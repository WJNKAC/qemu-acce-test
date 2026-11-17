"""WHINT：把 whint 从 pages×HV_MAX_CPUS 个 uint64 压缩成每页 1 字节的 CPU 位图。

两件事一起解决：

1) **正确性**：原实现用 16 位字段存 `hv_tlb_code()`，而 BITS=16 时编码是
   `table << 16 | slot`（最大 196607，需 18 位）→ **静默截断成 0**
   → 被当成"空槽"跳过 → 代码页的陈旧可写表项永不失效。
   这是改 BITS 时引入的洞，位图顺手修掉。

2) **性能**：数组是 `pages × HV_MAX_CPUS` 个 uint64：2 GB guest = 32 MB，
   按页号随机索引，每次可写填充必然 cache miss（消融实测占 refill 28%）。
   位图只有 `pages` 字节（2 GB → 512 KB，能进 L2）。

代价：protect 时失去"是哪个表项"的精度 → 退化成整表扫描（HV_TLB_SIZE×3 项）。
而 protect 每页一生只发生一次，所以要在两个场景分别确认：
knee（纯数据，protect≈0，纯赚）与 Debian 启动（protect 有量）。
"""


def _sub1(text, old, new, what):
    if text.count(old) != 1:
        raise SystemExit("WHINT %s: 期望 1 处，实际 %d 处" % (what, text.count(old)))
    return text.replace(old, new)


FIELD_OLD = "    uint64_t *whint;"
FIELD_NEW = "    uint8_t *whint;   /* WHINT: 每页 1 字节，位 = cpu 索引（原 pages×8 个 uint64） */"

ALLOC_OLD = "    r->whint = calloc(pages * HV_MAX_CPUS, sizeof *r->whint);"
ALLOC_NEW = "    r->whint = calloc(pages, 1); /* WHINT */"

GUARD_OLD = """    uint64_t *hint = &ram->whint[pg * HV_MAX_CPUS + cpu->index];
    uint64_t mine = code + 1, old = __atomic_load_n(hint, __ATOMIC_RELAXED), now = old;
    const uint8_t *host_page = ram->host + (pg << HV_TLB_PAGE_BITS);
    if (!(old & HV_WHINT_MANY)) {
        /* Up to three entries: this one, in a free place or one whose entry maps
           something else by now; beyond that the protector scans. */
        int have = 0, place = -1;
        for (int k = 0; k < 3; k++) {
            uint64_t c = old >> (16 * k) & 0xffff;
            if (c == mine) have = 1;
            else if (place < 0 && (!c || !maps_writable(&cpu->tlb[0] + (c - 1), host_page))) place = k;
        }
        if (!have) now = place >= 0 ? (old & ~(0xffffull << (16 * place))) | mine << (16 * place) : HV_WHINT_MANY;
        if (now != old) __atomic_store_n(hint, now, __ATOMIC_RELAXED);
    }"""

GUARD_NEW = """    /* WHINT: 每页 1 字节的 CPU 位图。原来存 3 个 16 位表项编码，
       BITS=16 下编码需 18 位、会截断成 0（被当空槽），是个静默正确性洞。 */
    uint8_t *hint = &ram->whint[pg];
    uint8_t bit = (uint8_t)(1u << cpu->index);
    const uint8_t *host_page = ram->host + (pg << HV_TLB_PAGE_BITS);
    (void)code;
    if (!(__atomic_load_n(hint, __ATOMIC_RELAXED) & bit))
        __atomic_fetch_or(hint, bit, __ATOMIC_RELAXED);"""

PROT_OLD = """    uint64_t *hint = &ram->whint[pg * HV_MAX_CPUS + cpu->index];
    uint64_t h = __atomic_exchange_n(hint, 0, __ATOMIC_SEQ_CST);
    const uint8_t *host_page = ram->host + (pg << HV_TLB_PAGE_BITS);
    if (cpu->m) if (cpu->m->stats_interval) cpu->m->stats.protect_kind[h & HV_WHINT_MANY ? 2 : h ? 1 : 0]++;
    if (h & HV_WHINT_MANY) {
        hv_tlb_protect_code(cpu, host_page);
        return;
    }
    for (int k = 0; k < 3; k++) {
        uint64_t c = h >> (16 * k) & 0xffff;
        if (!c) continue;
        HvTlbEntry *e = &cpu->tlb[0] + (c - 1);
        if (maps_writable(e, host_page)) e->write_tag = HV_TLB_INVALID;
    }"""

PROT_NEW = """    /* WHINT: 只知道自己写过这一页，不知道是哪个表项 → 整表扫描。
       每页一生只走一次，只在"可写页变成代码"时。 */
    uint8_t bit = (uint8_t)(1u << cpu->index);
    uint8_t was = __atomic_fetch_and(&ram->whint[pg], (uint8_t)~bit, __ATOMIC_SEQ_CST);
    const uint8_t *host_page = ram->host + (pg << HV_TLB_PAGE_BITS);
    (void)maps_writable;
    int hit = (was & bit) != 0;
    if (cpu->m) if (cpu->m->stats_interval) cpu->m->stats.protect_kind[hit ? 2 : 0]++;
    if (hit) hv_tlb_protect_code(cpu, host_page);"""


# ---- WHINT=2：字段 16 位 → 20 位（只修截断，不改行为）----
# 3 个 20 位字段 = 60 位，位 63 留给 HV_WHINT_MANY，正好放进 uint64。
# BITS=16 时 hv_tlb_code() 最大 196607（需 18 位），20 位够。
# 内存不变（仍是 pages×HV_MAX_CPUS×8），但**不再有静默截断**，
# 也不引入全表扫描 —— 对这个变量是纯粹的 bug fix，零性能变化。

GUARD_W20 = GUARD_OLD.replace("0xffff", "0xfffff").replace("16 * k", "20 * k").replace("16 * place", "20 * place")
PROT_W20 = PROT_OLD.replace("0xffff", "0xfffff").replace("16 * k", "20 * k")


def patch_machine_h_w20(text):
    return text      # 字段类型不变


def patch_machine_c_w20(text):
    return text      # 分配不变


def patch_mmu_c_w20(text):
    text = _sub1(text, GUARD_OLD, GUARD_W20, "write_guard(w20)")
    text = _sub1(text, PROT_OLD, PROT_W20, "protect_code_page(w20)")
    return text


def patch_machine_h(text):
    return _sub1(text, FIELD_OLD, FIELD_NEW, "字段")


def patch_machine_c(text):
    return _sub1(text, ALLOC_OLD, ALLOC_NEW, "分配")


def patch_mmu_c(text):
    text = _sub1(text, GUARD_OLD, GUARD_NEW, "write_guard")
    text = _sub1(text, PROT_OLD, PROT_NEW, "protect_code_page")
    return text
