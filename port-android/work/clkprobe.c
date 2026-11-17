/* 客户机时钟探针：把三个时间源同时打出来，和宿主侧对比。
   CNTFRQ 是内核认为的频率，CNTVCT 是内核读到的计数，
   clock_gettime 是用户态算出来的时间。 */
#include <stdio.h>
#include <time.h>
#include <stdint.h>

int main(void) {
    uint64_t frq, c1, c2, c3;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(frq));
    __asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(c1));
    struct timespec t1, t2;
    clock_gettime(CLOCK_MONOTONIC, &t1);
    /* 空转大约一小段时间 */
    for (volatile long i = 0; i < 30000000; i++) { }
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(c2));
    clock_gettime(CLOCK_MONOTONIC, &t2);
    __asm__ volatile("mrs %0, cntvct_el0" : "=r"(c3));

    double mono_ns = (t2.tv_sec - t1.tv_sec) * 1e9 + (t2.tv_nsec - t1.tv_nsec);
    double cnt_secs = (double)(c2 - c1) / (double)frq;
    printf("CNTFRQ_EL0   = %llu\n", (unsigned long long)frq);
    printf("CNTVCT delta = %llu counts\n", (unsigned long long)(c2 - c1));
    printf("  /CNTFRQ    = %.6f s   (内核相信的频率换算)\n", cnt_secs);
    printf("clock_gettime= %.6f s\n", mono_ns / 1e9);
    printf("ratio  clock/cnt = %.3f\n", (mono_ns / 1e9) / cnt_secs);
    return 0;
}
