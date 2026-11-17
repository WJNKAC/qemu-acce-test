/* Henge timer probe: CNTFRQ 一致还不够，epoch 也要对齐
 *
 * CNTFRQ 相同只说明"频率"对了；真正会让 guest 出问题的是**纪元**不同 ——
 * 两个时钟各走各的，差一个常数。这个探针同时验证两件事：
 *
 *   1. CNTFRQ 与 TCG 读数一致（转发的是 QEMU gtimer 用的频率）
 *   2. 两次读 CNTVCT 之间，guest 看到的增量 ≈ 真实流逝时间 × CNTFRQ
 *      （用固定次数的忙等制造已知量级的延迟，与 TCG 比同一区间的增量）
 *
 * 只看绝对值没意义（两个宿主的计数器起点天然不同），看的是**同一进程内
 * 两次读数的差**，以及它换算成时间之后是否在合理范围内。TCG 与 henge 的
 * 增量应该在同一量级；差一个数量级就说明缩放或纪元错了。
 */
    .section .text
    .globl _start
_start:
    adr  x2, m_begin
    bl   puts

    /* CNTFRQ */
    mrs  x4, cntfrq_el0
    adr  x2, m_frq
    bl   puts
    mov  x0, x4
    bl   hex
    mov  x19, x4                  /* 留作后面换算用 */

    /* t0 */
    isb
    mrs  x5, cntvct_el0
    adr  x2, m_t0
    bl   puts
    mov  x0, x5
    bl   hex

    /* 一段已知量级的忙等：约 20M 次循环 */
    /* 20000000 = 0x1312D00：movz/movk 两步 */
    movz x9, #0x2d00
    movk x9, #0x131, lsl #16
1:  subs x9, x9, #1
    b.ne 1b

    /* t1 */
    isb
    mrs  x6, cntvct_el0
    adr  x2, m_t1
    bl   puts
    mov  x0, x6
    bl   hex

    /* delta = t1 - t0 */
    adr  x2, m_delta
    bl   puts
    sub  x0, x6, x5
    bl   hex

    /* delta 换算成毫秒：delta * 1000 / CNTFRQ（CNTFRQ 在 x19）*/
    adr  x2, m_ms
    bl   puts
    sub  x0, x6, x5
    mov  x1, #1000
    mul  x0, x0, x1
    udiv x0, x0, x19
    bl   hex

    adr  x2, m_end
    bl   puts
2:  wfi
    b    2b

puts:
    movz x1, #0x0900, lsl #16
3:  ldrb w3, [x2], #1
    cbz  w3, 4f
    strb w3, [x1]
    b    3b
4:  ret

hex:
    movz x1, #0x0900, lsl #16
    mov  x9, #60
5:  lsr  x10, x0, x9
    and  x10, x10, #0xf
    cmp  x10, #10
    b.lo 6f
    add  x10, x10, #('a' - 10)
    b    7f
6:  add  x10, x10, #'0'
7:  strb w10, [x1]
    subs x9, x9, #4
    b.ge 5b
    mov  w10, #10
    strb w10, [x1]
    ret

m_begin: .asciz "TIMER-BEGIN\n"
m_frq:   .asciz "CNTFRQ="
m_t0:    .asciz "CNTVCT_T0="
m_t1:    .asciz "CNTVCT_T1="
m_delta: .asciz "DELTA="
m_ms:    .asciz "DELTA_MS="
m_end:   .asciz "TIMER-END\n"
