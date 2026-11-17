/* Henge timer-IRQ probe: #2（时间源）与 #3（中断注入）的联合验收
 *
 * 单看 CNTFRQ 相同、CNTVCT 单调，都不足以证明时间源对了 —— 纪元差一个常数
 * 时这两个观测全都成立。唯一能证伪的观测是**闭环**：
 *
 *   guest 写 CNTV_CVAL = CNTVCT + 100ms
 *     → 转发器交给 QEMU 的 gtimer
 *     → QEMU 在虚拟钟到达 deadline 时 raise IRQ
 *     → GIC (arm_gicv3) → arm_cpu_set_irq → CPU_INTERRUPT_HARD
 *     → kick_vcpu_thread → henge_sync_irq → 引擎的 irq_line
 *     → 引擎按自己的 PSTATE 取 IRQ 异常 → 本探针的向量表
 *
 * 任何一环错位，都不可能出现 "TIMER-IRQ"。这也正是 Linux 的 tick 依赖的
 * 那条链路：sched_clock 读 CNTVCT，tick 靠 CVAL 到期。
 *
 * 同时它验证 GICv3 的两条通路：控制面 GICD/GICR 走 MMIO catch-all，
 * CPU 接口 ICC_* 走 cp_regs 转发器。
 *
 * 必须在 gic-version=3 下跑：GICv2 的 CPU 接口是 MMIO，没有 ICC_*。
 */
#define GICD_BASE   0x08000000
#define GICR_SGI    0x080B0000      /* GICR for cpu0 + 0x10000 */

    .section .text
    .globl _start
_start:
    /* ---- 1) 自己的异常向量 ---- */
    adr  x0, vectors
    msr  vbar_el1, x0
    isb

    /* ---- 2) GIC 控制面：MMIO，走 catch-all ---- */
    movz x1, #0x0800, lsl #16
    mov  w2, #0x12                  /* ARE_NS | EnableGrp1NS */
    str  w2, [x1]

    movz x1, #0x080b, lsl #16       /* GICR SGI_base */
    mov  w2, #1
    lsl  w2, w2, #27                /* PPI 27 = virtual timer */
    str  w2, [x1, #0x080]           /* IGROUPR0: Group1 */
    str  w2, [x1, #0x100]           /* ISENABLER0 */
    mov  w2, #0
    strb w2, [x1, #(0x400 + 27)]    /* IPRIORITYR27 = 0 (highest) */

    /* ---- 3) GIC CPU 接口：系统寄存器，走 cp_regs 转发器 ---- */
    mov  x2, #1
    msr  S3_0_C12_C12_5, x2         /* ICC_SRE_EL1 = 1 */
    isb
    mov  x2, #0xff
    msr  S3_0_C4_C6_0, x2           /* ICC_PMR_EL1 */
    mov  x2, #1
    msr  S3_0_C12_C12_7, x2         /* ICC_IGRPEN1_EL1 */

    adr  x2, m_armed
    bl   puts

    /* ---- 4) 编程 100ms 后的 deadline ---- */
    mrs  x4, cntfrq_el0
    mov  x5, #10
    udiv x4, x4, x5                 /* CNTFRQ/10 = 100 ms 的 tick 数 */
    isb
    mrs  x6, cntvct_el0
    add  x6, x6, x4
    msr  S3_3_C14_C3_2, x6          /* CNTV_CVAL_EL0 */
    mov  x2, #1
    msr  S3_3_C14_C3_1, x2          /* CNTV_CTL_EL0 = enable */

    /* ---- 5) 开 IRQ，然后等 ---- */
    msr  daifclr, #2
1:  wfi
    b    1b

/* ---- IRQ 向量 ---- */
irq_handler:
    adr  x2, m_irq
    bl   puts

    mrs  x4, S3_0_C12_C12_0         /* ICC_IAR1_EL1: 认领中断 */
    adr  x2, m_intid
    bl   puts
    mov  x0, x4
    bl   hex

    msr  S3_0_C12_C12_1, x4         /* ICC_EOIR1_EL1: 结束 */

    mov  x2, #0
    msr  S3_3_C14_C3_1, x2          /* 关掉 timer，别再来 */

    adr  x2, m_end
    bl   puts
2:  wfi
    b    2b

unexpected:
    adr  x2, m_unexp
    bl   puts
3:  wfi
    b    3b

/* x2 = NUL 结尾字符串 */
puts:
    movz x1, #0x0900, lsl #16
4:  ldrb w3, [x2], #1
    cbz  w3, 5f
    strb w3, [x1]
    b    4b
5:  ret

/* x0 = 值，16 位十六进制 + 换行 */
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

/* ---- 向量表：EL1h 用 SP_EL1，IRQ 位于 Current EL with SPx + 0x80 = 0x280 ---- */
    .p2align 11
vectors:
    .rept 0x280 / 4
    b unexpected
    .endr
    b irq_handler
    .rept (0x800 - 0x284) / 4
    b unexpected
    .endr

m_armed: .asciz "TIMER-ARMED\n"
m_irq:   .asciz "TIMER-IRQ\n"
m_intid: .asciz "INTID="
m_unexp: .asciz "TIMER-UNEXPECTED\n"
m_end:   .asciz "TIMER-DONE\n"
