/* 直接验证 plat_linux.c 的 24MHz 时基换算是否真的产出 24MHz 刻度：
   用宿主自己的 clock_gettime 量 1 秒，看 hv_host_ticks_24mhz 走了多少 tick。 */
#include <stdio.h>
#include <time.h>
#include <stdint.h>

uint64_t hv_host_ticks_24mhz(void);
uint64_t hv_host_cntfrq(void);

static double now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

int main(void) {
    printf("host CNTFRQ_EL0 = %llu\n", (unsigned long long)hv_host_cntfrq());
    uint64_t a = hv_host_ticks_24mhz();
    double w0 = now();
    /* 睡 1 秒（宿主的真实时间） */
    struct timespec s = {1, 0};
    nanosleep(&s, NULL);
    uint64_t b = hv_host_ticks_24mhz();
    double w1 = now();
    double wall = w1 - w0;
    double ticks_sec = (double)(b - a) / 24e6;
    printf("wall %.4f s, ticks/24MHz %.4f s, ratio %.3f\n", wall, ticks_sec, ticks_sec / wall);
    printf("%s\n", (ticks_sec / wall > 0.97 && ticks_sec / wall < 1.03) ? "OK: 24MHz domain is correct"
                                                                     : "BAD: timebase is wrong");
    return 0;
}
