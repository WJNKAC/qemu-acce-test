/*
 * Host 单元测试：把 hv_classify() 的判定与 aarch64 汇编器的真值表对拍。
 *
 * 为什么在 host 上做，而不是进 guest 跑：
 *   枚举位域空间要几万到几十万条指令。进 guest 每轮开机 20 秒起，
 *   而这里几秒跑完；而且分类错误是「看起来在正常工作、结果一直是错的」
 *   那一类 bug，需要全量对拍才发现得了单条抽样漏掉的分支。
 *
 * 真值从哪来：不在本文件里硬编码。用 aarch64-linux-gnu-as 汇编每条候选指令，
 * 再用 objdump -d 反解出它的编码和助记符，作为「标准答案」。这样上游
 * 更新 decode 之后，重跑一次就能看出哪一条分类变了。
 *
 * 与引擎的关系：直接链 core/classify.c，调用同一个 hv_classify()。
 * 引擎改了分类逻辑，这个测试立刻能感知。
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "classify.h"

/* 一条待测指令：编码 + 它的助记符（来自汇编器，不是我们自己猜的）。 */
typedef struct { uint32_t insn; char mnem[24]; } Case;

static Case cases[400000];
static int ncase;

/* 助记符 → 期望的类别。只覆盖本测试枚举到的那些。 */
static HvInsnKind expect_of(const char *m)
{
    /* 去掉后缀：b.eq -> b, ldxr x0,[x1] 已经是首词 */
    if (!strncmp(m, "b.", 2))            return HV_INSN_BRANCH;
    if (!strcmp(m, "b") || !strcmp(m, "bl"))            return HV_INSN_BRANCH;
    if (!strcmp(m, "cbz") || !strcmp(m, "cbnz"))        return HV_INSN_BRANCH;
    if (!strcmp(m, "tbz") || !strcmp(m, "tbnz"))        return HV_INSN_BRANCH;
    if (!strcmp(m, "br") || !strcmp(m, "blr") || !strcmp(m, "ret"))
        return HV_INSN_BRANCH_REG;
    if (!strcmp(m, "adr") || !strcmp(m, "adrp"))        return HV_INSN_PCREL;
    if (!strcmp(m, "ldr") || !strcmp(m, "ldrsw") || !strcmp(m, "prfm")) {
        /* literal 形式由调用方按移位字段区分，见 check_case() */
        return HV_INSN_MEMORY;
    }

    /* 所有 memory 族（load/store/atomic/exclusive/pair） */
    static const char *mem[] = {
        "str","strb","strh","ldrb","ldrh","ldrsb","ldrsh","ldur","stur",
        "ldursw","ldxr","stxr","ldaxr","stlxr","ldxp","stxp","ldaxp","staxp",
        "ldar","stlr","ldarb","ldarh","stlrb","stlrh","cas","casa","casl",
        "casal","casb","cash","casp","ldadd","ldadda","ldaddl","ldaddal",
        "ldclr","ldeor","ldset","ldsmax","ldsmin","ldumax","ldumin","swp",
        "ld1","st1","ld2","st2","ld3","st3","ld4","st4", NULL
    };
    for (int i = 0; mem[i]; i++) if (!strcmp(m, mem[i])) return HV_INSN_MEMORY;

    static const char *bar[] = { "dsb","dmb","isb","clrex","sb", NULL };
    for (int i = 0; bar[i]; i++) if (!strcmp(m, bar[i])) return HV_INSN_BARRIER;

    static const char *wt[] = { "wfi","wfe","wfit","wfet", NULL };
    for (int i = 0; wt[i]; i++) if (!strcmp(m, wt[i])) return HV_INSN_WAIT;

    static const char *exc[] = { "svc","hvc","smc","brk","hlt","dcps1","dcps2","dcps3", NULL };
    for (int i = 0; exc[i]; i++) if (!strcmp(m, exc[i])) return HV_INSN_EXCEPTION;

    static const char *pac[] = { "paciasp","pacibsp","autiasp","autibsp",
                                 "pacia","pacib","autia","autib","xpaci","xpacd","pacga", NULL };
    for (int i = 0; pac[i]; i++) if (!strcmp(m, pac[i])) return HV_INSN_PAC;

    if (!strcmp(m, "eret") || !strcmp(m, "eretaa") || !strcmp(m, "eretab"))
        return HV_INSN_ERET;
    return HV_INSN_COPY;   /* 其余（ALU/SIMD/HINT）都是原样复制 */
}

/* 读 objdump 的输出：每行形如
 *     0:\t58000040 \tldr\tx0, 8 <x>
 *     0:\td5033bdf \tdsb\tsy
 */
static int load_cases(const char *path)
{
    FILE *f = fopen(path, "r");
    char line[512];

    if (!f) return -1;
    while (fgets(line, sizeof line, f)) {
        char hex[32], mn[32];
        char *p = strchr(line, ':');
        char *tab;

        if (!p) continue;
        tab = strchr(p, '\t');
        if (!tab) continue;
        if (sscanf(tab + 1, "%31s", hex) != 1) continue;
        tab = strchr(tab + 1, '\t');
        if (!tab) continue;
        if (sscanf(tab + 1, "%31s", mn) != 1) continue;
        if (strlen(hex) != 8) continue;              /* 不是 4 字节对齐的行 */
        if (ncase >= (int)(sizeof cases / sizeof cases[0])) break;
        cases[ncase].insn = (uint32_t)strtoul(hex, NULL, 16);
        snprintf(cases[ncase].mnem, sizeof cases[ncase].mnem, "%s", mn);
        ncase++;
    }
    fclose(f);
    return ncase;
}

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "sweep.objdump";
    int n, bad = 0;

    n = load_cases(path);
    if (n <= 0) {
        fprintf(stderr, "no cases from %s (rc=%d)\n", path, n);
        return 2;
    }
    printf("loaded %d instructions from %s\n", n, path);

    for (int i = 0; i < n; i++) {
        HvInsnKind want = expect_of(cases[i].mnem);
        HvInsnKind got  = hv_classify(cases[i].insn);

        /* LDR/PRFM 的 literal 形式要看编码本身，不看助记符 */
        if (!strcmp(cases[i].mnem, "ldr") || !strcmp(cases[i].mnem, "ldrsw") ||
            !strcmp(cases[i].mnem, "prfm")) {
            uint32_t opc = (cases[i].insn >> 24) & 0x3;
            int is_literal = ((cases[i].insn >> 24) & 0x3f) == 0x18 ||
                             ((cases[i].insn >> 24) & 0x3f) == 0x1c;
            (void)opc;
            if (is_literal)
                want = !strcmp(cases[i].mnem, "prfm")
                     ? HV_INSN_PREFETCH : HV_INSN_LOAD_LITERAL;
        }

        if (got != want) {
            if (bad < 40)
                printf("MISMATCH insn=%08x mnem=%-10s want=%-18s got=%s\n",
                       cases[i].insn, cases[i].mnem,
                       hv_insn_kind_name(want), hv_insn_kind_name(got));
            bad++;
        }
    }

    printf("\n%d cases, %d mismatches\n", n, bad);
    if (bad)
        printf("-> decode 与汇编器的真值不一致，见上面的编码\n");
    else
        printf("-> 全部一致\n");
    return bad ? 1 : 0;
}
