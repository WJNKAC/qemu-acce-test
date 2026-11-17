/* <mach/mach_time.h> 的替身。
   整套引擎的时间域是 24 MHz（guest 的 CNTFRQ_EL0 = 24 MHz，WFI 自旋、
   定时器比较、统计窗口都按这个刻度算），所以这里把宿主的
   CNTVCT_EL0 换算到同一个 24 MHz 域再交出去，而不是换个时基糊上去。 */
#ifndef HV_COMPAT_MACH_TIME_H
#define HV_COMPAT_MACH_TIME_H

#include <stdint.h>

uint64_t hv_host_ticks_24mhz(void);
#define mach_absolute_time() hv_host_ticks_24mhz()

typedef struct mach_timebase_info {
    uint32_t numer;
    uint32_t denom;
} mach_timebase_info_data_t;

static inline int mach_timebase_info(mach_timebase_info_data_t *info) {
    /* 时钟是 24 MHz，所以要换成 ns 得乘 1e9/24e6 = 125/3。
       早先这里写的是 1/1，于是 mach_absolute_time()*tb.numer/tb.denom/1e6
       算出来的"毫秒"实际是微秒：所有基于它的计时都小了 41.67 倍
       （原项目 test_bench 打印的 ms 因此一直是错的）。 */
    info->numer = 125;
    info->denom = 3;
    return 0;
}

#endif
