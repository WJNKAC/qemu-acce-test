"""BANK：2 MB 块翻译缓存（快路径一级探测）。

设计约束（每一条都来自前几轮的实测失败）：

1. **容量 ≥ 2 × 块数**。512 槽 vs 1024 块 = 3.2% 命中（实测），所以 N=2048
   起，8 GB → 8192。每项 16 B，N=2048 → 32 KB，L2 常驻。
2. **索引错开 2 MB 的整幂**。`idx=(va>>21)&(N-1)`：块号连续时 1024 块落在
   0..1023，与 2048 槽无冲突；块数超过 N 时靠 `BANK_FOLD` 折高位
   （与 HASH=1 同款手法，4 KB 表上已验证 474.7→340.7）。
3. **只缓存"整块同权限且可写"的块**。PMD 旧版死因是块内权限不同 → 命中后走错
   路径（99.4% 命中反而慢 46%）。这里只让 `w && !readonly` 的块入 bank，
   只读/代码块一律不进 —— 它们落回 4 KB 路径，权限精确。
   代价：块内一旦有页变成代码，必须整块作废（见 4）。
4. **失效挂满**。bank 失效 = memset 32 KB（比 epoch 慢，但不会漏）。
   挂 8 条 flush 路径 + protect_code_page（后者是必需的：代码页变成代码后，
   写入必须重新走 4 KB 路径才能被 whint 抓到）。

为什么 bank 命中要跳过整个 refill：
   消融已证明 refill 里 walk 只占 3%，成本在 whint(28%)、表项写、bloom。
   bank 命中直接给出 addend，**不填 4 KB 表项、不碰 whint**，所以省的是
   整次 refill（~500 ns），不是 walk（~15 ns）。
"""

import os

# HvCpu 里插 bank：紧跟 ret_tab 之后，正好 4 KB 对齐（0x401000），
# 且在那之前没有任何 C-only 字段，所以不影响已有偏移。
CPU_H_AFTER_RETTAB = """    uint8_t ret_tab[HV_IJC_TABLES][HV_RET_TAB_BYTES];"""

CPU_H_BANK = """    uint8_t ret_tab[HV_IJC_TABLES][HV_RET_TAB_BYTES];

    /* BANK：2 MB 块翻译缓存。放在 ret_tab 之后 —— 这个位置正好是 4 KB 的
       整数倍（HV_CPU_BANK），翻译出的代码可以用一条 `add T, T, #imm, lsl #12`
       定位它；再往后就是只有 C 会碰的字段，插在这里不动任何已有偏移。
       {tag, addend}：tag = block_va - HV_TLB_ADJ，检查方式与 4 KB 表项同款
       （sub + ubfm #21），只是粒度换成 2 MB。 */
    uint64_t bank[2 * HV_BANK_SIZE] __attribute__((aligned(16)));
    /* BANK 占用表：失效/反查只走"活着"的槽，O(占用) 而不是 O(HV_BANK_SIZE)。
       used = "该槽已在 live 表里"（与 tag 是否有效无关）。 */
    uint8_t bank_used[HV_BANK_SIZE];
    uint16_t bank_live[HV_BANK_SIZE];
    uint16_t bank_n;
    uint8_t bank_ready;     /* 数组是否已被擦成"空"（未复位的 CPU 可能是全零 BSS） */
    /* BANKPROF：三桶计数。只有插桩变体在 JIT 里 +1（每次访存 3 条指令），
       干净变体不加。访问总数 = bank_hits + k4_hits + refills（三者互补）。 */
    uint64_t bank_hits, k4_hits;"""

BANK_DEFINES = """#define HV_BANK_BITS 11
#define HV_BANK_SIZE (1u << HV_BANK_BITS)
#define HV_BANK_FOLD 0   /* 块数 > HV_BANK_SIZE 时置 1，把高位折进索引 */
#define HV_CPU_BANK (HV_CPU_RET_TAB + HV_IJC_TABLES * HV_RET_TAB_BYTES)
/* bank 数组之后依次是 used(1B/槽) + live(2B/槽) + n(2B) + ready(1B)，然后对齐到 8。
   这串算术很脆，所以下面用 _Static_assert 把它钉在 offsetof 上 —— 字段一挪动就编不过，
   而不是悄悄让 JIT 数到别的字段上去。 */
#define HV_CPU_BANK_HITS (HV_CPU_BANK + 2 * HV_BANK_SIZE * 8 + HV_BANK_SIZE + 2 * HV_BANK_SIZE + 8)
#define HV_CPU_BANK_K4HITS (HV_CPU_BANK_HITS + 8)"""


def bankprof_define():
    """BANKPROF 时告诉 C 侧"JIT 里真的在计数"，否则 sum 会打出一排 0 让人误判。"""
    return "\n#define HV_BANKPROF 1" if os.environ.get('BANKPROF', '0') != '0' else ""


def patch_cpu_h(text):
    if text.count(CPU_H_AFTER_RETTAB) != 1:
        raise SystemExit("BANK: ret_tab 锚点 %d 处" % text.count(CPU_H_AFTER_RETTAB))
    text = text.replace(CPU_H_AFTER_RETTAB, CPU_H_BANK)
    # 把 #define 放在 HV_CPU_RET_TAB 那一组后面
    anchor = "#define HV_CPU_RET_TAB 0x201000 /* just past the TLB */"
    if anchor not in text:
        # BITS 变体里这条已被改写，改用行前缀匹配
        import re
        m = re.search(r"#define HV_CPU_RET_TAB 0x[0-9a-f]+[^\n]*", text)
        if not m:
            raise SystemExit("BANK: 找不到 HV_CPU_RET_TAB")
        text = text[:m.end()] + "\n" + BANK_DEFINES + bankprof_define() + text[m.end():]
    else:
        text = text.replace(anchor, anchor + "\n" + BANK_DEFINES + bankprof_define())
    # 布局自检
    text = text.replace('_Static_assert(offsetof(HvCpu, ret_tab) == HV_CPU_RET_TAB, "HvCpu layout");',
                        '_Static_assert(offsetof(HvCpu, ret_tab) == HV_CPU_RET_TAB, "HvCpu layout");\n'
                        '_Static_assert(offsetof(HvCpu, bank) == HV_CPU_BANK, "BANK layout");\n'
                        '_Static_assert(offsetof(HvCpu, bank_hits) == HV_CPU_BANK_HITS, "BANKPROF layout");\n'
                        '_Static_assert(offsetof(HvCpu, k4_hits) == HV_CPU_BANK_K4HITS, "BANKPROF layout");')
    return text


# ---- mmu.c ----
HELPER = """/* ---- BANK ---- */
/* "空"值：低 21 位是 0x...80，而合法 tag 的低 21 位恒为 2MB-15，
   所以它永不匹配。全零反而危险（等于"块从 VA 0 起"），见 hv_bank_reset。 */
#define HV_BANK_EMPTY 0x8080808080808080ull

/* 失效只清"活着"的那些槽：启动期的调用极其频繁（每次进程切换、每次代码页保护），
   全表 32 KB memset 会变成纯开销 —— 4 核启动实测 +14% 就是这么来的。
   bank_used 表示"该槽已在 live 表里"，与 tag 是否有效无关：
   drop 只把 tag 作废，保留 used，避免同一个块被反复追加。 */
static inline void bank_invalidate(HvCpu *cpu) {
    if (!cpu->bank_ready) {
        /* 第一次用：数组可能是全零（静态 BSS、或没走 hv_cpu_reset 的 CPU）。
           全零 tag 会让 VA < 2 MB 假命中 → 读宿主地址 0。整表擦一次，之后走 live 表。 */
        memset(cpu->bank, 0x80, sizeof cpu->bank);
        memset(cpu->bank_used, 0, sizeof cpu->bank_used);
        cpu->bank_n = 0;
        cpu->bank_ready = 1;
        return;
    }
    for (uint32_t i = 0; i < cpu->bank_n; i++) {
        uint32_t b = cpu->bank_live[i];
        cpu->bank[2 * b] = HV_BANK_EMPTY;
        cpu->bank_used[b] = 0;
    }
    cpu->bank_n = 0;
}

/* hv_cpu_reset_index 会把整个 HvCpu memset 成 0，连 bank 一起 —— 而**全零的 tag
   是危险的**：检查是 `addr - tag < 2 MB`，tag=0 就等价于"这个块从 VA 0 开始"，
   于是 VA < 2 MB 的每一次访问都会假命中，addend 取到 0，直接读宿主地址 0 → SIGSEGV
   （test_mem 一开机就崩，就是这么挂的）。所以复位末尾必须补一次真失效值 ——
   这一次是全表 memset（每个 CPU 只做一次，无所谓）。 */
void hv_bank_reset(HvCpu *cpu) {
    memset(cpu->bank, 0x80, sizeof cpu->bank);
    memset(cpu->bank_used, 0, sizeof cpu->bank_used);
    cpu->bank_n = 0;
    cpu->bank_ready = 1;
}

/* 精确失效一条（VA 落在哪一块就丢哪一块）。整表 memset 是 32 KB，
   而每页 TLBI 在启动期极其频繁 —— 全表清会让 bank 变成纯开销（实测 12.9 s → 30.8 s）。 */
static inline void bank_drop_va(HvCpu *cpu, uint64_t va) {
    uint32_t b = (uint32_t)((va >> 21) & (HV_BANK_SIZE - 1));
    cpu->bank[2 * b] = HV_BANK_EMPTY;
}

/* 一个范围：块数不多就逐块丢，太多（大范围 TLBI）就整表清。 */
static inline void bank_drop_range(HvCpu *cpu, uint64_t va, uint64_t len) {
    uint64_t first = va >> 21, n = (len >> 21) + 2;
    if (n > 32) { bank_invalidate(cpu); return; }
    for (uint64_t i = 0; i < n; i++)
        cpu->bank[2 * (((first + i) & (HV_BANK_SIZE - 1)))] = HV_BANK_EMPTY;
}

/* 某页变成代码：块内任何一条可写映射都必须作废，否则写入绕过 whint。
   这里只有 PA 页号，没有 VA，所以按 addend 反查哪些块覆盖它。 */
static inline void bank_drop_host_page(HvCpu *cpu, const uint8_t *host_page) {
    for (uint32_t i = 0; i < cpu->bank_n; i++) {
        uint32_t b = cpu->bank_live[i];
        uint64_t tag = cpu->bank[2 * b];
        if (tag == HV_BANK_EMPTY) continue;
        const uint8_t *start = (const uint8_t *)(uintptr_t)(tag + HV_TLB_ADJ + cpu->bank[2 * b + 1]);
        if ((uintptr_t)host_page - (uintptr_t)start < (1u << 21)) cpu->bank[2 * b] = HV_BANK_EMPTY;
    }
}
"""

FILL_AFTER = """    if (e->write_tag != HV_TLB_INVALID) write_guard(cpu, ram, pg, hv_tlb_code(slot, table), e);"""

# 整块无代码页的扫描：只在"写也走 bank"（BANK_RD=0）时才需要。
# BANK_RD=1 时读不改变内存，不需要按块排除代码页 —— 而这次扫描是 512 字节/每
# 次 fill，18 M 次 fill 就是几十 MB 的无谓读，正是启动退化的嫌疑人之一。
FILL_SCAN = """    int block_clean = ram->ncode == 0;
    if (!block_clean) {
        uint64_t b0 = (page_pa & ~((1ull << 21) - 1) & ~(uint64_t)PAGE_MASK) - ram->pa;
        b0 >>= HV_TLB_PAGE_BITS;
        if (b0 + 512 <= (ram->size >> HV_TLB_PAGE_BITS)) {
            block_clean = 1;
            for (uint32_t i = 0; i < 512; i++)
                if (__atomic_load_n(&ram->code_pages[b0 + i], __ATOMIC_RELAXED)) { block_clean = 0; break; }
        }
    }
"""

FILL_BANK = """    if (e->write_tag != HV_TLB_INVALID) write_guard(cpu, ram, pg, hv_tlb_code(slot, table), e);
    /* BANK：2 MB 块描述符的线性映射，addend 全块恒定，记进块缓存。
       关键：不能要求 pa/va 都是 2 MB 对齐（那只有块首页能进，覆盖 1/512）。
       块描述符保证 addend 在整个块内恒定，所以只要两者的"块内偏移"相等即可。 */
@SCAN@    if (block_clean && w->block_size >= (1ull << 21) && w->w && !ram->readonly &&
        (page_pa & ((1ull << 21) - 1)) == (page_va & ((1ull << 21) - 1))) {
        uint64_t bva = page_va & ~((1ull << 21) - 1);
        uint32_t b = (uint32_t)((bva >> 21) & (HV_BANK_SIZE - 1));
#if HV_BANK_FOLD
        b = (uint32_t)(((bva >> 21) ^ (bva >> (21 + HV_BANK_BITS))) & (HV_BANK_SIZE - 1));
#endif
        if (!cpu->bank_used[b]) { cpu->bank_used[b] = 1; cpu->bank_live[cpu->bank_n++] = (uint16_t)b; }
        cpu->bank[2 * b + 0] = bva - HV_TLB_ADJ;
        cpu->bank[2 * b + 1] = (uint64_t)e->addend;
        /* BANK_SEEN：第一次在某页见到 2MB block 时置位，并把 page_gen 推一格，
           让这一页的块下次查找时失效重编译 —— 重编译时才会发射探测。
           （只推一次：靠 bank_seen 去重。） */
        if (ram->bank_seen && !ram->bank_seen[pg]) {
            ram->bank_seen[pg] = 1;
            __atomic_add_fetch(&ram->page_gen[pg], 1, __ATOMIC_SEQ_CST);
            if (cpu->m->stats_interval) cpu->m->stats.bank_seen_set++;
        }
        if (cpu->m->stats_interval) {
            cpu->m->stats.bank_fills++;
            if (el >= 0 && el < 4) cpu->m->stats.bank_fill_el[el]++;
        }
    }"""


def patch_mmu_c(text):
    # helper 放在第一个使用者之前（hv_tlb_flush）
    anchor = "void hv_tlb_flush(HvCpu *cpu) {"
    if text.count(anchor) != 1:
        raise SystemExit("BANK: hv_tlb_flush 锚点 %d 处" % text.count(anchor))
    text = text.replace(anchor, HELPER + "\n" + anchor)

    # EL 分布：tlb_fill 入口计一次（每次 fill 都经过这里，light/helper 都算）
    tf = "static void tlb_fill(HvCpu *cpu, uint64_t va, int el, const HvWalk *w) {\n"
    if text.count(tf) != 1:
        raise SystemExit("BANK: tlb_fill 锚点 %d 处" % text.count(tf))
    text = text.replace(tf, tf +
        "    /* BANK: EL 分布 —— 决定 EL1 能否去掉 bank 探测的唯一依据。 */\n"
        "    if (cpu->m->stats_interval && el >= 0 && el < 4) cpu->m->stats.fill_el[el]++;\n")

    # 填充
    if text.count(FILL_AFTER) != 1:
        raise SystemExit("BANK: write_guard 调用点 %d 处" % text.count(FILL_AFTER))
    rd = os.environ.get('BANK_RD', '0') != '0'
    fill = FILL_BANK.replace('@SCAN@', '' if rd else FILL_SCAN)
    if rd:
        # 读-only：不需要"整块无代码页"这个时快照条件
        fill = fill.replace('    if (block_clean && w->block_size',
                            '    if (w->block_size')
    # BANK_EL=1：填充也收成 EL0-only。
    # 否则 EL1 的 2MB 块照样被写进 bank（bank_used/bank_live 的 bookkeeping 白做），
    # 而 EL1 块已经不发射探测了 —— 填了没人查。实测残差 +2.1s 里有一份是这个。
    if os.environ.get('BANK_EL', '0') != '0':
        fill = fill.replace('    if (w->block_size >= (1ull << 21)',
                            '    if (el == 0 && w->block_size >= (1ull << 21)')
        if 'el == 0 && w->block_size' not in fill:
            raise SystemExit("BANK_EL: 填充条件未改到")
    if os.environ.get('BANK_SEEN', '0') == '0':
        # BANK_SEEN 关闭时把那段置位代码整段删掉（字段也不存在，留着会编不过）
        a = fill.find('        /* BANK_SEEN：')
        b = fill.find('        if (cpu->m->stats_interval) {', a)
        if a > 0 and b > a:
            fill = fill[:a] + fill[b:]
    text = text.replace(FILL_AFTER, fill)

    # 失效：8 条 flush 路径 + protect_code_page
    hooks = [
        ("void hv_tlb_flush(HvCpu *cpu) {\n", "void hv_tlb_flush(HvCpu *cpu) {\n    bank_invalidate(cpu); /* BANK */\n"),
        ("void hv_tlb_flush_user(HvCpu *cpu) {\n", "void hv_tlb_flush_user(HvCpu *cpu) {\n    bank_invalidate(cpu); /* BANK */\n"),
        ("void hv_tlb_flush_user_range(HvCpu *cpu, uint64_t va, uint64_t len) {\n",
         "void hv_tlb_flush_user_range(HvCpu *cpu, uint64_t va, uint64_t len) {\n    bank_drop_range(cpu, va, len); /* BANK */\n"),
        ("void hv_tlb_flush_kernel_range(HvCpu *cpu, uint64_t va, uint64_t len) {\n",
         "void hv_tlb_flush_kernel_range(HvCpu *cpu, uint64_t va, uint64_t len) {\n    bank_drop_range(cpu, va, len); /* BANK */\n"),
        ("void hv_tlb_flush_va_asid(HvCpu *cpu, uint64_t va, int asid) {\n",
         "void hv_tlb_flush_va_asid(HvCpu *cpu, uint64_t va, int asid) {\n    bank_drop_va(cpu, va); /* BANK */\n"),
        ("void hv_tlb_flush_va(HvCpu *cpu, uint64_t va) {\n",
         "void hv_tlb_flush_va(HvCpu *cpu, uint64_t va) {\n    bank_drop_va(cpu, va); /* BANK */\n"),
        # protect 必须在 protect_code_page（"某一页变成了代码"）时整块作废：
        # 否则块内那条写入会绕过 whint，自修改代码就漏了。
        ("void hv_tlb_protect_code_page(HvCpu *cpu, HvRam *ram, uint64_t pg) {\n",
         "void hv_tlb_protect_code_page(HvCpu *cpu, HvRam *ram, uint64_t pg) {\n"
         "    bank_drop_host_page(cpu, ram->host + (pg << HV_TLB_PAGE_BITS)); /* BANK */\n"),
        ("void hv_tlb_protect_code(HvCpu *cpu, const uint8_t *host_page) {\n",
         "void hv_tlb_protect_code(HvCpu *cpu, const uint8_t *host_page) {\n    bank_drop_host_page(cpu, host_page); /* BANK */\n"),
        # 进程切换（ttbr0 变了）：bank 里没有地址空间键，旧进程的块翻译对
        # 新进程来说是**错的 addend** —— 直接读到别人的宿主内存。test_mem 段错误
        # 就是这个（4 KB 表有 stash/ASID，bank 没有）。
        ("    if (old == now) return;\n",
         "    if (old == now) return;\n"
         "    /* BANK: bank 项里没有地址空间键 —— 换了 ttbr0 就必须整表作废，否则新进程\n"
         "       会用旧进程的 addend 读到别人的宿主内存（test_mem 段错误就是这么来的）。\n"
         "       代价是 O(bank_n) 次写（不是 32 KB memset：ready 之后只清 live 项），\n"
         "       但 switch_user 在启动期是高频路径，所以计数以便和上下文切换数对账。 */\n"
         "    if (cpu->m && cpu->m->stats_interval) { cpu->m->stats.bank_inv_switch++; cpu->m->stats.switch_user++; }\n"
         "    bank_invalidate(cpu);\n"),
    ]
    rd = os.environ.get('BANK_RD', '0') != '0'
    if rd and os.environ.get('BANK_NOPROT') != '0':
        # 只读 bank：代码页变代码这件事与"读"无关（读不改内存），
        # 所以这两条保护钩子对只读版是纯开销 —— 而启动期每次代码页保护都会调用它，
        # 原来的实现是 O(HV_BANK_SIZE) 扫描，实测把 4 核启动拖慢 14%。
        hooks = [h for h in hooks if 'protect_code' not in h[0]]
    rd = os.environ.get('BANK_RD', '0') != '0'
    if rd and os.environ.get('BANK_NOPROT') != '0':
        # 只读 bank：代码页变代码这件事与"读"无关（读不改内存），
        # 所以这两条保护钩子对只读版是纯开销 —— 而启动期每次代码页保护都会调用它，
        # 原来的实现是 O(HV_BANK_SIZE) 扫描，实测把 4 核启动拖慢 14%。
        hooks = [h for h in hooks if 'protect_code' not in h[0]]
    for old, new in hooks:
        if text.count(old) != 1:
            raise SystemExit("BANK: flush 钩子 %r 匹配 %d 处" % (old.split('(')[0], text.count(old)))
        text = text.replace(old, new)
    return text


def patch_ram_ncode(text):
    """HvRam 加一个"代码页计数"。bank 只在整块无代码页时才能入 ——
    否则写代码页会绕过 whint（test_exc 的 p_smc_nomaint 就是这么挂的）。"""
    old = "    uint8_t *code_pages; /* one byte per 16 KB page: a translated block came from here (2^pages_log2 of them) */"
    if text.count(old) != 1:
        raise SystemExit("BANK: code_pages 字段 %d 处" % text.count(old))
    out = text.replace(old, old + "\n    uint32_t ncode;     /* BANK: 已变成代码的页数（0 时入 bank 不必扫描整块） */")
    if os.environ.get('BANK_SEEN', '0') != '0':
        # per 4KB page, 1 byte: this page saw a 2MB block. Read at translate time.
        out = out.replace(old, old +
            "\n    uint32_t ncode;     /* BANK */\n"
            "    uint8_t *bank_seen; /* BANK_SEEN: per-page \"2MB block seen here\" (perf hint) */")
        out = out.replace("    uint32_t ncode;     /* BANK */\n    uint8_t *bank_seen;",
                          "    uint8_t *bank_seen;")
    return out


def patch_dispatch_ncode(text):
    old = "__atomic_store_n(&ram->code_pages[pg], 1, __ATOMIC_SEQ_CST);"
    if text.count(old) != 1:
        raise SystemExit("BANK: code_pages 置位 %d 处" % text.count(old))
    return text.replace(old, old + "\n        __atomic_add_fetch(&ram->ncode, 1, __ATOMIC_RELAXED); /* BANK */")


def patch_machine_c(text):
    """hv_cpu_reset_index 里补"真失效值"，否则 memset(cpu,0) 之后的 bank 会让
    VA < 2 MB 的访问假命中（tag=0 等价于块从 VA 0 起，addend=0 → 读宿主地址 0）。"""
    proto = "void hv_cpu_reset_index(HvCpu *cpu, HvMachine *m, uint32_t index) {"
    if text.count(proto) != 1:
        raise SystemExit("BANK machine.c: hv_cpu_reset_index %d 处" % text.count(proto))
    text = text.replace(proto, "void hv_bank_reset(HvCpu *cpu); /* BANK */\n\n" + proto)
    old = """    memset((char *)cpu + b + sizeof cpu->pc_state, 0, sizeof *cpu - b - sizeof cpu->pc_state);
    cpu->m = m;"""
    if text.count(old) != 1:
        raise SystemExit("BANK machine.c: reset memset 锚点 %d 处" % text.count(old))
    return text.replace(old, """    memset((char *)cpu + b + sizeof cpu->pc_state, 0, sizeof *cpu - b - sizeof cpu->pc_state);
    hv_bank_reset(cpu); /* BANK */
    cpu->m = m;""")
    if os.environ.get('BANK_SEEN', '0') != '0':
        # bank_seen：per 4KB 页 1 字节，跟 code_pages 同尺寸
        a = "    r->code_pages = calloc((size_t)1 << r->pages_log2, 1);"
        if text.count(a) != 1:
            raise SystemExit("BANK_SEEN: calloc 锚点 %d 处" % text.count(a))
        text = text.replace(a, a + "\n    r->bank_seen = calloc((size_t)1 << r->pages_log2, 1); /* BANK_SEEN */")
        f = "        free(m->ram[i].code_pages);"
        if text.count(f) != 1:
            raise SystemExit("BANK_SEEN: free 锚点 %d 处" % text.count(f))
        text = text.replace(f, f + "\n        free(m->ram[i].bank_seen); /* BANK_SEEN */")
    return text


def patch_machine_h(text):
    if text.count("    uint64_t refills;") != 1:
        raise SystemExit("BANK: refills 字段 %d 处" % text.count("    uint64_t refills;"))
    return text.replace("    uint64_t refills;",
                        "    uint64_t refills;\n"
                        "    uint64_t bank_fills, bank_hits; /* BANK */\n"
                        "    /* BANK：失效代价对账。switch_user 是每次地址空间切换都来一发，\n"
                        "       而 bank 没有 ASID，只能整表作废 —— 这是启动期的一笔潜在税，\n"
                        "       必须知道频度才能判断它值多少。 */\n"
                        "    uint64_t bank_inv_switch, bank_inv_all, switch_user;\n"
                        "    /* 按 EL 分桶。决定\"EL1 该不该去掉 bank 探测\"的唯一依据：\n"
                        "       EL1 的 fill 里有多少是 2 MB 块（bank 接得住）vs 4 KB（接不住）。\n"
                        "       内核 linear map 通常是 2 MB/1 GB 块 —— 与\"EL1 全是 4KB\"的直觉相反，\n"
                        "       所以必须先量再改。 */\n"
                        "    uint64_t fill_el[4], bank_fill_el[4];\n"
                        "    uint64_t bank_seen_set;")
