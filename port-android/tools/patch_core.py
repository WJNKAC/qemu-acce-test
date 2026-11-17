#!/usr/bin/env python3
"""生成 core/ 的实验副本（原树 src/WindowsiOS 保持只读）。

参数用环境变量控制，每个都对应一次可量化的实验：

  TLB_BITS=16       HV_TLB_BITS 14 → 16（覆盖 64 MB → 256 MB）
  PMD_BANK=1        大页（PMD block）独立 bank + 慢路径桶计数器

为什么 BITS 不能只改一个常量 —— 有三处会被踩到：

  1. `HV_CPU_RET_TAB` 是"紧接 TLB 之后、且是 4 KB 的倍数"的硬编码偏移
     （翻译出的代码用一条 ADD 加它，所以必须 4 KB 对齐）。
     TLB 从 0x580 起、每项 32 B、4 张表：BITS=14 → 2 MB，正好塞进 0x201000；
     BITS=16 → 8 MB，`ret_pad` 会算出负数（编译期报错）。
  2. `user_fills[]` / `kernel_fills[]` / `HvTlbStash.slot[]` 是 **uint16_t**，
     存的是 `hv_tlb_code()` = `table << BITS | slot`（或 `slot << 2 | table`）。
     BITS=14 时最大编码 65535，正好放满 uint16；BITS=16 时最大 262143，
     **会被静默截断** → 往错的表项写 → 随机内存错误。必须升到 uint32_t。
  3. 结构体从 ~4 MB 涨到 ~10 MB；`static HvCpu cpus[8]` 的 BSS 从 32 MB 到 80 MB。

用法： patch_core.py <src_core_dir> <dst_dir>
"""
import os
import re
import sys


def sub1(text, old, new, what):
    if text.count(old) != 1:
        raise SystemExit("%s: 期望恰好 1 处，实际 %d 处 —— 源码变了" % (what, text.count(old)))
    return text.replace(old, new)


def patch_cpu_h(text, tlb_bits, pmd_bank, prof=0, abl=0, whint=0, bank=0, linmap=0):
    if tlb_bits != 14:
        size = 1 << tlb_bits
        text = sub1(text,
                    '#define HV_TLB_BITS 14 /* 16384 entries per EL: 64 MB of 4 KB pages */',
                    '#define HV_TLB_BITS %d /* %u entries per EL: %u MB of 4 KB pages */'
                    % (tlb_bits, size, size * 4 // 1024),
                    'HV_TLB_BITS')
        # ret_tab 必须紧跟 TLB 之后，且是 4 KB 的倍数（代码用一条 ADD 加它）
        tlb_end = 0x580 + size * 4 * 32
        ret_tab = (tlb_end + 0xfff) & ~0xfff
        text = sub1(text, '#define HV_CPU_RET_TAB 0x201000 /* just past the TLB */',
                    '#define HV_CPU_RET_TAB 0x%x /* just past the TLB (%u MB), 4 KB aligned */'
                    % (ret_tab, size * 4 * 32 >> 20),
                    'HV_CPU_RET_TAB')
        # 槽编码位宽跟着变：uint16 会静默截断
        text = sub1(text, '    uint16_t user_fills[HV_USER_FILLS];',
                    '    uint32_t user_fills[HV_USER_FILLS];   /* TLB_BITS>14: slot codes exceed 16 bits */',
                    'user_fills')
        text = sub1(text, '    uint16_t kernel_fills[HV_KERNEL_FILLS];',
                    '    uint32_t kernel_fills[HV_KERNEL_FILLS];',
                    'kernel_fills')
    return text


PMD_FIELDS = """    uint64_t large_2m_bloom[64];
    uint64_t large_big_bloom[8];
    /* PMD 级缓存（PMD_BANK）。一次 2 MB block 走查能覆盖 512 个 4 KB 页，
       所以把走查结果按 VA>>21 记在这里：后续 4 KB refill 直接命中，
       整个跳过 4 级页表（省掉 4 次带原子 load 的 read_desc）。

       失效用 epoch：任何 flush 只把 pmd_epoch 加一，512 项一起作废，
       不必逐项清 —— 这就是"不能漏"的保证。关键是每个 flush 路径都要加那一行。 */
#define HV_PMD_BITS 9
#define HV_PMD_SIZE (1u << HV_PMD_BITS)
#define HV_PMD_MASK ((1ull << 21) - 1)
    struct { uint32_t epoch; uint8_t r, w, x, pad; uint64_t key; int64_t addend; } pmd[HV_PMD_SIZE];
    uint32_t pmd_epoch;"""

PMD_STATS = """    uint64_t refills;
    uint64_t pmd_lookups, pmd_hits, pmd_fills; /* PMD_BANK：慢路径命中率 */
    uint64_t large_fills;   /* 走查发现 block_size >= 2 MB 的次数（决定这个 cache 值不值得做） */"""


PROF_STATS = """#define HV_PROF 1
    uint64_t refills;
    /* PROF：把一次 refill 拆成几段，各段累加 ticks（cntfrq = 13 MHz，1 tick = 77 ns）。
       单次读数分辨率远不够，靠累加上千万次样本取平均。 */
    uint64_t prof_sum[8];
    uint64_t prof_n;"""


def patch_machine_h(text, tlb_bits, pmd_bank, prof=0, abl=0, whint=0, bank=0, linmap=0):
    if tlb_bits != 14:
        text = sub1(text, '    uint16_t *slot;      /* slot << 2 | table, as user_fills */',
                    '    uint32_t *slot;      /* slot << 2 | table, as user_fills */',
                    'HvTlbStash.slot')
    if pmd_bank:
        text = sub1(text, '    uint64_t large_2m_bloom[64];\n    uint64_t large_big_bloom[8];',
                    PMD_FIELDS, 'PMD 字段')
        text = sub1(text, '    uint64_t refills;', PMD_STATS, 'PMD 计数')
    if prof:
        text = sub1(text, '    uint64_t refills;', PROF_STATS, 'PROF 计数')
    if whint == 1:
        import patch_whint
        text = patch_whint.patch_machine_h(text)
    if bank:
        import patch_bank
        text = patch_bank.patch_machine_h(text)
    if linmap:
        import patch_linmap
        text = patch_linmap.patch_machine_h(text)
    return text


def patch_mmu_c(text, tlb_bits, pmd_bank, prof=0, abl=0, whint=0, bank=0, linmap=0):
    if tlb_bits != 14:
        text = sub1(text,
                    'if (cpu->nuser_fills < HV_USER_FILLS) cpu->user_fills[cpu->nuser_fills] = (uint16_t)hv_tlb_code(slot, table);',
                    'if (cpu->nuser_fills < HV_USER_FILLS) cpu->user_fills[cpu->nuser_fills] = hv_tlb_code(slot, table);',
                    'user_fills 写入')
        text = sub1(text,
                    'if (cpu->nkernel_fills < HV_KERNEL_FILLS) cpu->kernel_fills[cpu->nkernel_fills] = (uint16_t)hv_tlb_code(slot, table);',
                    'if (cpu->nkernel_fills < HV_KERNEL_FILLS) cpu->kernel_fills[cpu->nkernel_fills] = hv_tlb_code(slot, table);',
                    'kernel_fills 写入')
        # 读取处：用户刷新 / 内核刷新 / 进程切换三处
        text = text.replace('            uint16_t code = cpu->user_fills[i];',
                            '            uint32_t code = cpu->user_fills[i];')
    if pmd_bank == 1:
        text = patch_mmu_pmd(text)          # 完整：cache + 计数
    elif pmd_bank == 2:
        text = patch_mmu_pmd(text, count_only=True)   # 只计数，行为不变
    if prof:
        text = patch_prof_mmu(text)
    if abl:
        text = patch_ablate(text, abl)
    if whint == 1:
        import patch_whint
        text = patch_whint.patch_mmu_c(text)
    elif whint == 2:
        import patch_whint
        text = patch_whint.patch_mmu_c_w20(text)
    if bank:
        import patch_bank
        text = patch_bank.patch_mmu_c(text)
    return text


# ---- PMD_BANK：慢路径前置缓存 ----
# 改动四处，都很小：
#   1. tlb_fill 末尾：走查发现 block_size >= 2 MB 时，把 addend 记进 pmd
#   2. hv_tlb_refill：走页表之前先查 pmd，命中就直接得到 pa
#   3. 每一条 flush 路径作废 pmd（epoch++）
#   4. HvStats 加计数，由 dispatch.c 打印
#
# 为什么 addend 能在整个 2 MB 里通用：软件 MMU 的 addend 是"宿主地址 - 客机 VA"，
# 同一个线性映射里偏移部分是常量，页内和块内都一样。

PMD_HELPER = """/* ---- PMD_BANK：慢路径前置缓存 ---- */
static inline void pmd_flush(HvPerCpu *p) {
    if (p) p->pmd_epoch++;
}

/* 查：命中返回 addend。key 用 (va>>21)|1，0 表示空。 */
static inline int pmd_lookup(HvPerCpu *p, uint64_t va, int64_t *addend, HvWalk *out) {
    uint32_t i = (uint32_t)((va >> 21) & (HV_PMD_SIZE - 1));
    uint64_t key = (va >> 21) | 1ull;
    if (p->pmd[i].epoch != p->pmd_epoch || p->pmd[i].key != key) return 0;
    *addend = p->pmd[i].addend;
    /* 权限必须带出来：硬编码成 1 会让只读页也调 write_guard（内含 SEQ_CST 全屏障），
       既拖慢又是正确性问题（写只读页不再被拦）。 */
    out->r = p->pmd[i].r; out->w = p->pmd[i].w; out->x = p->pmd[i].x;
    return 1;
}

static inline void pmd_fill(HvPerCpu *p, HvMachine *m, uint64_t va, int64_t addend, int r, int w, int x) {
    uint32_t i = (uint32_t)((va >> 21) & (HV_PMD_SIZE - 1));
    p->pmd[i].epoch = p->pmd_epoch;
    p->pmd[i].key = (va >> 21) | 1ull;
    p->pmd[i].addend = addend;
    p->pmd[i].r = (uint8_t)r; p->pmd[i].w = (uint8_t)w; p->pmd[i].x = (uint8_t)x;
    if (m->stats_interval) m->stats.pmd_fills++;
}

void hv_tlb_flush(HvCpu *cpu) {"""


def patch_mmu_pmd(text, count_only=False):
    # 1. helper 必须定义在第一个使用者之前 —— 最早的是 hv_tlb_flush（143 行），
    #    不是 tlb_fill（700 行）。放错了就是 implicit declaration。
    text = sub1(text, 'void hv_tlb_flush(HvCpu *cpu) {',
                PMD_HELPER.strip('\n'), 'PMD helper')

    # 2. tlb_fill 末尾记住大页（那里 e->addend 刚算好，且有 ram 覆盖校验）
    old_tail = """    if (e->write_tag != HV_TLB_INVALID) write_guard(cpu, ram, pg, hv_tlb_code(slot, table), e);"""
    new_tail = """    if (e->write_tag != HV_TLB_INVALID) write_guard(cpu, ram, pg, hv_tlb_code(slot, table), e);
    /* PMD_BANK：整个 2 MB 都落在同一块 RAM 里才记（否则块内别处的 addend 不成立） */
    if (cpu->pc_state && w->block_size >= (1ull << 21)) {
        uint64_t blk_end = (page_pa & ~(uint64_t)HV_PMD_MASK) + (1ull << 21);
        if (blk_end <= ram->pa + ram->size) {
            pmd_fill(cpu->pc_state, cpu->m, va, e->addend, w->r, w->w, w->x);
            if (cpu->m->stats_interval) cpu->m->stats.large_fills++;
        }
    }"""
    text = sub1(text, old_tail, new_tail, 'tlb_fill 记大页')

    if count_only:
        return text   # 只保留 large_fills 计数与 flush 作废（后者此时无害）

    if count_only:
        return text   # 只保留 large_fills 计数与 flush 作废（后者此时无害）

    # 3. refill 里先查 pmd
    old_refill = """    HvWalk w;
    walk_begin(cpu);
    hv_mmu_walk(cpu, va, write ? HV_ACC_WRITE : HV_ACC_READ, el, &w);
    if (!w.fsc) tlb_fill(cpu, va, el, &w);
    walk_end(cpu);
    if (w.fsc) return 1;"""
    new_refill = """    HvWalk w;
    int64_t pmd_add = 0;
    memset(&w, 0, sizeof w);
    if (cpu->pc_state && pmd_lookup(cpu->pc_state, va, &pmd_add, &w)) {
        /* PMD_BANK：2 MB block 已缓存，直接算 pa。省掉 4 次 read_desc（每次一个原子 load）。 */
        w.pa = va + (uint64_t)pmd_add;
        w.block_size = 1ull << 21;
        tlb_fill(cpu, va, el, &w);
        if (cpu->m->stats_interval) cpu->m->stats.pmd_hits++;
    } else {
        if (cpu->pc_state && cpu->m->stats_interval) cpu->m->stats.pmd_lookups++;
        walk_begin(cpu);
        hv_mmu_walk(cpu, va, write ? HV_ACC_WRITE : HV_ACC_READ, el, &w);
        if (!w.fsc) tlb_fill(cpu, va, el, &w);
        walk_end(cpu);
    }
    if (w.fsc) return 1;"""
    text = sub1(text, old_refill, new_refill, 'refill 查 pmd')

    # 4. 每条 flush 路径作废。逐个函数体首行插 epoch++（pmd_flush 幂等，多处调用无妨）。
    flush_fns = [
        ('void hv_tlb_flush(HvCpu *cpu) {\n    if (cpu->m) cpu->m->stats.tlb_flushes++;',
         'void hv_tlb_flush(HvCpu *cpu) {\n    pmd_flush(cpu->pc_state); /* PMD_BANK */\n    if (cpu->m) cpu->m->stats.tlb_flushes++;'),
        ('void hv_tlb_flush_user(HvCpu *cpu) {', 'void hv_tlb_flush_user(HvCpu *cpu) {\n    pmd_flush(cpu->pc_state); /* PMD_BANK */'),
        ('void hv_tlb_flush_user_range(HvCpu *cpu, uint64_t va, uint64_t len) {', 'void hv_tlb_flush_user_range(HvCpu *cpu, uint64_t va, uint64_t len) {\n    pmd_flush(cpu->pc_state); /* PMD_BANK */'),
        ('void hv_tlb_flush_kernel_range(HvCpu *cpu, uint64_t va, uint64_t len) {', 'void hv_tlb_flush_kernel_range(HvCpu *cpu, uint64_t va, uint64_t len) {\n    pmd_flush(cpu->pc_state); /* PMD_BANK */'),
        ('void hv_tlb_flush_va_asid(HvCpu *cpu, uint64_t va, int asid) {', 'void hv_tlb_flush_va_asid(HvCpu *cpu, uint64_t va, int asid) {\n    pmd_flush(cpu->pc_state); /* PMD_BANK */'),
        ('void hv_tlb_flush_va(HvCpu *cpu, uint64_t va) {', 'void hv_tlb_flush_va(HvCpu *cpu, uint64_t va) {\n    pmd_flush(cpu->pc_state); /* PMD_BANK */'),
        ('void hv_tlb_protect_code(HvCpu *cpu, const uint8_t *host_page) {', 'void hv_tlb_protect_code(HvCpu *cpu, const uint8_t *host_page) {\n    pmd_flush(cpu->pc_state); /* PMD_BANK */'),
    ]
    for old, new in flush_fns:
        text = sub1(text, old, new, 'flush: ' + old.split('(')[0])
    return text


# ---- PROF：把一次 refill 拆成 8 段 ----
# 分辨率问题：cntfrq = 13 MHz，1 tick = 77 ns ≈ 154 周期。
# 单次读数根本分辨不出 1000 周期的内部结构，只能"每段累加、除样本数"。
# 代价：每次 now() 有几十周期延迟、且可能被 OoO 重排，
# 所以只信**比例**；绝对值由总 refill 时间独立给出。
#
#   A   = walk 本体                          sum[0]
#   D1  = tlb_fill 前半（ram_of/code_pages/user_fills）  sum[1]
#   C   = 写 TLB 表项（4 个字段）             sum[2]
#   B1  = write_guard 里的 whint 访问          sum[3]
#   B2  = write_guard 里的 fence 及余下        sum[4]
#   D3  = bloom 原子 + 返回                    sum[5]
#   call= refill 到 tlb_fill 的调用开销        sum[6]

_PROF_HELPER = "\n".join([
    "/* ---- PROF ---- */",
    "static __thread uint64_t hv_prof_t[10];",
    "static __thread int hv_prof_on;   /* 只有 refill 路径的样本才算，否则 t[0]/t[1] 是旧的 */",
    "static inline uint64_t hv_prof_now(void) {",
    "    uint64_t c;",
    "    /* 不加 isb：它会序列化整条流水线，把被测代码本身搅乱。",
    "       代价是可能被重排，所以只信累加后的比例。 */",
    '    __asm__ __volatile__("mrs %0, cntvct_el0" : "=r"(c));',
    "    return c;",
    "}",
    "",
])

_PROF_ACC = "\n".join([
    "    hv_prof_t[7] = hv_prof_now();          /* PROF: 函数末尾 */",
    "    if (cpu->m->stats_interval && hv_prof_on) {",
    "        HvStats *st = &cpu->m->stats;",
    "        /* 无符号减法 + OoO 重排 = 少数样本跑出负差、溢出成巨大值，",
    "           一条就能把平均值拉爆（踩过：9.3e5 ns/refill）。",
    "           所以每段都过一遍合理性闸门。 */",
    "#define PROF_ACC(i, a, b) do { uint64_t _d = (b) - (a); if (_d < 100000) st->prof_sum[i] += _d; } while (0)",
    "        PROF_ACC(0, hv_prof_t[0], hv_prof_t[1]);   /* A  walk */",
    "        PROF_ACC(1, hv_prof_t[2], hv_prof_t[3]);   /* D1 fill 前半 */",
    "        PROF_ACC(2, hv_prof_t[3], hv_prof_t[4]);   /* C  写 entry */",
    "        PROF_ACC(3, hv_prof_t[4], hv_prof_t[5]);   /* B1 whint */",
    "        PROF_ACC(4, hv_prof_t[5], hv_prof_t[6]);   /* B2 fence 余下 */",
    "        PROF_ACC(5, hv_prof_t[6], hv_prof_t[7]);   /* D3 bloom + 返回 */",
    "        PROF_ACC(6, hv_prof_t[1], hv_prof_t[2]);   /* 调用开销 */",
    "        PROF_ACC(7, hv_prof_t[8], hv_prof_t[9]);   /* 空区间基线（校准用） */",
    "#undef PROF_ACC",
    "        st->prof_n++;",
    "    }",
    "}",
])


def patch_prof_mmu(text):
    text = sub1(text, 'void hv_tlb_flush(HvCpu *cpu) {',
                _PROF_HELPER + '\nvoid hv_tlb_flush(HvCpu *cpu) {', 'PROF helper')

    # 锚点必须够长：hv_mmu_access 里也有 "HvWalk w; walk_begin(cpu);"
    text = sub1(text, '    HvWalk w;\n    walk_begin(cpu);\n'
                      '    hv_mmu_walk(cpu, va, write ? HV_ACC_WRITE : HV_ACC_READ, el, &w);',
                '    HvWalk w;\n'
                '    hv_prof_on = 1;                        /* PROF */\n'
                '    hv_prof_t[0] = hv_prof_now();          /* PROF: walk 起点 */\n'
                '    walk_begin(cpu);\n'
                '    hv_mmu_walk(cpu, va, write ? HV_ACC_WRITE : HV_ACC_READ, el, &w);\n'
                '    hv_prof_t[1] = hv_prof_now();          /* PROF: walk 终点 */',
                'PROF walk 段')

    # refill 收尾清标志（这个锚点 refill 独有：hv_mmu_access 是 "if (w.fsc) return w.fsc;"）
    text = sub1(text, '    if (!w.fsc) tlb_fill(cpu, va, el, &w);\n    walk_end(cpu);\n    if (w.fsc) return 1;',
                '    if (!w.fsc) tlb_fill(cpu, va, el, &w);\n    walk_end(cpu);\n'
                '    hv_prof_on = 0;                        /* PROF */\n    if (w.fsc) return 1;',
                'PROF 清标志')

    text = sub1(text, 'static void tlb_fill(HvCpu *cpu, uint64_t va, int el, const HvWalk *w) {\n'
                      '    if ((va >> 55) & 1) kva_note(va & ~(uint64_t)PAGE_MASK);',
                'static void tlb_fill(HvCpu *cpu, uint64_t va, int el, const HvWalk *w) {\n'
                '    hv_prof_t[2] = hv_prof_now();          /* PROF: tlb_fill 入口 */\n'
                '    if ((va >> 55) & 1) kva_note(va & ~(uint64_t)PAGE_MASK);',
                'PROF fill 入口')

    text = sub1(text,
                '    e->addend = (int64_t)((uint64_t)(uintptr_t)(ram->host + (page_pa - ram->pa)) - page_va);',
                '    hv_prof_t[3] = hv_prof_now();      /* PROF: 写 entry 起点 */\n'
                '    e->addend = (int64_t)((uint64_t)(uintptr_t)(ram->host + (page_pa - ram->pa)) - page_va);',
                'PROF entry 起点')

    text = sub1(text,
                '    if (e->write_tag != HV_TLB_INVALID) write_guard(cpu, ram, pg, hv_tlb_code(slot, table), e);',
                '    hv_prof_t[4] = hv_prof_now();          /* PROF: 写 entry 终点 */\n'
                '    hv_prof_t[5] = hv_prof_t[4];           /* PROF: 默认没调 write_guard */\n'
                '    if (e->write_tag != HV_TLB_INVALID) write_guard(cpu, ram, pg, hv_tlb_code(slot, table), e);\n'
                '    hv_prof_t[6] = hv_prof_now();          /* PROF: write_guard 返回 */',
                'PROF entry 终点 + wg 返回')

    # 函数末尾（bloom 之后）：用 stats 里那行作锚
    text = sub1(text,
                '            __atomic_or_fetch(&cpu->pc_state->large_big_bloom[h >> 6], 1ull << (h & 63), __ATOMIC_RELAXED);\n'
                '        }\n    }\n}',
                '            __atomic_or_fetch(&cpu->pc_state->large_big_bloom[h >> 6], 1ull << (h & 63), __ATOMIC_RELAXED);\n'
                '        }\n    }\n' + _PROF_ACC,
                'PROF 累加')

    text = sub1(text,
                '    uint64_t mine = code + 1, old = __atomic_load_n(hint, __ATOMIC_RELAXED), now = old;',
                '    uint64_t mine = code + 1, old = __atomic_load_n(hint, __ATOMIC_RELAXED), now = old;\n'
                '    hv_prof_t[5] = hv_prof_now();           /* PROF: whint 读完之后 */',
                'PROF whint 时刻')
    return text




# ---- ABL：端到端消融 ----
# 为什么不用分桶：cntfrq=13MHz，1 tick=77ns，而单段只有 10–270ns。
# 分辨率不够，且 mrs 的读延迟会伪装成"这一段很贵"（实测 walk 报 269ns，
# 但跳过 walk 后总时间反而变慢 240ns —— 自相矛盾，说明是伪影）。
# 消融没有这个问题：直接删掉一段，看端到端差多少。
#
#   ABL=1  write_guard 整个不调用（保护失效，仅测量）
#   ABL=2  只把 write_guard 里的 SEQ_CST fence 变成 no-op
#   ABL=3  large_*_bloom 的原子 OR 改成普通 RMW（单核安全）
#   ABL=4  thread_fence + bloom 一起（2+3）
#   ABL=5  不读/不写 whint 数组（per-page×per-cpu，2GB guest 时 32 MB）
#   ABL=6  不读 code_pages[pg]（per-page 字节，1GB 时 512 KB）
#   ABL=5  不读/不写 whint 数组（per-page×per-cpu，2GB guest 时 32 MB）
#   ABL=6  不读 code_pages[pg]（per-page 字节，1GB 时 512 KB）

def patch_ablate(text, abl):
    if abl in (1,):
        text = sub1(text,
                    '    if (e->write_tag != HV_TLB_INVALID) write_guard(cpu, ram, pg, hv_tlb_code(slot, table), e);',
                    '    if (0 && e->write_tag != HV_TLB_INVALID) write_guard(cpu, ram, pg, hv_tlb_code(slot, table), e); /* ABL=1 */',
                    'ABL write_guard')
    if abl in (2, 4):
        # 全文有 3 处 SEQ_CST fence，只有 write_guard 里那处要动 —— 用后一行做区分
        text = sub1(text, '    __atomic_thread_fence(__ATOMIC_SEQ_CST);\n'
                          '    if (__atomic_load_n(&ram->code_pages[pg], __ATOMIC_RELAXED))',
                    '    /* ABL=2: fence removed (single vCPU) */\n'
                    '    if (__atomic_load_n(&ram->code_pages[pg], __ATOMIC_RELAXED))',
                    'ABL fence')
    if abl == 5:
        # 必须连 store 一起跳过：只把 old 置 0 的话，块里的 __atomic_store_n
        # 仍会写 whint（store 要 RFO 拿 cache line，一样 miss）—— 第一版就是这么白测的。
        text = sub1(text,
                    '    uint64_t mine = code + 1, old = __atomic_load_n(hint, __ATOMIC_RELAXED), now = old;',
                    '    uint64_t mine = code + 1, old = 0, now = old; (void)hint; /* ABL=5: 不碰 whint */',
                    'ABL whint load')
        text = sub1(text, '    if (!(old & HV_WHINT_MANY)) {',
                    '    if (0) { /* ABL=5: 整块跳过 whint 的 load/store */',
                    'ABL whint block')
    if abl == 6:
        text = sub1(text,
                    '    if (__atomic_load_n(&ram->code_pages[pg], __ATOMIC_RELAXED)) e->write_tag = HV_TLB_INVALID;',
                    '    if (0) e->write_tag = HV_TLB_INVALID; /* ABL=6: 不读 code_pages */',
                    'ABL code_pages')
    if abl in (3, 4):
        text = sub1(text,
                    '            __atomic_or_fetch(&cpu->pc_state->large_2m_bloom[h >> 6], 1ull << (h & 63), __ATOMIC_RELAXED);',
                    '            cpu->pc_state->large_2m_bloom[h >> 6] |= 1ull << (h & 63); /* ABL=3: 非原子 */',
                    'ABL bloom2m')
        text = sub1(text,
                    '            __atomic_or_fetch(&cpu->pc_state->large_big_bloom[h >> 6], 1ull << (h & 63), __ATOMIC_RELAXED);',
                    '            cpu->pc_state->large_big_bloom[h >> 6] |= 1ull << (h & 63); /* ABL=3: 非原子 */',
                    'ABL bloombig')
    return text


def main():
    src, dst = sys.argv[1], sys.argv[2]
    tlb_bits = int(os.environ.get('TLB_BITS', '14'))
    pmd_bank = int(os.environ.get('PMD_BANK', '0'))
    prof = int(os.environ.get('PROF', '0'))
    abl = int(os.environ.get('ABL', '0'))
    whint = int(os.environ.get('WHINT', '0'))
    bank = int(os.environ.get('BANK', '0'))
    linmap = int(os.environ.get('LINMAP', '0'))
    os.makedirs(dst, exist_ok=True)

    # 变体标记：内容变化时让 make 重编所有 .o。
    # 否则 BITS=16 -> 14 切换时，.o 还是 16 的布局、头却是 14 的 → ABI 不一致 → 段错误。
    marker = os.path.join(dst, 'variant.txt')
    tag = '%d-%d-%d-%d-%d-%d-%d\n' % (tlb_bits, pmd_bank, prof, abl, whint, bank, linmap)
    if not (os.path.exists(marker) and open(marker).read() == tag):
        open(marker, 'w').write(tag)
        print("variant -> %s" % tag.strip())

    plan = [('cpu.h', patch_cpu_h), ('machine.h', patch_machine_h), ('mmu.c', patch_mmu_c),
            ('machine.c', None), ('dispatch.c', None)]
    changed = []
    for name, fn in plan:
        p = os.path.join(src, name)
        text = open(p, encoding='utf-8').read()
        if fn is None:            # machine.c / dispatch.c：只由特定开关改动
            import patch_whint
            import patch_bank
            out = text
            if name == 'machine.c' and whint == 1:
                out = patch_whint.patch_machine_c(out)
            if name == 'machine.c' and bank:
                out = patch_bank.patch_machine_c(out)
            if name == 'dispatch.c' and bank:
                out = patch_bank.patch_dispatch_ncode(out)
        else:
            if bank:
                import patch_bank
                if name == 'cpu.h':
                    text = patch_bank.patch_cpu_h(text)
                elif name == 'machine.h':
                    text = patch_bank.patch_ram_ncode(text)
            out = fn(text, tlb_bits, pmd_bank, prof, abl, whint, bank, linmap)
        # 内容相同就不碰文件 —— 否则 make 会认为头文件变了、重编所有 core
        dest = os.path.join(dst, name)
        same = os.path.exists(dest) and open(dest, encoding='utf-8').read() == out
        if not same:
            open(dest, 'w', encoding='utf-8').write(out)
            changed.append(name)
    if changed:
        print("patched core -> %s: %s (TLB_BITS=%d PMD_BANK=%d PROF=%d ABL=%d)"
              % (dst, ','.join(changed), tlb_bits, pmd_bank, prof, abl))


if __name__ == '__main__':
    main()
