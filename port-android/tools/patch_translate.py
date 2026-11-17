#!/usr/bin/env python3
"""生成 translate.c 的实验副本（原树保持只读）。

目前只有一个实验：**把 `ret x6` 改成 `mov x30, x6; ret`**。

动机：引擎的返回路径是
    ubfx/add/add/ldp/ldr/eor/eor/cbnz/ret x6
一条客机 `ret` 膨胀成 10 条宿主指令。而 `ret x6` 是**寄存器间接**返回 ——
ARM 的返回地址栈（RSB）通常只预测以链接寄存器（x30）为目标的 `ret`。
如果 A76 不预测 `ret x6`，那么每次 guest ret 都是一次间接跳转预测失败
（约 10–15 周期），这比那 10 条指令本身贵得多。

改法很便宜：`mov x30, x6` 再 `ret`。调用点本来就是 `bl L`（会向 RSB 压入 H），
所以 RSB 顶恰好就是这个 H，`ret` 能命中。

三个变体用 RET_MODE 选择：
    RET_MODE=0  原样 `ret x6`（基线）
    RET_MODE=1  `mov x30, x6; ret`（走 x30，力争 RSB 命中）
    RET_MODE=2  `br x6`（明确不走 RSB，作反向对照）

用法： patch_translate.py <src> <dst> [mode]
"""
import os
import sys

OLD = 'put(e, 0xd65f0000u | 6 << 5);'
# 原行的注释在右边，替换时把整行换掉更安全
OLD_LINE_HINT = '0xd65f0000u | 6 << 5'

V0 = 'put(e, 0xd65f0000u | 6 << 5);                                  /* ret x6 */'
V1 = ('put(e, MOV_X(30, 6));                                           /* mov x30, x6 */\n'
      '    put(e, 0xd65f0000u | 30 << 5);                                 /* ret (x30: lets the host RSB predict) */')
V2 = 'put(e, 0xd65f0000u | 6 << 5);                                  /* ret x6 */'


def convert(text, mode):
    # 找到唯一那处 `ret x6`
    idx = text.find('0xd65f0000u | 6 << 5')
    if idx < 0:
        raise SystemExit("找不到 `ret x6` 的生成处，translate.c 可能变了")
    if text.count('0xd65f0000u | 6 << 5') != 1:
        raise SystemExit("`ret x6` 出现不止一次，需要人工确认是哪一处")

    # 定位整行
    ls = text.rfind('\n', 0, idx) + 1
    le = text.find('\n', idx)
    line = text[ls:le]
    indent = line[:len(line) - len(line.lstrip())]

    if mode == 0:
        return text                      # 基线，不修改
    if mode == 1:
        new = V1
    elif mode == 2:
        new = 'put(e, BR_X(6));' + ' ' * 42 + '/* br x6: never predicted by the RSB */'
    else:
        raise SystemExit("mode 只能是 0/1/2")
    return text[:ls] + indent + new + text[le:]


HASH_OLD = 'put(e, UBFM_X(T, va, HV_TLB_PAGE_BITS, HV_TLB_PAGE_BITS + HV_TLB_BITS - 1));'
HASH_NEW = (
    '/* HASH=1: 索引改为"低位 ^ 高位折叠"。\n'
    '       直接映射 + 连续工作集 + 2 的整幂 = 每 2^BITS 页完美互踢：\n'
    '       512 MB 工作集正好 2 倍超订，命中率归零。折一位高位就散开。\n'
    '       代价：热路径多 2 条指令（ubfm 多取 1 位 + eor + 再掩回）。 */\n'
    '    put(e, UBFM_X(T, va, HV_TLB_PAGE_BITS, HV_TLB_PAGE_BITS + HV_TLB_BITS));\n'
    '    put(e, 0xca000000u | (uint32_t)HV_TLB_BITS << 10 | (uint32_t)T << 16 | (uint32_t)T << 5 | (uint32_t)T);\n'
    '    put(e, UBFM_X(T, T, 0, HV_TLB_BITS - 1));')


def patch_hash(text):
    if text.count(HASH_OLD) != 1:
        raise SystemExit("HASH 锚点匹配 %d 处" % text.count(HASH_OLD))
    return text.replace(HASH_OLD, HASH_NEW)



# ---- BANK=1：2 MB 块探测插在 4 KB 探测之前 ----
# 形状（命中 9 条，未命中 8 条后落回原 4 KB 探测）：
#     lsr   T, addr, #21
#     and   T, T, #(N-1)
#     lsl   T, T, #4            (16B/项；并入下面的 add 更好，但 add 的移位形式够用)
#     add   T, T, #0x401, lsl #12     ← bank 基址（4KB 对齐，见 HV_CPU_BANK）
#     add   T, x28, T
#     ldr   U, [T]
#     sub   U, addr, U
#     ubfm  U, U, #21, #63      ← 与 4 KB 表项同款检查，只是粒度 2MB
#     cbnz  U, 4k
#     ldr   U, [T, #8]          ← addend，之后与原路径合流
#     b     after
# 4k: <原来的 4 KB 探测>
# after:
BANK_OLD = """    if (!role) {
    uint32_t tlb = put_tlb_slot(e, T, addr, el_idx);"""

BANK_NEW = """    if (!role) {
    /* BANK：先探 2 MB 块。命中就跳过整次 refill（walk + whint + 表项写 + bloom），
       未命中落回下面的 4 KB 探测，代价 8 条指令。

       BANK_RD=1：只让**读**命中 bank。原因是 bank 项按 2 MB 块授权，而引擎的
       写撤销机制（code_pages + whint）是**页**粒度的：
         · 块内任一页变成代码后，写必须落回 4 KB 路径才会被 memop 捕获并作废翻译；
         · bank 命中会给出 addend 直接写宿主内存，整条撤销链被跳过（自修改代码
           静默失效，test_exc 的 p_smc_nomaint 就是这么挂的）。
       读没有撤销语义（读不会改内存），所以只让读命中是**结构上安全**的，
       不依赖"整块无代码页"这种时快照条件。 */
    uint32_t to_after = 0;   /* BANK: 4 KB 命中后从这里跳过那条 b，必须在外层作用域 */
    if (BANK_GATE) {
        uint32_t bank_off = (uint32_t)(HV_CPU_BANK >> 12);
        /* 索引：@IDXINSN@ 由 Python 按 BANK_UBFX 选择（ubfx 一条 / lsr+and 两条）。
           来源教训：lsr 的源寄存器写成 T 而不是 addr，探测读的是未初始化寄存器，
           症状是"填充正常、命中为零"，靠 dump JIT 逐条解码才看出来。 */
        @IDXINSN@
        put(e, ADD_LSL(T, 28, T, 4));                     /* add T, x28, T, lsl #4 */
        put(e, 0x91400000u | bank_off << 10 | (uint32_t)T << 5 | (uint32_t)T); /* add T, T, #0x401, lsl #12 */
        put(e, LDR_X(U, T, 0));
        put(e, SUB_X(U, addr, U));
        /* 让"跨 2 MB 块尾"的访问落回 4 KB 路径：ubfm #21 只比高位，
           块尾 slack 必须 ≥ bytes-1 才安全（4 KB 路径用同一条办法）。 */
        if (op.bytes > HV_TLB_ADJ + 1) put_add_imm(e, U, U, op.bytes - 1 - HV_TLB_ADJ);
        put(e, UBFM_X(U, U, 21, 63));
        uint32_t to_4k = e->n;
        put(e, CBNZ_X(U));
        put(e, LDR_X(U, T, 8));                           /* addend */
        @PROF_HIT@
        to_after = e->n;
        put(e, 0x14000000u);                              /* b after（下面回填） */
        patch_branch(&e->w[to_4k], (int64_t)e->n - to_4k);
    }
    uint32_t tlb = put_tlb_slot(e, T, addr, el_idx);"""


def patch_bank(text):
    if text.count(BANK_OLD) != 1:
        raise SystemExit("BANK translate: 锚点 %d 处" % text.count(BANK_OLD))
    text = text.replace(BANK_OLD, BANK_NEW)
    # BANK_RD=1：探测只读路径。BANK_RD=0（默认）：读写都探。
    gate = '!op.store' if os.environ.get('BANK_RD', '0') != '0' else '1'
    # BANK_EL=1：**按特权级分流**（用户提议的"合法版编译期分流"）。
    # 依据是静态量 el_idx（由块 flags 推导，翻译期就确定），不是易变的页表状态：
    #   EL0 块 → 保留 bank 探测（用户态数据面是 THP 主场，knee 靠它）
    #   EL1 块 → 整段不发射探测（启动期内核态占 88% 的 fill，全是 4KB，探测是纯税）
    # 实测依据（Debian 启动）：bank fills = el0 0 / el1 258263 —— boot 期 bank 的价值
    # 全部来自 EL1 那 5.7% 的 2MB 块；而 EL1 94.3% 的 fill 是 4KB，探测收不回来。
    if os.environ.get('BANK_EL', '0') != '0':
        gate = 'el_idx == 0' if gate == '1' else '(!op.store && el_idx == 0)'
    # BANK_SEEN=1：把"EL0 一律探测"换成"这一页见过 2MB block 才探测"。
    # 依据仍是翻译期可得的量：e->bram（本块所在 RAM）+ e->bpg（本块的页号），
    # 是引擎自己的 per-page 标记，不是 guest 页表，也不看 ASID / THP 状态。
    if os.environ.get('BANK_SEEN', '0') != '0':
        gate = gate.replace('el_idx == 0',
                            'el_idx == 0 && e->bram && e->bram->bank_seen && e->bram->bank_seen[e->bpg]')
    # 索引：ubfx 一条 或 lsr+and 两条。BANK_UBFX=0 保留旧写法用作对照。
    if os.environ.get('BANK_UBFX', '1') != '0':
        idx = "put(e, UBFM_X(T, addr, 21, 21 + HV_BANK_BITS - 1));"
    else:
        idx = ("put(e, 0xd3400000u | 21 << 16 | 33 << 10 | (uint32_t)addr << 5 | (uint32_t)T);\n"
               "        put(e, 0x92400000u | 0u << 16 | (uint32_t)(HV_BANK_BITS - 1) << 10 | (uint32_t)T << 5 | (uint32_t)T);")
    text = text.replace('@IDXINSN@', idx)
    text = text.replace('if (BANK_GATE) {',
                        'if (%s) {   /* BANK %s */' % (gate, 'read only' if gate != '1' else 'read+write'))
    # 在 4 KB 探测段的末尾回填 b after —— 锚点是 put(e, LDR_X(U, T, tlb + 24));
    tail = """    slow = e->nool - 1;
    put(e, LDR_X(U, T, tlb + 24));
    }"""
    if text.count(tail) != 1:
        raise SystemExit("BANK translate: 尾部锚点 %d 处" % text.count(tail))
    text = text.replace(tail, """    slow = e->nool - 1;
    put(e, LDR_X(U, T, tlb + 24));
    @PROF_K4@
    if (to_after) patch_branch(&e->w[to_after], (int64_t)e->n - to_after);   /* BANK: 4 KB 命中后跳过 b */
    }""")

    # ---- BANKPROF：三桶计数（必须放在所有 text 替换之后：@PROF_K4@ 是上面 tail 才引入的）----
    # 访问总数 N = bank 命中 + 4 KB 命中 + refill；前两项在 JIT 里数，第三项 stats.refills 已有
    # （refill 只在两者皆 miss 时发生，所以三桶互补，不需要单独数 miss）。
    # 只在插桩变体里加（每次访存多 3 条 ldr/add/str）。插桩变体只用来量**比率**，
    # 时间一律用干净变体测，两者互不污染。
    # ---- 为什么这里**没有** JIT 插桩 ----
    # 试过：在 bank 命中 / 4 KB 命中两条路径各加 ldr/add/str 计数。踩到一个硬约束 ——
    # bank 在 x28+0x401000（4 MB 外），计数桶紧跟其后（+38920），而 LDR_X 的 imm12
    # 只覆盖 4095*8=32760：38920/8=4865 溢出到 Rn 位，指令编码整体错乱，
    # 计数写进野地址 —— 症状是"fills 正常但 hits 恒为 0"，和当初 lsr 写错寄存器一模一样。
    # 要修就得两步寻址（add #hi,lsl #12 + ldr #lo），至少 6 条指令且要占第 4 个寄存器
    # （此时 T 是表项指针、U 是 addend，都不能动）。
    #
    # 改用**差值法**，零插桩零污染：
    #   bank_hit = refills(BANK=0) - refills(BANK=1)     ← bank 承接掉的那部分
    #   k4_hit   = N - refills(BANK=0)                    ← 只剩 4 KB 路径时命中数
    #   N        = knee 的 STEPS = 16M（固定）
    # 前提是两次运行的 guest 访问序列一致，用 translated_insns 校验。
    text = text.replace('\n        @PROF_HIT@', '').replace('\n    @PROF_K4@', '')
    text = text.replace('@PROF_HIT@', '').replace('@PROF_K4@', '')
    return text




# ---- BANK_SEEN：Emit 需要"本块属于哪块 RAM、哪一页" ----
EMIT_OLD = "    uint64_t page;       /* guest VA of the 16 KB page the block is in */"
EMIT_NEW = ("    uint64_t page;       /* guest VA of the 16 KB page the block is in */\n"
            "    struct HvRam *bram;  /* BANK_SEEN: the RAM this block lives in */\n"
            "    uint64_t bpg;        /* BANK_SEEN: its page index there */")

ASSIGN_OLD = "    e->page = b->va & ~((1ull << HV_TLB_PAGE_BITS) - 1);"
ASSIGN_NEW = ("    e->page = b->va & ~((1ull << HV_TLB_PAGE_BITS) - 1);\n"
              "    e->bram = b->ram;   /* BANK_SEEN */\n"
              "    e->bpg = b->pg;")


def patch_bank_seen_emit(text):
    for old, new, what in ((EMIT_OLD, EMIT_NEW, "Emit.page"),
                           (ASSIGN_OLD, ASSIGN_NEW, "e->page assign")):
        if text.count(old) != 1:
            raise SystemExit("BANK_SEEN: %s anchor %d" % (what, text.count(old)))
        text = text.replace(old, new)
    return text


def main():
    src, dst = sys.argv[1], sys.argv[2]
    mode = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    with open(src, encoding='utf-8') as f:
        text = f.read()
    import os
    if os.environ.get('HASH', '0') != '0':
        text = patch_hash(text)
    if os.environ.get('LINMAP', '0') != '0':
        # 独立于 BANK：LINMAP 只加"区间比较 + 常数 addend"，不依赖 bank 的任何状态。
        # 注意顺序 —— 必须在 patch_bank 之后（尾部锚点要看到 bank 插入的回填）。
        pass
    if os.environ.get('BANK', '0') != '0':
        text = patch_bank(text)
        if os.environ.get('BANK_SEEN', '0') != '0':
            text = patch_bank_seen_emit(text)
    if os.environ.get('LINMAP', '0') != '0':
        import patch_linmap
        text = patch_linmap.patch_translate_c(text)
    out = convert(text, mode)
    with open(dst, 'w', encoding='utf-8') as f:
        f.write(out)
    if mode:
        print("patched %s -> %s (RET_MODE=%d)" % (src, dst, mode))


if __name__ == '__main__':
    main()
