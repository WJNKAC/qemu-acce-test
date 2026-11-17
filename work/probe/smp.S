/* Henge SMP probe: 两个核都真的跑起来，且 CPU_ON 走的是 QEMU 的 PSCI
 *
 * 这是 #4 的验收，也是 Linux 二级核启动的最小复现：
 *
 *   cpu0: 读 MPIDR（必须是从 QEMU 转发的那个布局）
 *         → HVC PSCI CPU_ON(target = 本核 MPIDR + 1, entry = secondary, ctx)
 *         → 打印返回值（0 = success）
 *   cpu1: 被 QEMU 的 arm_set_cpu_on 唤醒，从 entry 起始执行
 *         → 它的 x0 是 context_id（PSCI 契约），打印出来核对
 *
 * 两种失败各自的签名很清楚：
 *   MPIDR 没转发（引擎自答）→ target 编号与 QEMU 的亲和性布局对不上，
 *       arm_set_cpu_on 返回 INVALID_PARAMS(0xfffffffe)，只有 cpu0 打印。
 *   PSCI 没转发（引擎自己处理）→ secondary 被引擎直接 reset，QEMU 侧的
 *       CPUState 与 vCPU 线程不知道，secondary 永远不动，同样只有 cpu0。
 */
#define MPIDR_AFF0  0xff
#define CONTEXT_LO  0x5ec0
#define CONTEXT_HI  0xc0de

    .section .text
    .globl _start
_start:
    mrs  x20, mpidr_el1
    and  x21, x20, #MPIDR_AFF0
    cbnz x21, secondary

/* ================= cpu0 ================= */
    adr  x1, stack0_top
    mov  sp, x1

    adr  x2, m_cpu0
    bl   puts
    mov  x0, x20
    bl   hex

    /*
     * 参数必须在调用 puts 之后重新装 —— puts/hex 会破坏 x0..x3。
     * x0 = fn, x1 = target MPIDR, x2 = entry, x3 = context_id
     */
    /*
     * target = 亲和性字段，不是 MPIDR_EL1 原值。MPIDR_EL1 的 bit31 是 RES1
     * （U 位），而 QEMU 的 arm_set_cpu_on() 拿到的 mp_affinity 里没有它 ——
     * 直接 x20+1 = 0x80000001 会被判成 "unknown CPU"。Linux 的
     * cpu_logical_map 同样只看亲和性字节，所以这里也照做。
     */
    and  x1, x20, #0xff
    add  x1, x1, #1
    adr  x2, secondary
    movz x3, #CONTEXT_LO
    movk x3, #CONTEXT_HI, lsl #16
    movz x0, #0x0003
    movk x0, #0xc400, lsl #16       /* 0xc4000003 = PSCI CPU_ON (64-bit) */
    hvc  #0

    adr  x2, m_on_ret
    bl   puts
    bl   hex                        /* x0 = PSCI 返回码 */

    adr  x2, m_done0
    bl   puts
1:  wfi
    b    1b

/* ================= cpu1 ================= */
secondary:
    adr  x1, stack1_top
    mov  sp, x1
    mov  x19, x0                    /* x0 = context_id，先存起来 */

    /*
     * 两个核同时写 PL011 会把输出撕成两半（串口没有硬件互斥）。等 cpu0
     * 打完再开口，输出就能逐行对齐 —— 这纯粹是为了让这个探针可读，
     * 不影响它验证的东西。
     */
    movz x9, #0x2d00
    movk x9, #0x131, lsl #16
9:  subs x9, x9, #1
    b.ne 9b

    adr  x2, m_cpu1
    bl   puts
    mov  x0, x20
    bl   hex

    adr  x2, m_ctx
    bl   puts
    mov  x0, x19
    bl   hex

    adr  x2, m_done1
    bl   puts
2:  wfi
    b    2b

/* ---- 工具 ---- */
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

    .p2align 4
stack0:     .space 0x4000
stack0_top:
stack1:     .space 0x4000
stack1_top:

m_cpu0:  .asciz "CPU0-MPIDR="
m_cpu1:  .asciz "CPU1-MPIDR="
m_on_ret:.asciz "CPU_ON-RET="
m_ctx:   .asciz "CPU1-CONTEXT="
m_done0: .asciz "CPU0-DONE\n"
m_done1: .asciz "CPU1-DONE\n"
