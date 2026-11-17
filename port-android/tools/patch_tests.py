#!/usr/bin/env python3
"""给上游测试源打"可控跳过"补丁（原树只读，产物写到 build/tsrc/）。

为什么需要：test_mem 的每个用例都先**原生**跑一遍作对照，再用 JIT 跑。
设备是 Cortex-A55（ARMv8.2），`atomics` 用例里的 `ldapur/stlur/ldapursb`
属于 FEAT_LRCPC2（v8.4）—— 原生执行直接 SIGILL，整个进程死在第 6 个用例，
于是后面 13 个用例 × 3 种模式的 JIT 覆盖（尤其 mode 2 "MMU on"）全都不跑了。

这不是引擎缺陷（已用 `ldapur` 三行的裸汇编在设备上复现：exit=132），
但会挡住建言。补 `HV_SKIP=atomics` 开关：按名字跳过，其余照跑。
"""

import sys

ANCHOR_MAIN = """    setvbuf(stdout, NULL, _IONBF, 0);
"""

INSERT_MAIN = """    setvbuf(stdout, NULL, _IONBF, 0);
    /* HV_SKIP="atomics,pac": 跳过本机原生跑不了的用例（宿主缺某条指令时，
       native 对照会 SIGILL 并中断整个套件）。 */
    const char *skip_list = getenv("HV_SKIP");
"""

ANCHOR_LOOP = """            const TestProgram *p = &programs[i];
"""

INSERT_LOOP = """            const TestProgram *p = &programs[i];
            if (skip_list && strstr(skip_list, p->name)) continue;
            if (getenv("HV_STAGE")) fprintf(stderr, "[%s/%d] native\\n", p->name, mode);
"""

ANCHOR_JIT = """            int bad = run_jit(&m, p, &init, &jit, mode == 2 ? mmu_on : NULL);"""

INSERT_JIT = """            if (getenv("HV_STAGE")) fprintf(stderr, "[%s/%d] jit\\n", p->name, mode);
            int bad = run_jit(&m, p, &init, &jit, mode == 2 ? mmu_on : NULL);"""


def main():
    src, dst = sys.argv[1], sys.argv[2]
    text = open(src, encoding="utf-8").read()
    for anchor, ins, what in ((ANCHOR_MAIN, INSERT_MAIN, "main"), (ANCHOR_LOOP, INSERT_LOOP, "loop"),
                              (ANCHOR_JIT, INSERT_JIT, "jit")):
        n = text.count(anchor)
        if n != 1:
            raise SystemExit("patch_tests: %s 锚点 %d 处" % (what, n))
        text = text.replace(anchor, ins)
    open(dst, "w", encoding="utf-8").write(text)


if __name__ == "__main__":
    main()
