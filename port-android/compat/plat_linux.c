/* Linux/Android 平台垫片：时基与 I-cache 维护。
   引擎内部的时间单位是 24 MHz tick，见 compat/mach/mach_time.h 的说明。 */
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>

#include "TargetConditionals.h"

#define HV_TICK_HZ 24000000ull

static uint64_t host_cntfrq = 1;   /* CNTFRQ_EL0，启动时读一次 */
static uint64_t to24_mult = 1;     /* 24e6 << 32 / cntfrq */
static uint32_t to24_shift = 32;

/* Darwin 的 commpage：core/translate.c 在【翻译时】读 0xfffffc090 的一个字节，
   据此决定 guest 的 CNTVCT 读指令该展开成"原生 mrs + 加一个偏移"还是走 helper。
   这个地址在 Linux 上没人映射，读它就是 SIGSEGV——第一次跑内核时炸的正是这里。

   这里在 0xfffffc000 铺一页零页，于是那个字节读到 0，translate_counter 走
   "return 0"（不内联），指令落到通用 MRS helper，helper 再走 hv_counter()
   → mach_absolute_time() → 我们换算到 24 MHz 的实现。数值口径完全一致，
   代价是每次读计数器多一次 helper 调用（Linux 里主要是 sched_clock/delay，
   不在最热路径上）。原树一个字都不用改。 */
#define HV_COMMPAGE_SHIM_PA 0xfffffc000ull
#define HV_COMMPAGE_SHIM_SZ 0x1000ull

static void map_commpage_shim(void) {
    void *want = (void *)(uintptr_t)HV_COMMPAGE_SHIM_PA;
    void *p = mmap(want, HV_COMMPAGE_SHIM_SZ, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p != want) {
        if (p != MAP_FAILED) munmap(p, HV_COMMPAGE_SHIM_SZ);
        p = mmap(want, HV_COMMPAGE_SHIM_SZ, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    }
    if (p != want)
        fprintf(stderr, "hv-linux: warning: cannot map the commpage shim at %#llx; "
                        "guest counter reads will fault while translating\n",
                (unsigned long long)HV_COMMPAGE_SHIM_PA);
}

__attribute__((constructor)) static void hv_plat_init(void) {
    map_commpage_shim();
    uint64_t frq;
    __asm__ volatile("mrs %0, cntfrq_el0" : "=r"(frq));
    if (frq == 0) frq = HV_TICK_HZ;
    host_cntfrq = frq;
    if (frq == HV_TICK_HZ) {
        to24_mult = 1;
        to24_shift = 0;
    } else {
        /* 24e6/cntfrq 的定点表示：cntfrq 是 13/19.2/25/50 MHz 这类值，
           32 位小数足够，误差远低于 1 tick/秒。 */
        to24_mult = (HV_TICK_HZ << 32) / frq;
        to24_shift = 32;
    }
}

uint64_t hv_host_ticks_24mhz(void) {
    uint64_t c;
    __asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(c));
    if (to24_shift == 0) return c;
    return (uint64_t)(((__uint128_t)c * (__uint128_t)to24_mult) >> to24_shift);
}

uint64_t hv_host_cntfrq(void) { return host_cntfrq; }

void sys_icache_invalidate(void *start, size_t len) {
    __builtin___clear_cache((char *)start, (char *)start + len);
}
