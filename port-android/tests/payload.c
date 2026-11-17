/* 最小 aarch64 裸机 payload：在等真内核编完之前，先用它把整条链路打通。
   它做四件事，每件都对应引擎里的一条关键路径：
     1. 往 PL011 写字符串        → MMIO 出口 + 设备模型
     2. 建 1:1 页表并开 MMU      → 软件 MMU 的页表走查 + SCTLR_EL1
     3. 开 MMU 后继续打印        → TLB 命中路径
     4. HVC #0 PSCI SYSTEM_OFF   → 异常注入 + PSCI
   链接到 0x40080000（RAM+0x80000），入口在偏移 0 处，和 arm64 Image 一样。 */
typedef unsigned long u64;
typedef unsigned int u32;

#define UART_DR 0x09000000UL
#define UART_FR 0x09000018UL

static void putc_(char ch) {
    while (*(volatile u32 *)UART_FR & (1u << 5)) { } /* TXFF: 等发送 FIFO 有空位 */
    *(volatile u32 *)UART_DR = (unsigned char)ch;
}

static void puts_(const char *s) {
    while (*s) {
        if (*s == '\n') putc_('\r');
        putc_(*s++);
    }
}

static void puthex(u64 v) {
    static const char d[] = "0123456789abcdef";
    puts_("0x");
    for (int i = 60; i >= 0; i -= 4) putc_(d[(v >> i) & 0xf]);
}

/* 4 级页表，1 GB 块映射，恒等映射前 2 GB：够跑这段代码和 UART。 */
static u64 l1[512] __attribute__((aligned(4096))); /* 1 GB 粒度 */

static void mmu_on(void) {
    /* TCR: T0SZ=25 (39-bit VA), 4KB granule, inner/outer WBWA, walks from l1 */
    u64 tcr = (25UL << 0)    /* T0SZ */
            | (1UL << 8)     /* IRGN0: WBWA */
            | (1UL << 10)    /* ORGN0: WBWA */
            | (3UL << 12)    /* SH0: inner shareable */
            | (0UL << 14)    /* TG0: 4KB */
            | (25UL << 16);  /* T1SZ */
    /* MAIR: attr0 = normal WBWA, attr1 = device-nGnRnE */
    u64 mair = (0xffUL << 0) | (0x00UL << 8);
    for (u64 i = 0; i < 2; i++)
        l1[i] = (i << 30) | (1UL << 10)     /* AF */
               | (1UL << 2)                  /* normal, inner shareable... attr idx 0 */
               | (3UL << 8)                  /* SH: inner */
               | (1UL << 0);                 /* valid block */
    /* UART 那一 GB 用 device 属性，避免写合并把字符吞掉 */
    l1[0] = (0UL << 30) | (1UL << 10) | (1UL << 2) | (1UL << 8) | (1UL << 0);

    __asm__ volatile("msr mair_el1, %0" ::"r"(mair));
    __asm__ volatile("msr tcr_el1, %0" ::"r"(tcr));
    __asm__ volatile("msr ttbr0_el1, %0" ::"r"((u64)l1));
    __asm__ volatile("dsb sy; isb");
    u64 sctlr;
    __asm__ volatile("mrs %0, sctlr_el1" : "=r"(sctlr));
    sctlr |= (1UL << 0) | (1UL << 2) | (1UL << 12); /* M, C, I */
    __asm__ volatile("msr sctlr_el1, %0; isb" ::"r"(sctlr));
}

void c_start(void) {
    puts_("\n[payload] bare-metal aarch64 is running under the translator\n");
    puts_("[payload] MMU off, talking to PL011 at ");
    puthex(UART_DR);
    puts_("\n");

    mmu_on();

    puts_("[payload] MMU on (4 KB granule, 1 GB blocks, identity map)\n");
    puts_("[payload] if this line printed, the software TLB is refilling\n");

    /* PSCI SYSTEM_OFF via HVC: x0 = 0x84000008（32 位 SMC32 调用号） */
    register u64 x0 __asm__("x0") = 0x84000008UL;
    __asm__ volatile("hvc #0" ::"r"(x0));
    for (;;) { }
}
