/* Henge 真 DMA 探针：让 QEMU 的 edu 设备用 pci_dma_write 写 guest 代码页
 *
 *   guest 写 MMIO(edu 0x98 = RUN|TO_PCI)
 *     -> QEMU edu 的 edu_dma_timer()
 *     -> pci_dma_write(pdev, dst = target_fn, dma_buf, 4)
 *     -> address_space_write
 *     -> flatview_write          ← 引擎的钩子在这里
 *     -> hv_engine_dma_written -> hv_dma_written -> code_pages 位图 -> page_gen++
 *
 * 钩子失效时，guest 第二次执行 target_fn 仍得 0x1111。
 *
 * 地址来自 `-M virt,dumpdtb=` 与 `info mtree`，两条独立来源一致：
 *   ECAM   0x40_10000000 - 0x40_1fffffff   (256 MB, 256 条总线)
 *   MMIO   0x10000000    - 0x3efeffff
 * 裸机 guest 必须自己做 PCIe 枚举：QEMU 不做，`info pci` 里 BAR0 显示
 * "(not mapped)"。`-device edu` 默认落在 Bus 0 / device 2，所以配置空间
 * 就是 ECAM + (2 << 15) = ECAM + 0x10000。
 *
 * 寄存器纪律：putc/hex 会破坏 x0/x1/x2/x3/x9/x10，所以所有跨调用要用的值
 * 一律放在 x19-x28（callee-saved，且本文件不碰它们）。上一版把 ECAM 基址
 * 留在 x9 里，hex 一跑就没了 —— 这正是第一次读回 0 的原因，不是引擎的问题。
 */
#define DMA_START       0x40000
#define REG_SRC         0x80
#define REG_DST         0x88
#define REG_CNT         0x90
#define REG_CMD         0x98
#define CMD_RUN         0x1
#define CMD_TO_PCI      0x2

#define ECAM_BASE       0x4010000000
#define EDU_CFG         (ECAM_BASE + 0x10000)   /* dev 2, fn 0 */
#define PCIE_MMIO_BASE  0x10000000

    .section .text
    .globl _start
_start:
    adr  x1, stack0_top
    mov  sp, x1

    movz x19, #(ECAM_BASE & 0xffff)
    movk x19, #((ECAM_BASE >> 16) & 0xffff), lsl #16
    movk x19, #((ECAM_BASE >> 32) & 0xffff), lsl #32
    add  x22, x19, #0x10000                 /* edu 的配置空间 */

    adr  x2, m_begin
    bl   puts

    /* ---- 1) 确认 edu 在 dev 2 ---- */
    ldr  w20, [x22]
    adr  x2, m_id
    bl   puts
    mov  x0, x20
    bl   hex

    movz w21, #0x1234
    and  w23, w20, #0xffff
    cmp  w23, w21
    b.ne no_edu

    /* ---- 2) BAR0 大小：写全 1 读回 ---- */
    movz w24, #0xffff
    movk w24, #0xffff, lsl #16
    str  w24, [x22, #0x10]
    ldr  w25, [x22, #0x10]
    and  w25, w25, #0xfffffff0
    mvn  w25, w25
    add  w25, w25, #1
    adr  x2, m_barsz
    bl   puts
    mov  x0, x25
    bl   hex

    /* ---- 3) BAR0 = MMIO 窗口起点 0x10000000 ---- */
    movz w26, #(PCIE_MMIO_BASE & 0xffff)
    movk w26, #((PCIE_MMIO_BASE >> 16) & 0xffff), lsl #16
    str  w26, [x22, #0x10]

    /* 使能 Memory Space（command bit 1）*/
    ldrh w27, [x22, #0x04]
    orr  w27, w27, #0x2
    strh w27, [x22, #0x04]

    mov  x28, x26                           /* x28 = edu MMIO 基址 */

    /* 回读三样：BAR0、command、以及它到底映射上了没有。
       BAR0 显示已分配但 QEMU 侧 xp 读到 0xffffffff 时，问题一定在这两个
       寄存器之一：command 的 Memory Space 位没置上，映射就不会建立。 */
    ldr  w20, [x22, #0x10]
    adr  x2, m_bar_rb
    bl   puts
    mov  x0, x20
    bl   hex
    ldrh w20, [x22, #0x04]
    adr  x2, m_cmd
    bl   puts
    mov  x0, x20
    bl   hex

    adr  x2, m_mmio
    bl   puts
    mov  x0, x28
    bl   hex

    /* ---- 4) liveness（偏移 0，应读 0xaa）---- */
    ldr  w20, [x28]
    adr  x2, m_live
    bl   puts
    mov  x0, x20
    bl   hex

    /* ---- 5) 先执行一次 target_fn，让它被翻译并缓存 ---- */
    bl   target_fn
    adr  x2, m_first
    bl   puts
    bl   hex

    /* ---- 6) FROM_PCI：把 patch 字喂进 dma_buf ---- */
    adr  x20, patch_insn
    str  w20, [x28, #REG_SRC]
    movz w20, #(DMA_START & 0xffff)
    movk w20, #(DMA_START >> 16), lsl #16
    str  w20, [x28, #REG_DST]
    mov  w20, #4
    str  w20, [x28, #REG_CNT]
    mov  w20, #CMD_RUN
    str  w20, [x28, #REG_CMD]
    bl   dma_wait

    /* ---- 7) TO_PCI：设备写 target_fn —— 真 DMA 写代码页 ---- */
    movz w20, #(DMA_START & 0xffff)
    movk w20, #(DMA_START >> 16), lsl #16
    str  w20, [x28, #REG_SRC]
    adr  x20, target_fn
    str  w20, [x28, #REG_DST]
    mov  w20, #4
    str  w20, [x28, #REG_CNT]
    mov  w20, #(CMD_RUN | CMD_TO_PCI)
    str  w20, [x28, #REG_CMD]
    bl   dma_wait
    adr  x2, m_dma_done
    bl   puts

    /* ---- 8) 再执行：钩子有效则是 0x2222 ---- */
    bl   target_fn
    adr  x2, m_second
    bl   puts
    bl   hex
    b    done

no_edu:
    adr  x2, m_noedu
    bl   puts

done:
    adr  x2, m_end
    bl   puts
1:  wfi
    b    1b

/* 等 edu 的 DMA 线程把 cmd 的 RUN 位清掉（超时后放弃，避免挂死）。
   只用 x20/x21，不碰调用者的 x19/x22/x28。 */
dma_wait:
    movz x20, #0x2d00
    movk x20, #0x131, lsl #16
    movk x20, #0x0002, lsl #32
2:  ldr  w21, [x28, #REG_CMD]
    tbnz w21, #0, 3f
    subs x20, x20, #1
    b.ne 2b
3:  ret

target_fn:
    movz w0, #0x1111
    ret

    .p2align 2
patch_insn:
    .word 0x52844440                /* movz w0, #0x2222 */

puts:
    movz x1, #0x0900, lsl #16
4:  ldrb w3, [x2], #1
    cbz  w3, 5f
    strb w3, [x1]
    b    4b
5:  ret

hex:
    movz x1, #0x0900, lsl #16
    mov  x9, #60
6:  lsr  x10, x0, x9
    and  x10, x10, #0xf
    cmp  x10, #10
    b.lo 7f
    add  x10, x10, #('a' - 10)
    b    8f
7:  add  x10, x10, #'0'
8:  strb w10, [x1]
    subs x9, x9, #4
    b.ge 6b
    mov  w10, #10
    strb w10, [x1]
    ret

    .p2align 4
stack0:     .space 0x4000
stack0_top:

m_begin:   .asciz "EDU-BEGIN\n"
m_id:      .asciz "EDU-ID="
m_noedu:   .asciz "EDU-ID-MISMATCH\n"
m_barsz:   .asciz "BAR0-SIZE="
m_bar_rb:  .asciz "BAR0-READBACK="
m_cmd:     .asciz "CMD="
m_mmio:    .asciz "MMIO="
m_live:    .asciz "LIVENESS="
m_first:   .asciz "FIRST="
m_dma_done:.asciz "DMA-DONE\n"
m_second:  .asciz "SECOND="
m_end:     .asciz "EDU-END\n"
