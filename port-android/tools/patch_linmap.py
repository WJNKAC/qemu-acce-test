"""LINMAP：按需开启的 EL1 linear map 特化通道。

## 为什么是"通道"而不是"优化"

linear map 的区间和偏移是**系统相关**的：Linux arm64 的 direct map 在 PAGE_OFFSET，
Windows 的内核 VA 布局完全不同，将来接别的系统又是另一套。所以引擎**不能**内置
任何具体数值 —— 它只提供一条"如果你告诉我 [base, base+len) 恒等于 host+delta，
我就能让这个区间的访问跳过 TLB 探测"的通道，由 runner 按需打开。

三条硬约束：

1. **默认关闭**。`nlinmap == 0` 时翻译期一条指令都不多发，行为与今天完全一致。
   配置错误、系统不认识、想关掉对比 —— 都只是不配置而已。
2. **不固化易变状态**。区间由配置显式给出，不探、不学、不猜。
   （第九轮 BANK_SEEN 的教训：靠运行期学习的东西都要等重编译，而热块永不重编译。）
3. **失败安全**。VA 不在区间内 → `b.hs` 落回原 TLB 探测，语义零变化。

## 责任边界（写清楚，因为这是配置者的义务）

引擎**无法**验证区间内的映射真的连续：它拿到 delta 就直接加。所以配置者必须保证
`[base, base+len)` 内每一个字节都满足 `host = va + delta` 且**全部已映射**。
否则不崩溃，但会读到错误的内存（ram 是 malloc 的一块，读越界不会立刻 segfault）。

这也是为什么这个通道**只开启给能自证的系统**（例如 Linux 的 direct map 覆盖全部 RAM）。

## 为什么只加速读

和 bank 同一条理由：写要过页粒度的撤销链（code_pages + whint + memop + 翻译作废），
而 linmap 只给 addend、不给权限判断，写命中会整条绕过。读没有撤销语义。

## 指令序列（命中 7 条 / 未命中 5 条后落回 TLB）

    ldr  T, #p(base)          ← literal pool，L1 必中
    sub  T, addr, T           ← off = va - base
    ldr  U, #p(len)
    cmp  T, U
    b.hs miss                 ← 不在区间，落回 4 KB 探测
    ldr  U, #p(delta)         ← U = addend（和 bank 命中同一个语义）
    b    after                ← 与 bank 共用 to_after 合流点

关键点：**linmap 命中只产出 addend**，所以它和 bank 命中走完全相同的合流路径，
不引入新的权限/失效语义。这也意味着它天然继承"读-only + 依赖 8 条 flush 路径"的性质。
"""

import os

# HvMachine：最多两段（Linux 的 direct map + 可能的第二个窗口；够用且好测）
LM_SLOTS = 2

MACHINE_ANCHOR = "    int slow_mem;        /* tests: send every load and store through hv_mem_emulate */"

MACHINE_FIELDS = """    int slow_mem;        /* tests: send every load and store through hv_mem_emulate */
    /* LINMAP: on-demand linear-map windows, configured by the runner (0 = off).
       A window asserts: for every VA in [base, base+len), host == VA + delta and
       the whole range is mapped.  The engine cannot verify that -- it is the
       configurator's contract.  Guest VA layout is system-specific (Linux
       PAGE_OFFSET vs Windows kernel VA), so nothing here is hardcoded. */
    struct { uint64_t base, len; int64_t delta; } linmap[2];
    int nlinmap;"""


def patch_machine_h(text):
    if text.count(MACHINE_ANCHOR) != 1:
        raise SystemExit("LINMAP: slow_mem 锚点 %d 处" % text.count(MACHINE_ANCHOR))
    text = text.replace(MACHINE_ANCHOR, MACHINE_FIELDS)
    # 让 runner 能用 #ifdef 判断这个通道编进来了没有
    hdr = "typedef struct HvMachine {"
    if text.count(hdr) != 1:
        raise SystemExit("LINMAP: HvMachine 锚点 %d 处" % text.count(hdr))
    return text.replace(hdr, "#define HV_LINMAP 1 /* LINMAP channel built in (still off until configured) */\n\n" + hdr)


# 命中数**不插桩**（差值法）：linmap 命中不填 TLB，所以
#   hits = refills(无 --linmap) - refills(有 --linmap)
# 理由见 MEASURE.md 第九轮：往探测序列里加计数 = 把刚消掉的税加回来。


# ---- translate.c：在 4 KB 探测之前发射区间比较 ----
# 锚点是 `if (!role)` 块里的那句（已确认全文件唯一）。
#
# 生成的结构（以 1 段为例，未命中 5 条 / 命中 6 条）：
#
#     ldr  T, #p(base)
#     sub  T, addr, T          off = va - base          （不写 flags）
#     ldr  U, #p(len)
#     sub  U, T, U             off - len                （不写 flags；off<len 时 bit63=1）
#     tbnz U, #63, hit         tbnz 不读 NZCV
#     [4 KB 探测]              未命中走这里
#     b    skip                探测结束，跳过命中桩
#   hit:
#     ldr  U, #p(delta)        U = addend = delta
#   skip:                     与 bank 命中同一个合流点（= 探测之后）
EMIT_ANCHOR = "    uint32_t tlb = put_tlb_slot(e, T, addr, el_idx);"

EMIT_CODE = """    /* LINMAP: on-demand linear-map windows.  EL1 data-read only.
       A hit yields nothing but an addend (= delta), so it joins exactly the same
       post-check path as a bank hit -- no new permission or invalidation
       semantics.  With nlinmap == 0 not a single instruction is emitted, so an
       unconfigured engine behaves byte-for-byte as before.

       The comparison must NOT touch NZCV: the whole TLB probe below is written
       under "Uses no flags", and later instructions rely on the incoming flags.
       Hence sub+sub+tbnz instead of cmp+b.hs.  (cmp here cost a deterministic
       crash after 5864 guest instructions, whatever the window was.) */
    uint32_t lm_hit_site[2];
    int lm_n_hit = 0;
    /* 临时寄存器：只从 {6,7,15}（唯一"不承载 guest 寄存器"的三个）里挑一个
       **不在 {addr, T, U} 中**的。
       曾经直接写死用 x7 —— 而 x7 正是 pick() 的候选之一，当 addr 被分到 7 时
       `sub U, addr, 7` 又退化成 x-x=0，off 恒 0 → 永远"命中" →
       拿 delta 当 addend → guest 读到错内存、跑飞（实测 fetch_walks 飙到 18 亿）。
       这就是 addr==T 那个坑换了个寄存器又踩一次。 */
    int lm_tmp = -1;
    for (int c = 0; c < 3; c++) {
        int r = c == 0 ? 6 : c == 1 ? 7 : 15;
        if (r != addr && r != T && r != U) { lm_tmp = r; break; }
    }
    uint32_t lm_skip_all = 0;
#ifdef LM_SKIPSEG
    /* 诊断：无条件跳过整段。指令**不执行**但仍占位置/占 literal。
       崩 → 布局类（位置相关/回填/literal 计数）；不崩 → 执行类。 */
    if (lm_tmp >= 0 && el_idx == 1 && !op.store && e->m->nlinmap > 0 && e->npool + 8 < MAX_LITS) {
        lm_skip_all = e->n;
        put(e, 0x14000000u);
    }
#endif
    if (lm_tmp >= 0 && el_idx == 1 && !op.store && e->m->nlinmap > 0 && e->npool + 8 < MAX_LITS) {
        for (int lw = 0; lw < e->m->nlinmap && lw < 2; lw++) {
            /* 关键：**不能写 addr** —— addr 可能就是 T（direct 且 op.rn 恰好是 T 时），
               那样 `sub T, addr, T` 会算成 T-T = 0，off 恒为 0，0-len 永远为负，
               tbnz 每次都跳 → linmap 永远"命中" → 装载 delta 当 addend → JIT 崩。
               （实测症状：x15 装的是 delta，区间配成 0xdead... 也照样跳。）
               所以差值算在 U 里，addr 只读不写。 */
            /* 临时寄存器用 x7：上游注释明确 "x7 is never a guest register"，
               所以 `sub U, addr, 7` 不会被 addr==T 那种自减抵消掉。
               （曾用 T 装 base：若 op.rn 恰好等于 T 的宿主编号，off 恒为 0，
               tbnz 恒跳，症状是区间配成 0xdead... 也"命中"。） */
            put_lit(e, lm_tmp, e->m->linmap[lw].base);
            put(e, SUB_X(U, addr, lm_tmp));                            /* U = va - base */
            put_lit(e, lm_tmp, e->m->linmap[lw].len);
            put(e, SUB_X(U, U, lm_tmp));                               /* U = off - len */
            lm_hit_site[lm_n_hit++] = e->n;
            /* tbnz 编码：0xb7000000 | (b5<<31) | (b40<<19) | (imm14<<5) | Rt。
               bit 63 → b5=1, b40=1 → 常数 0xb7080000。
               **不能写 `63u << 31`**：在 uint32 里它截断成 0x80000000，丢掉 b40，
               于是实际编成 "tbnz Rt, #31" —— 而 off-len 是个小负数，bit31 恒为 1，
               结果每次都跳（实测症状：区间配成 0xdead... 也照样"命中"，
               x15 里装的是 delta 而不是 addend，JIT 立刻崩）。 */
            put(e, @TBNZ63@ | (uint32_t)U);                          /* tbnz U, #63, hit */
        }
    }
#ifdef LM_SKIPSEG
    if (lm_skip_all) patch_branch(&e->w[lm_skip_all], (int64_t)e->n - lm_skip_all);
#endif
    uint32_t tlb = put_tlb_slot(e, T, addr, el_idx);"""

LM_TAIL = """    if (lm_n_hit) {
        uint32_t skip = e->n;
        put(e, 0x14000000u);                                  /* b skip: probe done */
        for (int i = 0; i < lm_n_hit; i++) {
            patch_branch(&e->w[lm_hit_site[i]], (int64_t)e->n - lm_hit_site[i]);
            put_lit(e, U, (uint64_t)e->m->linmap[i].delta);    /* U = addend */
        }
        patch_branch(&e->w[skip], (int64_t)e->n - skip);
    }"""

TAIL_FORMS = [
    # BANK=0（原样）
    ("""    slow = e->nool - 1;
    put(e, LDR_X(U, T, tlb + 24));
    }""",
     """    slow = e->nool - 1;
    put(e, LDR_X(U, T, tlb + 24));
""" + LM_TAIL + """
    }"""),
    # BANK=1（bank 已插入自己的回填，紧跟 LDR 之后）
    ("""    put(e, LDR_X(U, T, tlb + 24));
    if (to_after) patch_branch(&e->w[to_after], (int64_t)e->n - to_after);   /* BANK: 4 KB 命中后跳过 b */
    }""",
     """    put(e, LDR_X(U, T, tlb + 24));
    if (to_after) patch_branch(&e->w[to_after], (int64_t)e->n - to_after);   /* BANK: 4 KB 命中后跳过 b */
""" + LM_TAIL + """
    }"""),
]


def patch_translate_c(text):
    if os.environ.get('LM_SKIPSEG', '0') != '0':
        text = text.replace('#define MAX_LITS', '#define LM_SKIPSEG 1\n#define MAX_LITS')
    if text.count(EMIT_ANCHOR) != 1:
        raise SystemExit("LINMAP: put_tlb_slot 锚点 %d 处" % text.count(EMIT_ANCHOR))
    # 占位符在 EMIT_CODE 里，必须**先**把常量填进去，再插入 ——
    # 顺序反了就等于往文件里塞了个未替换的 @TBNZ63@（这一轮已经栽过一次）。
    import emit_check
    code = EMIT_CODE.replace('@TBNZ63@', '0x%08xu' % emit_check.tbnz(0, 63))
    text = text.replace(EMIT_ANCHOR, code)
    for old, new in TAIL_FORMS:
        if text.count(old) == 1:
            return text.replace(old, new)
    raise SystemExit("LINMAP: 两种尾部形态都没匹配上（bank 的顺序变了？）")
