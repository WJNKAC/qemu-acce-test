/*
 * bench.c —— 并行计算微基准（initramfs 的 rdinit）
 *
 * 目的：回答"smp4 在 henge 内是否真的并行、扩展性如何"，而不是只看启动 wall。
 * 做同样的工作量：1 线程一次，T 线程各做一次（T = min(在线 CPU, 4)），
 * 用 CLOCK_MONOTONIC（guest 的 arch timer）测时，打印 T1/TN/加速比。
 *
 * 自校准：先跑 2M 次估单次迭代成本，再定 N 使单线程约 0.5 s（TCG 下也自适应）。
 * 结束时 poweroff，让 QEMU 干净退出（henge 的 SYSTEM_OFF 路径）。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <time.h>
#include <sched.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/reboot.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <linux/reboot.h>

static uint64_t N;
static volatile uint64_t g_chk;
static uint64_t work(uint64_t n)
{
    uint64_t x = 88172645463325252ull;
    for (uint64_t i = 0; i < n; i++) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
    }
    return x;
}

static void *thr(void *arg)
{
    *(uint64_t *)arg = work(N);
    g_chk ^= *(uint64_t *)arg;
    return NULL;
}

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

int main(void)
{
    cpu_set_t set;
    uint64_t a = 0, t0, t1;

    /*
     * PID 1's stdio is /dev/console only if the kernel managed to open it; in
     * an initramfs that is not always true (devtmpfs may mount later).  Open it
     * explicitly and use it for the result, so a benchmark never runs silently.
     */
    {
        int cfd;
        /*
         * The initramfs has no /dev at all (the kernel prints "unable to open
         * an initial console" and PID 1's stdio is /dev/null).  As PID 1 we
         * hold CAP_MKNOD, so create the console node ourselves.
         */
        mkdir("/dev", 0755);
        mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1));
        cfd = open("/dev/console", O_WRONLY | O_NOCTTY);
        if (cfd < 0) {
            mknod("/dev/ttyAMA0", S_IFCHR | 0600, makedev(204, 64));
            cfd = open("/dev/ttyAMA0", O_WRONLY | O_NOCTTY);
        }
        if (cfd >= 0) {
            dup2(cfd, 1);
            dup2(cfd, 2);
        }
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("BENCH start\n");
    CPU_ZERO(&set);
    sched_getaffinity(0, sizeof set, &set);
    int cpus = CPU_COUNT(&set);

    N = 2000000;
    t0 = now_ns();
    a = work(N);
    t1 = now_ns();
    double per = (double)(t1 - t0) / (double)N;
    if (per > 0.0) {
        N = (uint64_t)(0.5e9 / per);
    }
    if (N < 1000000ull) N = 1000000ull;
    if (N > 400000000ull) N = 400000000ull;

    /*
     * Phase sweep with the same work per thread: N, 2N, 4N.  Ideal tT == t1
     * (T cores), so the effective parallelism is P_T = T * t1 / tT.  Measuring
     * all phases in one boot keeps the host's frequency state comparable; t1 is
     * measured twice and the smaller value is used (first touch is cold).
     */
    uint64_t t1a, t1b, t1_ns, t2_ns = 0, t4_ns = 0;
    t0 = now_ns();
    a = work(N);
    g_chk ^= a;
    t1a = now_ns() - t0;
    t0 = now_ns();
    a ^= work(N);
    g_chk ^= a;
    t1b = now_ns() - t0;
    t1_ns = t1a < t1b ? t1a : t1b;
    for (int T = 2; T <= 4; T += 2) {
        pthread_t th[4];
        uint64_t out[4] = {0, 0, 0, 0};
        uint64_t ta, tb;
        if (T > cpus) break;   /* oversubscribing a guest CPU tells nothing */
        t0 = now_ns();
        for (int i = 0; i < T; i++) pthread_create(&th[i], NULL, thr, &out[i]);
        for (int i = 0; i < T; i++) pthread_join(th[i], NULL);
        ta = now_ns() - t0;
        t0 = now_ns();
        for (int i = 0; i < T; i++) pthread_create(&th[i], NULL, thr, &out[i]);
        for (int i = 0; i < T; i++) pthread_join(th[i], NULL);
        tb = now_ns() - t0;
        if (T == 2) t2_ns = ta < tb ? ta : tb;
        if (T == 4) t4_ns = ta < tb ? ta : tb;
    }
    printf("BENCH cpus=%d n=%llu t1_us=%llu t2_us=%llu t4_us=%llu "
           "p2_x1000=%llu p4_x1000=%llu per_iter_ns=%llu chk=%llx\n",
           cpus, (unsigned long long)N,
           (unsigned long long)(t1_ns / 1000),
           (unsigned long long)(t2_ns / 1000), (unsigned long long)(t4_ns / 1000),
           (unsigned long long)(t2_ns ? (2ull * t1_ns * 1000ull / t2_ns) : 0),
           (unsigned long long)(t4_ns ? (4ull * t1_ns * 1000ull / t4_ns) : 0),
           (unsigned long long)(t1_ns / (N ? N : 1)),
           (unsigned long long)g_chk);

    sync();
    reboot(LINUX_REBOOT_CMD_POWER_OFF);
    return 0;
}
