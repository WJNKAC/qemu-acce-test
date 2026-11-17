/* Henge LSE 探针：ARMv8.1 原子指令（LSE）到底是不是真的被执行了
 *
 * 为什么需要它。`-cpu max` 在本树下是 `aarch64_aa32_a57_init`（ARMv8.0），
 * ID_AA64ISAR0.ATOMIC = 0，所以内核的 alternatives 和 musl 都不会发 LSE 指令，
 * 全程只走 LL/SC。引擎里 HV_MEM_ATOMIC / HV_MEM_CAS / HV_MEM_CASP 那三条路径
 * 于是零覆盖 —— 而 A57 基线恰恰让人以为"跑通了就等于覆盖了"。
 *
 * v11.1.3 没有 cortex-a76 模型（aarch64_cpus[] 只有 a57/a53/host/max），
 * 换 CPU 模型这条路不通，只能在 EL1 直接发这些指令。
 *
 * 引擎的翻译器不查 ID 寄存器，所以只要能翻译就一定执行，这正好让探针
 * 直接测"解码+语义"而不是测"guest 愿不愿意用"。
 *
 * 覆盖：
 *   LDADD / LDCLR / LDEOR / LDSET / LDSMAX / LDSMIN / LDUMAX / LDUMIN
 *   SWP / CAS / CASA / CASL / CASAL
 *   含 32/64 位两种宽度、以及 A（acquire）/ L（release）后缀的编码
 *
 * 判据：每一项都必须读到"旧值 + 写回新值"两步都对。任何一项错就打印 BAD-xx，
 * 全对打印 LSE-OK。引擎若没实现，会在 translate_mem_impl 之前就被 memop 解码
 * 成 HV_MEM_ATOMIC，所以错的表现是"值不对"而不是"UNDEF"——这正是要抓的。
 */
    .section .text
    .globl _start
_start:
    movz x1, #0x0900, lsl #16          /* PL011 数据寄存器 */
    adr  x2, m_begin
    bl   puts

    /* ---- LDADD: 旧值进 Rt，内存变成 mem+Rs ---- */
    adr  x3, v64
    mov  x4, #100
    str  x4, [x3]
    mov  x5, #7
    ldadd x5, x6, [x3]                 /* x6 = 旧值 100, mem = 107 */
    mov  x7, #100
    cmp  x6, x7
    b.ne bad_ldadd
    ldr  x8, [x3]
    mov  x7, #107
    cmp  x8, x7
    b.ne bad_ldadd

    /* ---- LDCLR ---- */
    mov  x4, #0xff
    str  x4, [x3]
    mov  x5, #0x0f
    ldclr x5, x6, [x3]                 /* mem = 0xf0 */
    ldr  x8, [x3]
    mov  x7, #0xf0
    cmp  x8, x7
    b.ne bad_ldclr

    /* ---- LDEOR ---- */
    mov  x4, #0xaa
    str  x4, [x3]
    mov  x5, #0xff
    ldeor x5, x6, [x3]                 /* mem = 0x55 */
    ldr  x8, [x3]
    mov  x7, #0x55
    cmp  x8, x7
    b.ne bad_ldeor

    /* ---- LDSET ---- */
    mov  x4, #0
    str  x4, [x3]
    mov  x5, #0x30
    ldset x5, x6, [x3]                 /* mem = 0x30 */
    ldr  x8, [x3]
    mov  x7, #0x30
    cmp  x8, x7
    b.ne bad_ldset

    /* ---- LDSMAX (有符号) ---- */
    mov  x4, #5
    str  x4, [x3]
    mov  x5, #9
    ldsmax x5, x6, [x3]                /* mem = 9 */
    ldr  x8, [x3]
    mov  x7, #9
    cmp  x8, x7
    b.ne bad_smax

    /* ---- LDSMIN：写更大值应无变化 ---- */
    mov  x4, #5
    str  x4, [x3]
    mov  x5, #9
    ldsmin x5, x6, [x3]                /* mem 不变 = 5 */
    ldr  x8, [x3]
    cmp  x8, x4
    b.ne bad_smin

    /* ---- LDUMAX / LDUMIN (无符号，用负数区分与有符号实现) ---- */
    mov  x4, #1
    str  x4, [x3]
    mov  x5, #-1                       /* 无符号极大 */
    ldumax x5, x6, [x3]                /* mem 应变 -1 */
    ldr  x8, [x3]
    cmp  x8, x5
    b.ne bad_umax

    mov  x4, #1
    str  x4, [x3]
    mov  x5, #-1
    ldumin x5, x6, [x3]                /* mem 不变 = 1 */
    ldr  x8, [x3]
    cmp  x8, x4
    b.ne bad_umin

    /* ---- SWP：交换 ---- */
    mov  x4, #0x1111
    str  x4, [x3]
    mov  x5, #0x2222
    swp  x5, x6, [x3]                  /* x6 = 0x1111, mem = 0x2222 */
    mov  x7, #0x1111
    cmp  x6, x7
    b.ne bad_swp
    ldr  x8, [x3]
    mov  x7, #0x2222
    cmp  x8, x7
    b.ne bad_swp

    /* ---- CAS：相等才换 ---- */
    mov  x4, #0x55
    str  x4, [x3]
    mov  x5, #0x55
    mov  x6, #0x66
    cas  x5, x6, [x3]                  /* 相等 -> mem = 0x66 */
    ldr  x8, [x3]
    mov  x7, #0x66
    cmp  x8, x7
    b.ne bad_cas

    /* ---- CAS：不相等不换，且 Rt 回填内存实际值 ---- */
    mov  x5, #0x99                     /* 期望值不匹配 */
    mov  x6, #0x77
    cas  x5, x6, [x3]                  /* mem 保持 0x66，x5 = 0x66 */
    ldr  x8, [x3]
    mov  x7, #0x66
    cmp  x8, x7
    b.ne bad_cas2
    cmp  x5, x7
    b.ne bad_cas2

    /* ---- CASA / CASAL：acq / acq-rel 变体必须同样正确 ---- */
    mov  x4, #0x10
    str  x4, [x3]
    mov  x5, #0x10
    mov  x6, #0x20
    casa x5, x6, [x3]
    ldr  x8, [x3]
    mov  x7, #0x20
    cmp  x8, x7
    b.ne bad_casal

    mov  x5, #0x20
    mov  x6, #0x30
    casal x5, x6, [x3]
    ldr  x8, [x3]
    mov  x7, #0x30
    cmp  x8, x7
    b.ne bad_casal

    /* ---- 32 位宽度：ldadd w ---- */
    adr  x3, v32
    mov  w4, #10
    str  w4, [x3]
    mov  w5, #5
    ldadd w5, w6, [x3]                 /* w6 = 10, mem = 15 */
    mov  w7, #10
    cmp  w6, w7
    b.ne bad_w
    ldr  w8, [x3]
    mov  w7, #15
    cmp  w8, w7
    b.ne bad_w

    adr  x2, m_ok
    bl   puts
    b    done

bad_ldadd:  adr x2, m_b1
            b   fail
bad_ldclr:  adr x2, m_b2
            b   fail
bad_ldeor:  adr x2, m_b3
            b   fail
bad_ldset:  adr x2, m_b4
            b   fail
bad_smax:   adr x2, m_b5
            b   fail
bad_smin:   adr x2, m_b6
            b   fail
bad_umax:   adr x2, m_b7
            b   fail
bad_umin:   adr x2, m_b8
            b   fail
bad_swp:    adr x2, m_b9
            b   fail
bad_cas:    adr x2, m_b10
            b   fail
bad_cas2:   adr x2, m_b11
            b   fail
bad_casal:  adr x2, m_b12
            b   fail
bad_w:      adr x2, m_b13
fail:
    bl   puts
    adr  x2, m_crlf
    bl   puts
done:
    /* WFI 收尾：引擎把它当 HV_EXIT_WFI，QEMU 停住，脚本靠超时收工 */
    wfi
    b    done

/* ---- 输出：x1 = UART 基址，x2 = 字符串 ---- */
puts:
    ldrb w3, [x2]
    cbz  w3, puts_ret
puts_wait:
    ldr  w4, [x1, #0x18]               /* UARTFR */
    tbnz w4, #5, puts_wait             /* TXFF */
    str  w3, [x1]
1:  add  x2, x2, #1
    b    puts
puts_ret:
    ret

    .section .rodata
m_begin: .asciz "\nLSE-BEGIN\n"
m_ok:    .asciz "LSE-OK"
m_crlf:  .asciz "\n"
m_b1:    .asciz "BAD-LDADD"
m_b2:    .asciz "BAD-LDCLR"
m_b3:    .asciz "BAD-LDEOR"
m_b4:    .asciz "BAD-LDSET"
m_b5:    .asciz "BAD-LDSMAX"
m_b6:    .asciz "BAD-LDSMIN"
m_b7:    .asciz "BAD-LDUMAX"
m_b8:    .asciz "BAD-LDUMIN"
m_b9:    .asciz "BAD-SWP"
m_b10:   .asciz "BAD-CAS"
m_b11:   .asciz "BAD-CAS-NOMATCH"
m_b12:   .asciz "BAD-CASA/CASAL"
m_b13:   .asciz "BAD-W32"

    .section .data
    .align 4
v64: .quad 0
v32: .word 0
