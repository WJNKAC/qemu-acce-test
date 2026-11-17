/* Henge DMA 探针：由**外部**（gdbstub 的 M 包）改写代码页，验证 flatview_write 钩子
 *
 *   smc.S   写来自 guest 自己的 str -> 引擎的 hv_phys_write 内部失效（已成立）
 *   dma.S   写来自 gdbstub 的 M 包  -> cpu_memory_rw_debug
 *                                      -> address_space_rw
 *                                      -> flatview_write   ← 钩子在这里
 *
 * 同步协议（这个组合是实测出来的，每一步都试过别的写法）：
 *   1. guest 执行 target_fn 一次 -- 引擎翻译并缓存
 *   2. guest 自旋轮询 mailbox
 *   3. host: QMP `stop` 让 VM 停下
 *   4. host: gdbstub 写 target_fn，再写 mailbox = 1
 *   5. host: QMP `cont`
 *   6. guest 看到 mailbox，再执行 target_fn
 *
 * 为什么必须绕这一圈：
 *   - gdbstub 在 VM 运行中完全不响应包（实测），只有 VM 停下时处理；
 *   - guest 的 `brk #0` 不能用来停 VM：引擎把它当普通 BRK 异常，
 *     QEMU 根本不知道，gdbstub 也就收不到 stop reply（实测：guest 直接
 *     因为 VBAR=0 去取向量而 FAULT_LOOP）；
 *   - QMP 的 stop/cont 可以在运行中随时停，且停下后 gdbstub 立刻可用。
 *
 * 顺带验证第二件事：mailbox 是**数据**页，外部写它不该引起代码失效 ——
 * 而 guest 必须能读到新值（RAM 是共享的）。它若读不到，说明写根本没落地。
 */
    .section .text
    .globl _start
_start:
    adr  x1, stack0_top
    mov  sp, x1

    adr  x2, m_begin
    bl   puts

    /* ---- 1) 先执行一次，让引擎翻译并缓存 target_fn ---- */
    bl   target_fn
    adr  x2, m_first
    bl   puts
    bl   hex

    /* ---- 2) 把 mailbox 地址打出来，然后自旋等外部写 ---- */
    adr  x19, mailbox
    adr  x2, m_mb
    bl   puts
    mov  x0, x19
    bl   hex

    adr  x2, m_wait
    bl   puts

    movz x20, #0x2d00
    movk x20, #0x131, lsl #16
    movk x20, #0x0004, lsl #32      /* 长超时：外部要发 QMP + gdb 两组包 */
1:  ldr  w21, [x19]
    cbnz w21, 2f
    subs x20, x20, #1
    b.ne 1b
2:
    adr  x2, m_go
    bl   puts

    /* ---- 3) 外部已改写 target_fn ---- */
    bl   target_fn
    adr  x2, m_second
    bl   puts
    bl   hex

    adr  x2, m_end
    bl   puts
3:  wfi
    b    3b

target_fn:
    movz w0, #0x1111
    ret

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
stack0:  .space 0x4000
stack0_top:
mailbox: .space 4

m_begin: .asciz "DMA-BEGIN\n"
m_first: .asciz "FIRST="
m_mb:    .asciz "MB_ADDR="
m_wait:  .asciz "WAITING\n"
m_go:    .asciz "GO\n"
m_second:.asciz "SECOND="
m_end:   .asciz "DMA-END\n"
