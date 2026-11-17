/* 三方对比用的单一负载集合。
   静态链接成 Linux aarch64 ELF，于是三条路径跑的是同一个二进制：
     1. 原生            —— 设备上直接执行
     2. qemu-aarch64    —— 同 ISA TCG（user-mode）
     3. hv-linux        —— 本移植的直通翻译器（跑在 Linux 客户机里）
   这样编译器、库、代码布局完全一致，差异只来自翻译/执行方式本身。 */
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>

static double mono(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

/* 纯寄存器 ALU：直通翻译器应接近原生，TCG 会明显吃亏 */
static double bench_alu(long iters) {
    unsigned long long a = 1, b = 3, c = 5, d = 7;
    double t0 = mono();
    for (long i = 0; i < iters; i++) {
        a = a * 6364136223846793005ull + 1442695040888963407ull;
        b ^= a >> 17; b += i;
        c += a ^ b; c = (c << 7) | (c >> 57);
        d -= c * 3 + b;
        a ^= d >> 11;
    }
    double t1 = mono();
    volatile unsigned long long s = a ^ b ^ c ^ d; (void)s;
    return (t1 - t0) * 1e9 / (double)iters;
}

/* 访存密集：软件 MMU / softmmu 的代价都落在这里 */
static double bench_mem(long iters) {
    static unsigned int arr[8192];
    for (int i = 0; i < 8192; i++) arr[i] = (unsigned)i * 2654435761u;
    unsigned long long acc = 0;
    double t0 = mono();
    for (long i = 0; i < iters; i++) {
        unsigned idx = (unsigned)(acc + (unsigned long long)i) & 8191u;
        unsigned v = arr[idx];
        arr[idx] = v + 1u;
        acc += v * 3u + 1u;
        acc ^= acc >> 7;
    }
    double t1 = mono();
    volatile unsigned long long s = acc; (void)s;
    return (t1 - t0) * 1e9 / (double)iters;
}

/* 函数调用密集：考分支链、返回表、间接跳转缓存 */
static unsigned long long __attribute__((noinline)) leaf(unsigned long long x) {
    return x * 6364136223846793005ull + 1;
}
static double bench_call(long iters) {
    unsigned long long a = 1;
    double t0 = mono();
    for (long i = 0; i < iters; i++) a = leaf(a ^ (unsigned long long)i);
    double t1 = mono();
    volatile unsigned long long s = a; (void)s;
    return (t1 - t0) * 1e9 / (double)iters;
}

/* 分支密集：考块链与退出开销 */
static double bench_branch(long iters) {
    unsigned long long a = 0, x = 1;
    double t0 = mono();
    for (long i = 0; i < iters; i++) {
        if (x & 1) { if (x & 2) a += 3; else a -= 1; }
        else { if (x & 4) a ^= 7; else a += x >> 3; }
        x = x * 2862933555777941757ull + 3037000493ull;
    }
    double t1 = mono();
    volatile unsigned long long s = a; (void)s;
    return (t1 - t0) * 1e9 / (double)iters;
}

/* 混合"真实程序"负载：大量函数调用 + 指针追逐 + 分支 + 访存。
   最接近编译器/解释器/数据库这类真实软件的形态。 */
static unsigned long long __attribute__((noinline)) hash_step(unsigned long long h, unsigned char c) {
    return (h ^ c) * 1099511628211ull;
}
static unsigned long long __attribute__((noinline)) walk(const unsigned *next, unsigned i, int depth) {
    unsigned long long h = 1469598103934665603ull;
    for (int d = 0; d < depth; d++) {
        h = hash_step(h, (unsigned char)(next[i] & 0xff));
        i = next[i] & 0xffffu;
    }
    return h;
}
static int cmp_u(const void *a, const void *b) {
    unsigned x = *(const unsigned *)a, y = *(const unsigned *)b;
    return (x > y) - (x < y);
}
static double bench_real(long iters) {
    enum { N = 1 << 16 };
    static unsigned arr[N], next[N];
    unsigned long long st = 88172645463325252ull;
    for (int i = 0; i < N; i++) {
        st ^= st << 13; st ^= st >> 7; st ^= st << 17;
        arr[i] = (unsigned)st;
        next[i] = (unsigned)(st >> 16) & (N - 1);
    }
    double t0 = mono();
    unsigned long long acc = 0;
    long rounds = iters / 1000000 + 1;  /* 每轮约 8 ms，iters=3e6 就得 24 轮 ≈ 0.2 s，再乘 qsort 的实际成本 */
    for (long r = 0; r < rounds; r++) {
        qsort(arr, N, sizeof arr[0], cmp_u);       /* 大量调用 + 访存 */
        acc += walk(next, (unsigned)(r & (N - 1)), 64); /* 指针追逐 + 调用 */
        arr[r & (N - 1)] = (unsigned)acc;
    }
    double t1 = mono();
    volatile unsigned long long s = acc; (void)s;
    return (t1 - t0) * 1e9 / (double)rounds;  /* 每轮的 ns */
}

typedef double (*fn)(long);

int main(int argc, char **argv) {
    long n = (argc > 1 ? atol(argv[1]) : 2000000);
    /* bench3 <iters> <name>：只跑一个子基准，便于用宿主侧计时做整进程对比
       （进程内的 clock_gettime 在这台设备上会把 DVFS 波动算进结果）。 */
    struct { const char *name; fn f; } b[] = {
        {"alu   ", bench_alu},
        {"mem   ", bench_mem},
        {"call  ", bench_call},
        {"branch", bench_branch},
        {"real  ", bench_real},
    };
    const char *only = argc > 2 ? argv[2] : NULL;
    for (unsigned i = 0; i < sizeof b / sizeof *b; i++) {
        if (only && strncmp(b[i].name, only, strlen(only)) != 0) continue;
        b[i].f(n / 10 ? n / 10 : 1); /* 预热 */
        printf("%-7s %8.2f ns/iter\n", b[i].name, b[i].f(n));
    }
    return 0;
}
