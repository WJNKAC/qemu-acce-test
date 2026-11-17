/* Henge LL/SC 探针：ARMv8.0 的独占访问，与 LSE 是两条独立的路
 *
 * 为什么单独一个探针。LSE 门控回归那次，二分只证明
 *     hv_engine_set_lse(m, 0) -> Linux 零串口输出
 * 但没证明死因是"LSE 被拒"。引擎的解码树里 LL/SC 与 LSE 分开走：
 *
 *   decode_exclusive()  -> HV_MEM_EXCL   (LDXR/STXR/LDAXR/STLXR)
 *                       -> HV_MEM_CASP   (LDXP/STXP, o2&&o1 且 !(size>>1))
 *   单寄存器 atomic 分支 -> HV_MEM_ATOMIC (LDADD/SWP..., o3|aop)
 *   o2&&!o1             -> HV_MEM_CAS    (LSE 的 CAS)
 *
 * 门控谓词挂的是 {ATOMIC, CAS, CASP} 三种 kind。**CASP 是从
 * decode_exclusive 出来的**，也就是说如果 ARMv8.0 的 LDXP/STXP 被判成
 * HV_MEM_CASP（而不是 HV_MEM_EXCL），门控就会拒掉一条 v8.0 指令 ——
 * 与"内核首指令 UNDEF、零输出"完全吻合。
 *
 * 本探针把三个族分别测一遍，让死因可分辨：
 *   A  LL/SC 单宽（LDXR/STXR）       v8.0 必有
 *   B  LL/SC 配对（LDXP/STXP）       v8.0 必有  ← 门控可能误伤的就是这条
 *   C  LSE 原子（LDADD/SWP/CAS）     v8.1，应当被门控拒
 *
 * 判据：
 *   A 或 B 失败       → 门控误伤 v8.0 路径，谓词要挪
 *   只有 C 失败       → 门控正确，死因在别处（ID 视图不一致）
 *   三个都成功        → 门控完全没生效，另查
 */
    .section .text
    .globl _start
_start:
    movz x1, #0x0900, lsl #16
    adr  x2, m_begin
    bl   puts

    /* ---- A: LDXR / STXR 单宽 ---- */
    adr  x3, v64
    mov  x4, #0x1234
    str  x4, [x3]
    ldxr x5, [x3]                     /* x5 = 0x1234 */
    add  x6, x5, #1
    stxr w7, x6, [x3]                 /* w7 = 0 (success) */
    cbnz w7, bad_a
    ldr  x8, [x3]
    mov  x9, #0x1235
    cmp  x8, x9
    b.ne bad_a
    adr  x2, m_a_ok
    bl   puts

    /* ---- B: LDXP / STXP 配对（门控的嫌疑人）---- */
    adr  x3, v128
    mov  x4, #0x11
    mov  x5, #0x22
    stp  x4, x5, [x3]
    ldxp x6, x7, [x3]                 /* x6=0x11, x7=0x22 */
    mov  x9, #0x33
    mov  x10, #0x44
    stxp w11, x9, x10, [x3]           /* w11 = 0 (success) */
    cbnz w11, bad_b
    ldp  x12, x13, [x3]
    mov  x9, #0x33
    cmp  x12, x9
    b.ne bad_b
    mov  x9, #0x44
    cmp  x13, x9
    b.ne bad_b
    adr  x2, m_b_ok
    bl   puts

    /* ---- C: LSE（v8.1，应当被门控拒掉）---- */
    adr  x3, v64
    mov  x4, #10
    str  x4, [x3]
    mov  x5, #5
    ldadd x5, x6, [x3]                /* x6=10, mem=15 */
    mov  x9, #15
    ldr  x8, [x3]
    cmp  x8, x9
    b.ne bad_c
    adr  x2, m_c_ok
    bl   puts

    adr  x2, m_done
    bl   puts
    b    hang

bad_a:  adr x2, m_ba
        b   fail
bad_b:  adr x2, m_bb
        b   fail
bad_c:  adr x2, m_bc
fail:
    bl   puts
    adr  x2, m_crlf
    bl   puts
hang:
    wfi
    b    hang

puts:
    ldrb w3, [x2]
    cbz  w3, puts_ret
puts_wait:
    ldr  w4, [x1, #0x18]
    tbnz w4, #5, puts_wait
    str  w3, [x1]
    add  x2, x2, #1
    b    puts
puts_ret:
    ret

    .section .rodata
m_begin: .asciz "\nLLSC-BEGIN\n"
m_a_ok:  .asciz "A-OK "
m_b_ok:  .asciz "B-OK "
m_c_ok:  .asciz "C-OK "
m_done:  .asciz "\nLLSC-ALL-OK\n"
m_crlf:  .asciz "\n"
m_ba:    .asciz "BAD-A-LLSC-SINGLE"
m_bb:    .asciz "BAD-B-LLSC-PAIR"
m_bc:    .asciz "BAD-C-LSE"

    .section .data
    .align 4
v64:  .quad 0
    .align 4
v128: .quad 0, 0
