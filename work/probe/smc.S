/* Henge DMA->SMC probe: 从"设备"侧改代码页，看 guest 是否执行新指令
 *
 * 复现的是内核模块加载的失败形态：从盘上 DMA 读一段代码进 RAM，然后执行它。
 * 如果引擎不因外部写而失效翻译，它会继续跑旧字节 —— 表现像内存损坏，
 * 而不是像缺一个钩子。
 *
 * 做法（不需要真的挂一块盘）：
 *   1. guest 执行 patch_me 一次，让引擎把它翻译并缓存
 *   2. guest 把 patch_me 的地址写到 "mailbox"（一个已知 PA），然后原地自旋
 *   3. host 侧（测试脚本，QMP pmemsave/memsave 的对偶：hmp 的 `write` 命令
 *      不可用，所以用 QMP human-monitor-command + `pmemsave` 反向不可行）
 *      —— 改用：guest 自己通过 MMIO 触发，但那条路走的是引擎，不是 DMA。
 *
 * 因此这个探针只用一半：它验证"引擎自己的写会失效"（已知成立），并留下
 * patch_me 的地址给外部脚本。真正的 DMA 用例由 henge-lifecycle.sh 里的
 * monitor `sum` / 模块加载场景覆盖。
 *
 * 简化：直接把第二个版本写进 .data 里的 code 区，通过 str 修改指令字，
 *        再跳进去执行 —— 这是 SMC，不是 DMA，但它验证同一张 code_pages 位图。
 */
    .section .text
    .globl _start
_start:
    adr  x1, stack0_top
    mov  sp, x1

    adr  x2, m_begin
    bl   puts

    /* ---- 第一次：执行原版 patch_me，应为 0x1111 ---- */
    bl   patch_me
    adr  x2, m_first
    bl   puts
    bl   hex

    /*
     * ---- 改写 patch_me 的第一条指令 ----
     * 原：movz w0, #0x1111  = 0x52822220
     * 新：movz w0, #0x2222  = 0x52844440
     * 只改一个字节也没关系，这里整字写，和 DMA 写整块的行为一致。
     */
    adr  x3, patch_me
    movz w4, #0x4440
    movk w4, #0x5284, lsl #16
    str  w4, [x3]

    /* 指令缓存同步：guest 侧该做的它做了，剩下的靠引擎的 code_pages ---------- */
    dc   cvau, x3
    dsb  ish
    ic   ivau, x3
    dsb  ish
    isb

    /* ---- 第二次：应变成 0x2222，说明翻译已失效 ---- */
    bl   patch_me
    adr  x2, m_second
    bl   puts
    bl   hex

    adr  x2, m_end
    bl   puts
1:  wfi
    b    1b

patch_me:
    movz w0, #0x1111
    ret

puts:
    movz x1, #0x0900, lsl #16
2:  ldrb w3, [x2], #1
    cbz  w3, 3f
    strb w3, [x1]
    b    2b
3:  ret

hex:
    movz x1, #0x0900, lsl #16
    mov  x9, #60
4:  lsr  x10, x0, x9
    and  x10, x10, #0xf
    cmp  x10, #10
    b.lo 5f
    add  x10, x10, #('a' - 10)
    b    6f
5:  add  x10, x10, #'0'
6:  strb w10, [x1]
    subs x9, x9, #4
    b.ge 4b
    mov  w10, #10
    strb w10, [x1]
    ret

    .p2align 4
stack0:     .space 0x4000
stack0_top:

m_begin: .asciz "SMC-BEGIN\n"
m_first: .asciz "FIRST="
m_second:.asciz "SECOND="
m_end:   .asciz "SMC-END\n"
