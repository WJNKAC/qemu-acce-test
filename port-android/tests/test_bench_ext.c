/* 引擎 JIT 的"块转移开销"直测（不经过 Linux 客户机）。
 *
 * 和 src/WindowsiOS/tests/test_bench.c 的区别：多了 bench_u1/u8/u32 三个
 * 受控基本块程序（见 bench_extra.S），用来量"每转移一次基本块要付多少"。
 *
 * 用法： test_bench_ext [程序名]
 *        HV_DUMP=file  导出每个已翻译块 (guest VA, guest 指令数, 宿主字数)
 */
#include "harness.h"

#include <mach/mach_time.h>

#include "translate.h"
#include <stdlib.h>

DECLARE_PROGRAM(bench_calls);
DECLARE_PROGRAM(bench_mem);
DECLARE_PROGRAM(bench_dispatch);
DECLARE_PROGRAM(bench_loop);
DECLARE_PROGRAM(bench_u1);
DECLARE_PROGRAM(bench_u8);
DECLARE_PROGRAM(bench_u32);
extern const char bench_programs_begin[], bench_programs_finish[];
extern const char bench_extra_begin[], bench_extra_finish[];

/* bench_u1/u8/u32 的工作单元总数完全相同：256/32/8 × 2^20 × U = 2^28 */
#define WORK_UNITS (268435456.0)

static const TestProgram programs[] = {
    TEST_PROGRAM(bench_u1), TEST_PROGRAM(bench_u8), TEST_PROGRAM(bench_u32),
    TEST_PROGRAM(bench_loop), TEST_PROGRAM(bench_calls),
    TEST_PROGRAM(bench_dispatch), TEST_PROGRAM(bench_mem),
};
/* 每块工作单元数；0 = 不是受控块实验，不报 ns/work */
static const int unroll[] = {1, 8, 32, 0, 0, 0, 0};

/* EL0: 间接跳转缓存只对低（用户）地址生效，和客户机里跑时一致 */
static void at_el0(HvCpu *cpu) {
    cpu->el = 0;
    cpu->spsel = 0;
}

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    static HvMachine m;
    if (hv_machine_init(&m, 4 << 20) != 0) return 1;
    m.chain = 1;
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)bench_programs_begin,
                       bench_programs_finish - bench_programs_begin, (void *)bench_programs_begin, 1);
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)bench_extra_begin,
                       bench_extra_finish - bench_extra_begin, (void *)bench_extra_begin, 1);
    uint8_t *stack = aligned_alloc(16384, 65536);
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)stack, 65536, stack, 0);
    uint64_t sp = (uint64_t)(uintptr_t)stack + 32768;
    const char *only = argc > 1 ? argv[1] : NULL;

    printf("%-15s %9s %9s %7s %11s %11s %9s\n",
           "program", "native_ms", "jit_ms", "jit/nat", "dispatches", "chained", "ns/work");
    int failed = 0;
    for (size_t i = 0; i < sizeof programs / sizeof programs[0]; i++) {
        const TestProgram *p = &programs[i];
        if (only && strcmp(only, p->name) != 0) continue;
        static HvCpu init, native, jit;
        memset(&init, 0, sizeof init);
        seed_cpu(&init, i + 1, sp);
        double tn = 1e9, tj = 1e9;
        uint64_t entries = 0, chained = 0;
        for (int k = 0; k < 5; k++) {
            double t0 = now_ms();
            native = init;
            hv_native_run(&native, p->native);
            double t1 = now_ms();
            uint64_t b0 = m.stats.blocks, c0 = m.stats.chained;
            if (run_jit(&m, p, &init, &jit, at_el0)) return 1;
            entries = m.stats.blocks - b0;
            chained = m.stats.chained - c0;
            double t2 = now_ms();
            if (t1 - t0 < tn) tn = t1 - t0;
            if (k && t2 - t1 < tj) tj = t2 - t1;   /* 第一次含翻译 */
        }
        int bad = unroll[i] && native.x[5] != jit.x[5];
        char nsw[24] = "-";
        if (unroll[i]) snprintf(nsw, sizeof nsw, "%.4f", tj * 1e6 / WORK_UNITS);
        printf("%-15s %9.3f %9.3f %7.2f %11llu %11llu %9s%s\n", p->name, tn, tj, tj / tn,
               (unsigned long long)entries, (unsigned long long)chained, nsw,
               bad ? "  WRONG" : "");
        failed += bad;
    }
    if (getenv("HV_DUMP")) {
        FILE *f = fopen(getenv("HV_DUMP"), "wb");
        for (int i = 0; f && i < m.nblocks; i++) {
            HvBlock *b = &m.blocks[i];
            uint32_t *end = i + 1 < m.nblocks ? m.blocks[i + 1].code : m.jit.base + m.jit.used;
            uint64_t hdr[3] = {b->va, b->ninsns, (uint64_t)(end - b->code)};
            fwrite(hdr, sizeof hdr, 1, f);
            fwrite((const void *)(uintptr_t)b->va, 4, b->ninsns, f);
            fwrite(b->code, 4, (size_t)(end - b->code), f);
        }
        if (f) fclose(f);
    }
    return failed != 0;
}
