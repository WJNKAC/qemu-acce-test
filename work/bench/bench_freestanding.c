// bench_freestanding.c —— 不依赖任何 libc 的 aarch64 基准程序
//
// 为什么要 freestanding：
//   要在**两个不同的 C 运行库环境**里跑同一个二进制——
//     客机 = Debian glibc
//     Android 宿主 = bionic
//   glibc 静态库的二进制在 bionic 上不一定能跑，反之亦然。
//   只用 svc 指令直接发系统调用，就绕开这个问题：内核 ABI（syscall 号+参数）
//   在两边完全一样。
//
// 只用两个系统调用：write(64)、clock_gettime(113, CLOCK_MONOTONIC=1)
//
// 编译：
//   aarch64-linux-gnu-gcc -O2 -static -nostdlib -ffreestanding \
//       -fno-stack-protector -o bench bench_freestanding.c
//
// ⚠ 第一版把累加器绑到固定寄存器（register u64 a asm("x9")）再配 "+r" 约束，
//   在 GCC 上是经典陷阱：固定寄存器与约束分配会打架，结果在 Android 上直接
//   段错误、在客机上也未必对。改成普通 C + volatile 做数据依赖，
//   语义一样"不许优化掉"，但不再依赖编译器的寄存器分配细节。
//
// 每个用例固定迭代次数，输出 "名字 纳秒 每项纳秒" 与字节速率，便于两边直接比。

typedef unsigned long u64;
typedef long i64;

struct timespec {
    i64 tv_sec;
    i64 tv_nsec;
};

static inline i64 sys_write(i64 fd, const void *buf, u64 n)
{
    register i64 x8 asm("x8") = 64;
    register i64 x0 asm("x0") = fd;
    register const void *x1 asm("x1") = buf;
    register u64 x2 asm("x2") = n;
    asm volatile("svc #0"
                 : "+r"(x0)
                 : "r"(x8), "r"(x1), "r"(x2)
                 : "memory");
    return x0;
}

static inline void now(struct timespec *ts)
{
    register i64 x8 asm("x8") = 113;
    register i64 x0 asm("x0") = 1; /* CLOCK_MONOTONIC */
    register struct timespec *x1 asm("x1") = ts;
    asm volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1) : "memory");
}

static u64 ns_diff(const struct timespec *a, const struct timespec *b)
{
    return (u64)((b->tv_sec - a->tv_sec) * 1000000000LL +
                 (b->tv_nsec - a->tv_nsec));
}

/* ---------- 极简输出 ---------- */
static u64 slen(const char *s)
{
    u64 n = 0;
    while (s[n]) n++;
    return n;
}
static void puts_(const char *s) { sys_write(1, s, slen(s)); }

static void putnum(u64 v)
{
    char b[24];
    int i = 24;
    if (v == 0) {
        sys_write(1, "0", 1);
        return;
    }
    while (v && i > 0) {
        b[--i] = (char)('0' + (v % 10));
        v /= 10;
    }
    sys_write(1, b + i, (u64)(24 - i));
}

static void pad(const char *name)
{
    puts_(name);
    for (u64 i = slen(name); i < 14; i++) sys_write(1, " ", 1);
}

static void report(const char *name, u64 ns, u64 iters)
{
    pad(name);
    putnum(ns);
    puts_(" ns  ");
    if (iters) {
        u64 per = (ns * 1000) / iters; /* 放大 1000 倍 */
        putnum(per / 1000);
        puts_(".");
        u64 frac = per % 1000;
        if (frac < 100) sys_write(1, "0", 1);
        if (frac < 10) sys_write(1, "0", 1);
        putnum(frac);
        puts_(" ns/op");
    }
    puts_("\n");
}

/* MB/s = bytes / (ns/1e9) / 1e6 = bytes * 1000 / ns  (再取整) */
static void report_rate(const char *name, u64 ns, u64 bytes)
{
    pad(name);
    putnum(ns / 1000000);
    puts_(" ms");
    for (u64 i = 0; i < 5; i++) sys_write(1, " ", 1);
    if (ns) {
        /* 先把 B/s 算出来再换算成 MiB/s。
           第一版写成 (bytes/1024)*1e6/ns —— 那个量级是 MiB/s 本身，
           却又除了 1000，于是 2900 MB/s 被印成 2.900（差 1000 倍）。 */
        u64 bps = bytes * 1000000000ULL / ns;      /* 字节/秒 */
        u64 mibs_x1000 = bps * 1000 / 1048576ULL;  /* MiB/s × 1000 */
        putnum(mibs_x1000 / 1000);
        puts_(".");
        u64 f = mibs_x1000 % 1000;
        if (f < 100) sys_write(1, "0", 1);
        if (f < 10) sys_write(1, "0", 1);
        putnum(f);
        puts_(" MiB/s");
    }
    puts_("\n");
}

/* ---------- 基准内核 ----------
 * 用 volatile 累加器做数据依赖：编译器无法把循环化简掉，
 * 也无法把中间结果提到循环外。
 */

// 纯整数运算：依赖链做长（每条依赖上一条），测的是延迟而不是吞吐
__attribute__((noinline)) static u64 k_alu(u64 n)
{
    /* 累加器**不能**用 volatile：那会把每个中间值压回栈，
       测出来的是 store/load 而不是算术。实测两者差 6 倍。
       保持普通局部变量（留在寄存器），靠末尾的 asm 屏障阻止删除。 */
    u64 a = 1, b = 3;
    for (u64 i = 0; i < n; i++) {
        a = a + b;
        b = b ^ (a >> 3);
        a = a + (b << 1);
        b = b - 7;
    }
    asm volatile("" : "+r"(a), "+r"(b));
    return a ^ b;
}

// 乘加：mul 延迟更长，测乘法路径
__attribute__((noinline)) static u64 k_mul(u64 n)
{
    u64 a = 7;
    const u64 m = 0x9e3779b97f4a7c15UL;
    for (u64 i = 0; i < n; i++) {
        a = a * m + 1;
    }
    asm volatile("" : "+r"(a));
    return a;
}

// 顺序访存：测 cache line 预取与带宽
__attribute__((noinline)) static u64 k_mem_seq(volatile u64 *buf, u64 words, u64 reps)
{
    volatile u64 acc = 0;
    for (u64 r = 0; r < reps; r++) {
        for (u64 i = 0; i < words; i++) acc = acc + buf[i];
    }
    return acc;
}

// 跨步访存：步长 64B（一个 cache line），每次访问换行，测预取/TLB
__attribute__((noinline)) static u64 k_mem_stride(volatile u64 *buf, u64 words,
                                                 u64 stride, u64 reps)
{
    volatile u64 acc = 0;
    for (u64 r = 0; r < reps; r++) {
        for (u64 i = 0; i < words; i += stride) acc = acc + buf[i];
    }
    return acc;
}

// 函数调用开销：noinline 保证不被内联
__attribute__((noinline)) static u64 leaf(u64 x) { return x + 1; }
__attribute__((noinline)) static u64 k_call(u64 n)
{
    volatile u64 a = 0;
    for (u64 i = 0; i < n; i++) a = leaf(a);
    return a;
}

// 数据相关分支：模式周期 8，分支预测器猜不全
__attribute__((noinline)) static u64 k_branch(u64 n)
{
    volatile u64 acc = 0;
    for (u64 i = 0; i < n; i++) {
        if ((i & 7) < 3)
            acc = acc + i;
        else
            acc = acc - 1;
    }
    return acc;
}

/* ---------- best-of-N 计时 ----------
 * 为什么取最小值而不是平均：
 *   这个设备是 big.LITTLE + 有后台负载，单次测量会被调度/降频污染。
 *   实测原生侧 alu 的单次值在 2.99~5.36 ns/op 之间波动（±61%）。
 *   最小值对应"干扰最少的那次"，是微基准的标准做法；
 *   平均值会把噪声算进结果，反而不可比。
 */
#define BOFN 3

typedef u64 (*fn_u64)(u64);

static u64 time_fn(fn_u64 f, u64 n)
{
    struct timespec t0, t1;
    u64 best = ~0UL;
    for (int r = 0; r < BOFN; r++) {
        now(&t0);
        u64 sink = f(n);
        now(&t1);
        asm volatile("" : "+r"(sink));
        u64 d = ns_diff(&t0, &t1);
        if (d < best) best = d;
    }
    return best;
}

/* ---------- 静态缓冲（不用 malloc）---------- */
static u64 membuf[8192]; /* 64 KB */

void _start(void)
{
    struct timespec t0, t1;
    u64 sink;

    puts_("=== bench_freestanding (best of ");
    putnum(BOFN);
    puts_(") ===\n");

    for (u64 i = 0; i < 8192; i++) membuf[i] = i * 2654435761UL;

    /* 预热：这个设备的 schedutil 在 idle 时把频率压到 700~950 MHz，
       而基准原先是几十毫秒就结束、根本来不及升频 —— 实测同一颗核
       两次测量能差 55%。先跑约 1 秒把 DVFS 拉起来，后面的数才可比。
       宿主管不到客机里的 cpufreq，所以这一段在两边都是必须的。 */
    sink = k_alu(30000000);
    sink ^= k_mul(30000000);
    sink ^= k_branch(30000000);
    asm volatile("" : "+r"(sink));

    report("alu",    time_fn(k_alu,   30000000), 30000000);
    report("mul",    time_fn(k_mul,   30000000), 30000000);
    report("call",   time_fn(k_call,  30000000), 30000000);
    report("branch", time_fn(k_branch,30000000), 30000000);

    {
        u64 best = ~0UL;
        for (int r = 0; r < BOFN; r++) {
            now(&t0);
            sink = k_mem_seq(membuf, 8192, 1500);
            now(&t1);
            asm volatile("" : "+r"(sink));
            u64 d = ns_diff(&t0, &t1);
            if (d < best) best = d;
        }
        report_rate("mem_seq", best, 8192UL * 8 * 1500);
    }

    {
        u64 best = ~0UL;
        for (int r = 0; r < BOFN; r++) {
            now(&t0);
            sink = k_mem_stride(membuf, 8192, 8, 1500);
            now(&t1);
            asm volatile("" : "+r"(sink));
            u64 d = ns_diff(&t0, &t1);
            if (d < best) best = d;
        }
        report("mem_stride64", best, (8192 / 8) * 1500);
    }

    (void)sink;
    puts_("=== done ===\n");

    register i64 x8 asm("x8") = 94;
    register i64 x0 asm("x0") = 0;
    asm volatile("svc #0" : "+r"(x0) : "r"(x8) : "memory");
    for (;;) {
    }
}
