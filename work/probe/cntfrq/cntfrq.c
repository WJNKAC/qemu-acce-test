/* 读 CNTFRQ_EL0 与实测计数器速率。
 *
 * 为什么需要它：Henge 的 counter() 假设 CNTFRQ = 24 MHz（Apple），
 * 而这台设备可能是 13 MHz / 19.2 MHz。移植层的 to24_mult 把它换算到
 * 24MHz 域，但换算的分子/分母里写死了设备频率 —— 换设备就会错。
 * 这个探针给出两个数：CNTFRQ 寄存器值，以及用 CLOCK_MONOTONIC 实测的速率。
 * 两者不一致说明 CNTFRQ 被固件报错了（MTK 上确实有这种情况）。
 *
 * EL0 可以直接读 CNTFRQ_EL0 / CNTVCT_EL0，不需要特权。
 */
#include <stdio.h>
#include <stdint.h>
#include <time.h>

static inline uint64_t rd_cntfrq(void) { uint64_t v; __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(v)); return v; }
static inline uint64_t rd_cntvct(void) { uint64_t v; __asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(v)); return v; }

int main(void) {
    uint64_t frq = rd_cntfrq();
    printf("CNTFRQ_EL0 = %llu  (%.3f MHz)\n", (unsigned long long)frq, frq / 1e6);

    struct timespec t0, t1;
    uint64_t c0, c1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    c0 = rd_cntvct();
    /* 500ms 足够，且不会因为设备 idle 而漂太多 */
    struct timespec req = {0, 500 * 1000 * 1000}, rem;
    while (nanosleep(&req, &rem) == -1) req = rem;
    c1 = rd_cntvct();
    clock_gettime(CLOCK_MONOTONIC, &t1);

    double ns = (t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec);
    double ticks = (double)(c1 - c0);
    printf("measured    = %.3f MHz  (%llu ticks / %.3f ms)\n",
           ticks / ns * 1e3, (unsigned long long)(c1 - c0), ns / 1e6);
    printf("ratio to CNTFRQ = %.4f\n", (ticks / ns * 1e9) / (double)frq);
    return 0;
}
