/* 与 tests/bench_extra.S 逐条等价的 Linux 版本，用来在
   「原生」和「qemu-aarch64(TCG)」两条路径上跑同一段客人指令流。

   受控变量：每块的工作指令数 U ∈ {1,8,32}，三种 U 的工作单元总数相同
   (2^28)，所以总时间可直接比。

   c(U) = a + (2a + b) / U     a = 每条指令成本, b = 每次块转移成本
   由 U=1 与 U=32 两点解出 b，即"块转移一次等于几条 ALU 指令"。

   编译：aarch64-linux-gnu-gcc -O2 -static -o loops loops.c
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define OUTER1  256
#define OUTER8  32
#define OUTER32 8

#define STR2(x) #x
#define STR(x) STR2(x)

#define S1  "sub x5, x5, #1\n\t"
#define S8  S1 S1 S1 S1 S1 S1 S1 S1
#define S32 S8 S8 S8 S8

#define LOOP(U, OUTER, BODY)                                                   \
    static double loop_u##U(void) {                                            \
        struct timespec t0, t1;                                                \
        clock_gettime(CLOCK_MONOTONIC, &t0);                                   \
        __asm__ __volatile__(                                                  \
            "mov x5, #0\n\t"                                                   \
            "movz x3, #" STR(OUTER) "\n\t"                                         \
            ".p2align 4\n\t"                                                    \
            "1:\n\t"                                                           \
            "movz x2, #0x10, lsl #16\n\t"                                      \
            ".p2align 4\n\t"                                                    \
            "2:\n\t" BODY                                                      \
            "subs x2, x2, #1\n\t"                                              \
            "b.ne 2b\n\t"                                                      \
            "subs x3, x3, #1\n\t"                                              \
            "b.ne 1b\n\t"                                                      \
            :                                                                  \
            :                                                                  \
            : "x2", "x3", "x5", "cc", "memory");                               \
        clock_gettime(CLOCK_MONOTONIC, &t1);                                   \
        return (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6; \
    }

LOOP(1, OUTER1, S1)
LOOP(8, OUTER8, S8)
LOOP(32, OUTER32, S32)

int main(int argc, char **argv) {
    const char *only = argc > 1 ? argv[1] : NULL;
    struct { const char *n; double (*f)(void); } b[] = {
        {"u1", loop_u1}, {"u8", loop_u8}, {"u32", loop_u32},
    };
    const double work = 268435456.0;
    double c[3] = {-1, -1, -1};
    for (int i = 0; i < 3; i++) {
        if (only && strcmp(only, b[i].n) != 0) continue;
        double best = 1e18;
        for (int k = 0; k < 3; k++) {
            double v = b[i].f();
            if (v < best) best = v;
        }
        c[i] = best;
        printf("%-4s %8.4f ns/work  (%8.3f ms)\n", b[i].n, best * 1e6 / work, best);
    }
    if (c[0] > 0 && c[2] > 0) {
        double n1 = c[0] * 1e6 / work, n32 = c[2] * 1e6 / work;
        double a = (32 * n32 - n1) / 31.0;   /* 3a+b = n1 ; 34a+b = 32*n32 */
        double bb = n1 - 3 * a;
        printf("per-insn %.4f ns   per-block-transition %.4f ns  "
               "(= %.2f cycles @2.2GHz, %.2f insn-equiv)\n",
               a, bb, bb * 2.2, a > 0 ? bb / a : 0.0);
    }
    return 0;
}
