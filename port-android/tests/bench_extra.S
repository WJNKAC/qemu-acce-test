// 基本块大小受控实验（在 bench_programs.S 基础上追加）。
//
// 目的：同样多的 ALU 工作单元，但每个基本块里的指令数差 1/8/32 倍。
// 块越大 → 每单位工作要付的"块进出开销"越少。三条曲线拟合出：
//     c(U) = a + (2a + b) / U      a = 每条指令成本, b = 每次块转移成本
// 于是 b 就是"块转移一次等于几条 ALU 指令"，可直接和 TCG / 原生比。
//
// 三者的工作单元总数相同（268435456 = 256×2^20），所以总时间可直接比。
#include "harness.h"

    .text
    .p2align 14
    .globl bench_extra_begin
    .globl bench_extra_finish
bench_extra_begin:

// U=1：块内 1 条工作指令 + 2 条循环控制（subs / b.ne）
PROGRAM bench_u1
    mov x5, #0
    movz x3, #256
.p2align 4
1:
    movz x2, #0x10, lsl #16
.p2align 4
2:
    sub x5, x5, #1
    subs x2, x2, #1
    b.ne 2b
    subs x3, x3, #1
    b.ne 1b
END bench_u1

// U=8：块内 8 条工作指令 + 2 条循环控制
PROGRAM bench_u8
    mov x5, #0
    movz x3, #32
.p2align 4
1:
    movz x2, #0x10, lsl #16
.p2align 4
2:
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    subs x2, x2, #1
    b.ne 2b
    subs x3, x3, #1
    b.ne 1b
END bench_u8

// U=32：块内 32 条工作指令 + 2 条循环控制
PROGRAM bench_u32
    mov x5, #0
    movz x3, #8
.p2align 4
1:
    movz x2, #0x10, lsl #16
.p2align 4
2:
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    sub x5, x5, #1
    subs x2, x2, #1
    b.ne 2b
    subs x3, x3, #1
    b.ne 1b
END bench_u32

    .p2align 14
bench_extra_finish:
