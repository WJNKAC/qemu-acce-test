/* Henge sysreg probe: 证明"引擎不认识的系统寄存器被转给 QEMU"
 *
 * 背景：引擎自己建模了一部分 ARMv8 系统寄存器，QEMU 建模了另一部分（GICv3
 * 的 CPU 接口 ICC_*、通用定时器的 CNTV_CVAL 等）。两边的集合互不包含。
 *
 * 引擎遇到不认识的 MRS/MSR 时，原来的行为是注入 UNDEF。这个探针就是要
 * 区分出那个行为和转发：
 *
 *   ICC_IAR1_EL1  = S3_0_C12_C12_0   读它，没有待处理中断时应得 1023
 *   ICC_PMR_EL1   = S3_0_C4_C6_0     写 0xF0，读回应为 0xF0
 *   ICC_EOIR1_EL1 = S3_0_C12_C12_1   写回刚才 IAR 读到的东西
 *
 * 如果转发生效：打印 "SYSREG-OK"。如果引擎仍然注入 UNDEF：EL1 取异常，
 * VBAR=0 没有向量表，于是 FAULT_LOOP 或直接乱跑 —— 也就是"什么都没打印"。
 *
 * 注意 ICC_IAR1_EL1 在 GICv3 未使能（ICC_SRE / GICD_CTLR）时读到的仍是
 * 1023（spurious），这正好让探针不依赖 GIC 是否就绪。
 */
    .section .text
    .globl _start
_start:
    /* 先打个标记，证明执行到了这里 */
    movz x1, #0x0900, lsl #16
    adr  x2, m_begin
    bl   puts

    /* ---- 1) 读 ICC_IAR1_EL1 ---- */
    mrs  x4, S3_0_C12_C12_0
    mov  x5, #1023
    cmp  x4, x5
    b.ne fail_iar

    /* ---- 2) ICC_PMR_EL1 写后读回 ---- */
    mov  x6, #0xf0
    msr  S3_0_C4_C6_0, x6
    mrs  x7, S3_0_C4_C6_0
    cmp  x7, x6
    b.ne fail_pmr

    /* ---- 3) ICC_EOIR1_EL1：把 IAR 的值写回去 ---- */
    msr  S3_0_C12_C12_1, x4

    adr  x2, m_ok
    bl   puts
    b    done

fail_iar:
    adr  x2, m_badiar
    bl   puts
    b    done
fail_pmr:
    adr  x2, m_badpmr
    bl   puts

done:
    movz x1, #0x0900, lsl #16
    mov  w3, #10
    strb w3, [x1]
1:  wfi
    b    1b

/* x2 = NUL 结尾字符串，写到 PL011 */
puts:
    movz x1, #0x0900, lsl #16
2:  ldrb w3, [x2], #1
    cbz  w3, 3f
    strb w3, [x1]
    b    2b
3:  ret

m_begin:  .asciz "SYSREG-BEGIN\n"
m_ok:     .asciz "SYSREG-OK\n"
m_badiar: .asciz "SYSREG-BAD-IAR\n"
m_badpmr: .asciz "SYSREG-BAD-PMR\n"
