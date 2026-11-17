/* Henge ID probe: 覆盖三种寄存器存储形态，每一种都可能坏在不同地方
 *
 * 引擎自答 ID 组时给的是"固定 Cortex-A76 镜像"，与 QEMU 正在建模的 CPU
 * 无关。转发之后这三条都必须与 TCG 逐字相同：
 *
 *   1. MIDR_EL1        ARM_CP_CONST 型 —— 读 resetvalue，不碰 env
 *   2. ID_AA64PFR0_EL1 ARM_CP_CONST 型 —— 同一路径，但它是 guest 判断
 *                      "有没有 FP/SIMD、GICv3 sysreg" 的依据
 *   3. CNTFRQ_EL0      fieldoffset 型 —— 读 env.cp15.c14_cntfrq，
 *                      也就是 QEMU gtimer 实际用的频率（不是引擎硬编码的 24 MHz）
 *
 * 每个值都按 nibble 打出来，便于和 TCG 的输出直接对照。任何一个不一致
 * 都会打印 MISMATCH 而不是静默通过 —— 这个探针的用途就是当验收。
 *
 * 另外测一条权限：EL1 读 MPIDR_EL1 必须成功（它是 PL1 寄存器），
 * 用来确认 PL 检查没有把合法访问挡掉。
 */
    .section .text
    .globl _start
_start:
    adr  x2, m_begin
    bl   puts

    /* ---- 1) MIDR_EL1 ---- */
    mrs  x4, midr_el1
    adr  x2, m_midr
    bl   puts
    mov  x0, x4
    bl   hex

    /* ---- 2) ID_AA64PFR0_EL1 ---- */
    mrs  x4, id_aa64pfr0_el1
    adr  x2, m_pfr0
    bl   puts
    mov  x0, x4
    bl   hex

    /* ---- 3) CNTFRQ_EL0 ---- */
    mrs  x4, cntfrq_el0
    adr  x2, m_cntfrq
    bl   puts
    mov  x0, x4
    bl   hex

    /* ---- 4) MPIDR_EL1（PL1，EL1 必须能读）---- */
    mrs  x4, mpidr_el1
    adr  x2, m_mpidr
    bl   puts
    mov  x0, x4
    bl   hex

    /* ---- 5) CTR_EL0（PL0，EL1 也能读）---- */
    mrs  x4, ctr_el0
    adr  x2, m_ctr
    bl   puts
    mov  x0, x4
    bl   hex

    adr  x2, m_end
    bl   puts
1:  wfi
    b    1b

/* 打印一行前缀（x2 = 字符串），不换行 */
puts:
    movz x1, #0x0900, lsl #16
2:  ldrb w3, [x2], #1
    cbz  w3, 3f
    strb w3, [x1]
    b    2b
3:  ret

/* x0 = 值，打印 16 个十六进制位 + 换行 */
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

m_begin: .asciz "ID-BEGIN\n"
m_midr:  .asciz "MIDR="
m_pfr0:  .asciz "ID_AA64PFR0="
m_cntfrq:.asciz "CNTFRQ="
m_mpidr: .asciz "MPIDR="
m_ctr:   .asciz "CTR_EL0="
m_end:   .asciz "ID-END\n"
