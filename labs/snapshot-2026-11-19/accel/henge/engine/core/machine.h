#ifndef HENGEVM_MACHINE_H
#define HENGEVM_MACHINE_H

#include <TargetConditionals.h>
#include <pthread.h>
#include <stdint.h>

#include "cpu.h"
#include "jit_region.h"

/* Guest physical memory: RAM regions backed by host memory, and MMIO regions
   handled by device callbacks. The fast path only ever sees RAM. */
typedef struct HvRam {
    uint64_t pa, size;
    uint8_t *host;
    int readonly;
    uint8_t *code_pages; /* one byte per 16 KB page: a translated block came from here (2^pages_log2 of them) */
    uint32_t pages_log2;
    uint32_t *page_gen;  /* per page: bumped to invalidate the blocks translated from it */
    /* Identifies this slot's current occupancy.  Bumped by add_ram() *and* by
       del_ram(), which is what makes it worth having.

       add_ram() alone would only distinguish two occupants after the fact.  The
       gap in the middle is the dangerous one: between the del and the next add
       the slot is retired -- size 0, page_gen NULL -- while pa, flags and
       epoch all still match whatever was there before, so a block translated
       from the vanished window passes every other test and then reads
       page_gen[pg], i.e. NULL[pg].  That is a host SIGSEGV, not a wrong guest
       read.  Bumping on the way out closes the window instead of documenting
       it.

       Blocks remember this as ram_epoch; see hv_block_find(). */
    uint32_t epoch;
    /* Per page and CPU: up to three TLB entries (slot << 2 | table, plus 1;
       16 bits each) that mapped the page writable, or HV_WHINT_MANY when there
       were more. When the page becomes code only those are dropped, not a whole
       TLB scanned. */
    uint64_t *whint;
} HvRam;

typedef struct HvMmio {
    uint64_t pa, size;
    void *opaque;
    uint64_t (*read)(void *opaque, uint64_t off, unsigned size);
    void (*write)(void *opaque, uint64_t off, uint64_t val, unsigned size);
    const char *name;
    int self_locked;     /* the device takes its own lock (the GIC): no device lock around it */
} HvMmio;

typedef struct HvBlock {
    uint32_t jit_gen; /* full flushes when it was made */
    uint64_t va, pa;
    uint32_t flags;      /* HV_BLOCK_* state the translation depends on */
    uint32_t ninsns;
    uint32_t gen;        /* page_gen of its page when translated */
    uint32_t ram_epoch;  /* ram->epoch when translated: which occupancy of the slot this is */
    struct HvRam *ram;   /* where its page lives, for a quick staleness check */
    uint64_t pg;
    uint32_t *code;
    struct HvBlock *next;
    uint32_t maker;      /* the CPU that translated it (index + 1; 0: not a CPU, as in tests) */
} HvBlock;

#define HV_BLOCK_EL1   1u        /* translated for EL1 (selects tlb[1]) */
#define HV_BLOCK_FPOFF 2u        /* CPACR_EL1.FPEN traps FP/SIMD at this EL */
#define HV_BLOCK_SPX   4u        /* EL1 with SPSel = 1 (SP_EL1 in use, SP_EL0 banked) */
#define HV_BLOCK_PAN   8u        /* EL1 with PSTATE.PAN set (selects TLB table 2) */

#define HV_MAX_RAM 8
#define HV_MAX_MMIO 48
#define HV_BLOCK_HASH (1 << 21) /* one bucket per block: chains are walked on every front-cache miss */
#define HV_JC_BITS 16
#define HV_MAX_BLOCKS (3 << 20) /* a macOS boot runs well over a million distinct blocks; a full flush retranslates them all */
#define HV_PROF_RING (1 << 16)
#define HV_MAX_SLOTS (6 << 20)  /* chainable exits: about two per block */

/* Counters for --stats: where the time goes. */
typedef struct HvStats {
    uint64_t blocks, translations, block_flushes;
    /* Slot-identity counters.  Accumulated, not rates: they answer "did this
     * ever happen", which is the only question that matters for a fault path
     * that is either impossible or fatal.
     *
     *   ram_reuse    add_ram() recycled a retired slot.  Not the same as
     *                del_ram calls -- a del against a never-mirrored window
     *                retires nothing, and on a disk boot that is 698 of 704.
     *                Measured baseline (13.35, disk boot): 5 hits, 704 calls,
     *                4 reuses, all before the first vCPU.
     *   retired_hit  a block was looked up while its window was retired
     *                (size 0, page_gen NULL).  This is the NULL-dereference
     *                path: it is the only observer the del-epoch bump has,
     *                since that fix is correct by construction and otherwise
     *                produces no visible change.
     *   epoch_stale  a block's occupancy generation no longer matched.
     *   epoch_high_water  largest generation gap seen.
     *
     * del_hit / del_miss: del_ram found a live mirrored window (0) or not
     * (-1).  Together with ram_reuse these settle "why did 704 dels retire
     * only 4 slots" without reasoning about the never-mirror list. */
    uint64_t ram_reuse, epoch_stale, epoch_high_water;
    uint64_t del_hit, del_miss;
    uint64_t retired_hit;
    uint64_t flush_smc, flush_ic, flush_full;  /* why translations were dropped */
    uint64_t chained, ijc_fills, ijc_resets;
    uint64_t xchained;
    uint64_t kick_src[5];     /* exit_req set by: a request (TLBI), hv_cpu_wake, kick_all, hv_machine_wake, the CPU itself */        /* of them, exits to another page (TLB-checked) */
    uint64_t syncs, sync_ticks;        /* TLBI acks waited for, and host ticks spent waiting */
    uint64_t dev_waits, dev_wait_ticks; /* device lock taken while another CPU held it */
    uint64_t tr_waits, tr_wait_ticks;   /* translation lock likewise */
    uint64_t words_inline, words_ool, words_pool; /* translated code size by part */
    uint64_t refills;
    uint64_t ijc_light;       /* branch-cache misses resolved without the dispatcher (hv_ijc_resolve) */         /* TLB misses filled by the light path (hv_tlb_refill) */
    uint64_t stash_saves, stash_hits, stash_entries; /* user TLB entries kept across process switches */
    uint64_t code_protects;   /* pages that became code (every CPU's TLB scanned for writable entries) */
    uint64_t tlb_miss_kind[4]; /* TLB misses: EL0 empty, EL0 other page there, EL1 empty, EL1 other page there */
    uint64_t slow_why[6];     /* slow accesses by cause: MMIO, code-page write, page end, TLB miss, other, TLB entry there but mismatched */
    uint64_t slow_kind[12];   /* hv_mem_emulate calls by HV_MEM_* kind */
    uint64_t light_kind[4];
    uint64_t light_fail[4];
    uint64_t light_walks;
    uint64_t fast_resumes;
    uint64_t fr_fail[5];    /* SVCs and ERETs that went to their block without the dispatcher */
    uint64_t protect_kind[3]; /* a page becoming code, per CPU: not mapped writable, one entry, scan */
    uint64_t light_region[2]; /* user light fills: in the shared region (0x18..0x28 << 28), elsewhere */
    uint64_t chained_early;   /* exits chained as their block was placed */
    uint64_t wfe_waits;       /* WFEs that waited on the monitored word in place */
    uint64_t kind_insns[16], kind_words[16]; /* --stats: inline words by instruction kind (HvInsnKind), as translated */
    uint64_t posted_kind[4];
    uint64_t race_kind[3];    /* remote drops that raced: walk under way, cache fill under way, either during the drop */  /* TLBIs other CPUs had to do themselves: a page or small range that raced, a big range, the rest (ASID, all) */
    uint64_t range_spared;    /* big user-range TLBIs that needed no cached targets dropped */
    uint64_t kernel_ranges;   /* big kernel-range TLBIs, dropped by range rather than with everything */
    uint64_t tlb_range_flushes; /* and that dropped only the TLB entries in the range */     /* of hv_ijc_resolve's lookups, ones that walked for the target page */   /* hv_ijc_resolve could not: chaining off/odd target, filters full, no TLB entry, block not made yet */   /* the same for hv_ijc_resolve's fills */
    uint64_t fill_kind[4];    /* ijc fills into an empty slot, over another live salt, over the same salt, over a dead salt */
    uint64_t reset_why[8];    /* cache drops: full flush, TLBI by ASID, TLBI user VA, TLBI kernel VA, code change, user VA in every ASID (whole user half), keyed filter full, big user range */
    uint64_t why[6];          /* dispatcher entries by cause: chain fill, kick, exception/sysreg, interrupt, cached target, cache miss */
    uint64_t miss_kind[7];    /* cache misses by the branch that missed: RET, BR/BLR, B/BL, conditional, MSR, other, unknown */
    uint64_t recent[16];      /* debugging: the last blocks the dispatcher entered (pc | el) */
    struct { uint64_t from, to, spsr; uint32_t kind, el; } elchg[16]; /* debugging: last exception entries (kind = type) and ERETs (kind 9) */
    uint32_t nelchg;
    uint64_t nrecent;
    uint64_t translate_ticks, translated_insns, translated_words; /* time spent translating, guest and host code size */
    uint64_t retrans_va, retrans_vapa; /* translations of a VA (and VA+PA) translated before: diagnostics */
    uint64_t helper[12];      /* by HV_OP_* */
    uint64_t tlb_flushes, fetch_walks, exceptions, interrupts;
    uint64_t wfi, wfi_ticks;  /* WFI exits, host ticks spent asleep */
} HvStats;

#if TARGET_OS_IPHONE
#define HV_MAX_CPUS 4
#else
#define HV_MAX_CPUS 8
#endif
#define HV_WHINT_MANY (1ull << 63) /* whint: more than three; else up to three TLB codes + 1, 16 bits each */

/* What each CPU has to itself and keeps across hv_cpu_reset (tests copy HvCpu
   structs around, so it lives here, by CPU index): its indirect-branch cache and
   the filters for dropping entries from it, the front cache of blocks, its
   interrupt lines and its wakeup. */
/* A process's user TLB entries, put aside when it is switched out (TTBR0 now
   names another address space) and put back when it comes back, as a TLB
   tagged by ASID keeps them. Any TLBI that could touch the address space
   (here or from another CPU) bumps gen; a stash whose gen moved is dropped. */
#define HV_STASHES 8
#define HV_STASH_CAP 1024
typedef struct HvTlbStash {
    uint64_t ttbr0;      /* the address space (0: empty); read by other CPUs */
    uint32_t gen;        /* bumped by TLBIs (atomic) */
    uint32_t saved_gen;  /* gen when the entries were saved */
    uint32_t n;
    uint64_t used;       /* for replacing the least recently saved */
    uint16_t *slot;      /* slot << 2 | table, as user_fills */
    HvTlbEntry *ent;
} HvTlbStash;

typedef struct HvPerCpu {
    /* Interrupt lines into this CPU.
     *
     * AUTHORITY: whoever owns the GIC owns these.  Standalone (HengeVM and the
     * AppleVM build) that is this engine, and its GIC writes them.  Under the
     * QEMU accelerator they are DERIVED and diagnostic only -- see
     * irq_line_get below, which is what the dispatcher actually consults.
     *
     * They stay adjacent and 8-byte aligned because translated code can read
     * both with one load through HvCpu.lines_ptr; after the read-through
     * change that load exists only for hv_engine_get_irq/monitor display. */
    int irq_line, fiq_line;
    uint64_t *ijc;           /* indirect-branch cache tables (cpu->ijc points here) */
    uint64_t ijc_pages[2][1024]; /* hashed bitmap of the user pages any process cached targets in (for all-ASID TLBIs) */
    /* Hashed bitmap of (page, salt) pairs with cached targets: a TLBI for one
       address space drops its entries only if that address space cached
       something in the page. A new salt makes old bits meaningless, so this is
       only cleared (with the whole cache) when it gets an eighth full. */
    uint64_t ijc_keyed[1 << 14];
    uint32_t ijc_keyed_count;
    uint32_t ijc_tables_used; /* bit per flags value whose table was ever filled */
    /* Exactly which (user id, user page) pairs have cached targets: a hash set,
       so unmapping a big range of one address space drops only its code pages'
       entries instead of the whole address space's. Emptied with the user half. */
    uint64_t *ucode;
    uint32_t ucode_count;
    /* Per user id: which 32 MB chunks of its VA (hashed into 256) have cached
       targets, so a TLBI for a big range elsewhere (data, nearly always) drops nothing. */
    uint64_t (*cid_chunks)[4];
    uint64_t last_fill[2];
    /* Per half, hashed by (page ^ salt): which 256-byte pieces of the page have
       cached targets, so dropping a page clears 64 entries per piece instead of
       all 4096. A slot two keys wanted is spoiled (key ~0: scan it all); only
       this CPU empties one again, after clearing its page. */
    struct { uint64_t key, bits; } ijc_hint[2][4096];   /* page ^ salt of the last fill in each half: its filter bits are set already */
    /* Direct-mapped cache in front of the hash, with the VA beside the block so
       a slot holding another block is passed over without reading it. */
    struct { uint64_t va; struct HvBlock *b; } jc[1 << HV_JC_BITS];
    /* WFI sleeps on this; device threads, the GIC and other CPUs signal it. */
    pthread_mutex_t wake_mu;
    pthread_cond_t wake_cv;
    int wake_pending;
    /* Work other CPUs ask of this one (only the owner may touch its TLB and
       branch cache while it runs). Posting bumps req_seq; the owner does the
       work at its next dispatcher entry and publishes ack_seq. */
    pthread_mutex_t req_mu;
    uint32_t req_flags;          /* HV_REQ_* */
    uint32_t nreq;
    struct { uint32_t op1, crn, crm, op2; uint64_t xt; } req[64]; /* TLBIs to apply */
    uint64_t req_seq, ack_seq;
    /* active: inside the dispatcher loop (0 while parked: WFI, powered off, at a
       flush barrier). tlb_live: active and not itself waiting for acks, i.e. it
       may be using TLB entries right now. */
    int active, tlb_live;
    uint32_t walk_seq;           /* odd while it walks page tables and fills its TLB (see hv_tlbi_drop_remote_va) */
    uint32_t ijc_seq;            /* odd while it checks a block's mapping in its TLB and caches it (hv_ijc_fill_checked) */
    HvTlbStash stash[HV_STASHES];
    uint64_t stash_clock;
    /* Bloom filters for >4 KB block/large-page descriptors expanded into 4 KB TLB entries,
       so a single by-VA TLBI on a 2 MB / 1 GB / 16 KB / 64 KB mapping drops all sub-pages. */
    uint64_t large_2m_bloom[64];
    uint64_t large_big_bloom[8];
    uint64_t last_refill_key;
} HvPerCpu;

#define HV_REQ_TLB_ALL 1u   /* drop the whole TLB and branch cache */
#define HV_REQ_IJC_RESET 2u /* drop the branch cache (code changed) */

typedef struct HvMachine {
    HvRam ram[HV_MAX_RAM];
    int nram;
    HvRam *main_ram;     /* the largest region: guest RAM */
    HvMmio mmio[HV_MAX_MMIO];
    int nmmio;

    HvJitRegion jit;
    HvBlock *hash[HV_BLOCK_HASH];
    HvBlock *blocks;
    int nblocks;
    uint32_t max_blocks, max_slots; /* sized from the JIT region (machine.c) */
    int flush_pending;   /* set by helpers; the dispatcher flushes once the block has left */
    /* Set by a host that changes the RAM map (a QEMU MemoryListener, after a
       region was removed or its read-back mode changed).  hv_flush_blocks()
       normally only empties the software TLB when the *layout* changes; for a
       RAM change it must empty every entry on every CPU, because the entries
       point at host memory the guest may no longer read directly.  Cleared by
       hv_flush_blocks() once it has done so.  Set together with
       flush_pending, and always from a thread that will not touch any TLB
       itself: the flush happens later, on a vCPU, with everybody parked --
       the only moment the layout may change (see hv_flush_blocks). */
    int need_tlb_flush;
    /* Phase 1 acceptance instrumentation (HV_DBG_FLUSH): how long a deferred
       invalidation took to actually run.  The window is real and this is its
       measurement, so "0 violations" is never read as "0 window". */
    int dbg_flush;
    uint64_t flush_req_ns;
    uint64_t flush_reqs;
    uint64_t flush_max_ns;
    uint64_t flush_sum_ns;

    void *gic;
    /* Devices: called between blocks every so often and while the CPU waits.
       Returns the host time (mach_absolute_time units) of the next timer event, or 0. */
    uint64_t (*tick)(struct HvMachine *m, HvCpu *cpu);
    void *tick_opaque;
    /* GIC CPU interface system registers (ICC_*_EL1), reg = op0:op1:CRn:CRm:op2. */
    uint64_t (*icc_read)(struct HvMachine *m, HvCpu *cpu, uint32_t reg);
    void (*icc_write)(struct HvMachine *m, HvCpu *cpu, uint32_t reg, uint64_t v);

    uint64_t stop_pc;    /* tests: leave the dispatcher when pc reaches this */
    void (*stop_hook)(HvCpu *cpu); /* debugging: call this there instead of leaving */
    uint64_t stop_pc2;   /* debugging: a second such place */
    uint32_t jit_gen;    /* full flushes so far, as blocks see them (HV_JIT_POISON checks) */
    int gen_checks;
    int trace;           /* print every block entered */
    int log;             /* 1: unknown sysregs, undefined instructions, unmapped accesses; 2: also every exception */
    int slow_mem;        /* tests: send every load and store through hv_mem_emulate */

    /* ---- seams: what a host with its own device models takes over ----
       All three default to 0, which is exactly the standalone behaviour. A
       host that owns the devices (QEMU) sets them, and the engine stops
       pretending to be the machine it cannot see. Being flags rather than
       #ifdefs is deliberate: the standalone build and the hosted build then
       run the same code paths, so a change that breaks one is caught by the
       other's tests. */
    /* An MRS/MSR the engine does not model: leave the block with
       HV_EXIT_SYSREG_EXT instead of injecting UNDEF, so the host can answer it
       from its own register table (QEMU's cpu->cp_regs) and hand back the
       value. Without this the engine's idea of "unimplemented" decides what
       the guest sees, which is wrong the moment the host has registers the
       engine never will (ICC_*, CNTV_CVAL, ...). */
    /* ---- the time base ----
       The engine counts in its own domain (counter(), 24 MHz on this port) and
       compiles nothing into the guest that depends on it being guest time --
       on Linux counter reads go through the MRS helper, not inline code, so
       converting here costs a multiply and nothing else.

       timer_freq is the guest's CNTFRQ and comes from the host's timer model,
       not from a #define.  scale converts counter() ticks to timer_freq ticks.
       epoch is the difference between the two clocks at the last calibration:
       guest ticks = scaled(counter()) - epoch.  A virtual clock that freezes
       while the VM is stopped (QEMU's) makes host and guest diverge whenever
       the guest is paused, so epoch is re-taken on every resume.

       Defaults (freq 24000000, scale 1/1, epoch 0) are exactly the standalone
       behaviour. */
    uint64_t timer_freq;
    uint64_t timer_scale_num, timer_scale_den;
    uint64_t timer_epoch;
    int sysreg_external;
    /* SMC/HVC: leave the block instead of running the built-in PSCI, so the
       host's PSCI conduit owns CPU_ON/CPU_OFF. The in-engine version resets
       the target CPU itself, which a host that owns CPU objects (QEMU and its
       vCPU threads) must not have happen behind its back. */
    int psci_external;
    /* LSE (ARMv8.1 atomics: LDADD/LDCLR/CAS/SWP and friends) is implemented by
       the translator, so it executes whatever the guest's ID register claims.
       INITIALISED TO 1 BY hv_machine_init() -- that is the standalone behaviour
       and it must not change -- and a host that owns the ID registers sets it
       from what it actually advertises. Under QEMU that matters: -cpu
       cortex-a57 advertises ATOMIC=0, so a guest probing for LSE is told "no",
       yet the engine would still execute it. TCG traps instead. */
    int feat_lse;

    /*
     * Interrupt level, read through -- the single-owner rule.
     *
     * HvPerCpu.irq_line/fiq_line are a *copy*.  Whoever writes them and
     * whoever delivers interrupts must be the same party, or the copy goes
     * stale between a device lowering the line and the dispatcher looking.
     * ARM makes this load-bearing: CPU_INTERRUPT_HARD is cleared ONLY by the
     * GIC dropping the line (target/arm/cpu.c arm_cpu_set_irq), never by the
     * delivery path, so a stale-high level is indistinguishable from a real
     * pending interrupt and the guest livelocks in cpu_do_idle().
     *
     * So the owner installs this hook and the engine asks it at every block
     * boundary instead of trusting its own copy:
     *
     *   - QEMU accelerator: reads cs->interrupt_request atomically.  That is
     *     exactly MTTCG's own model -- the vCPU thread reads the flag at every
     *     TB boundary while an iothread may be setting it with qatomic_or, and
     *     nobody claims the reader has a private copy.
     *   - Standalone (AppleVM): reads its own GIC, i.e. the same bytes as
     *     pc_state, so it is a no-op indirection there and both builds stay
     *     structurally identical.
     *
     * NULL means "no hook": the engine then falls back to pc_state, which is
     * the pre-read-through behaviour.  Kept so this file still builds and runs
     * standalone without a host shim.
     *
     * Memory order: the writer publishes with a release store and the reader
     * uses an acquire load, so a line raised before a kick is visible to the
     * block the kick causes.  Return 1 for asserted, 0 for not.
     */
    int (*irq_line_get)(void *ctx, unsigned cpu_index, int fiq);
    /* Opaque to the engine: the host's way back from cpu_index to its own CPU
     * object.  Passed straight through to irq_line_get. */
    void *irq_line_ctx;

    uint64_t stat_slow_mem; /* hv_mem_emulate calls */
    uint64_t access_pc;  /* guest PC of the load/store being emulated, for logs */
    uint64_t watch_va;   /* debugging: log every write that touches this guest VA (0: off) */
    uint64_t watch_pa;   /* debugging: the same by physical address */
    HvStats stats;
    int chain;               /* block chaining and the indirect-branch cache are enabled */
    uint64_t *slots;         /* chainable exits' targets (0: not chained) */
    uint32_t **slot_site;    /* the B in each exit's stub that chaining rewrites to jump to the target */
    uint32_t **slot_stub;    /* what that B goes to while it isn't chained */
    uint32_t **slot_cond;    /* a conditional branch in a block's hot part that chaining may send straight to the target too */
    /* Exits to another page (see put_branch_exit): the host addend the target
       page's TLB entry must hold for the exit to go straight to the chained
       block (0: a same-page exit), and once chained, the target's physical page
       (| 1) so that invalidating its code can unchain it. xchained lists them. */
    uint64_t *slot_xa, *slot_xpa;
    uint32_t *xchained, nxchained;
    uint32_t nslots;
    HvCpu *cpu;              /* CPU 0: the one that polls devices */
    HvCpu *cpus[HV_MAX_CPUS]; /* every CPU, so device and invalidation code can ask them to leave */
    int ncpus;
    HvPerCpu percpu[HV_MAX_CPUS];
    /* With more than one CPU, only the holder of this runs guest code (a fair
       ticket lock, handed over at every kick and while a CPU sleeps). */
    int big_lock_on;
    /* Devices, the GIC and the ICC registers: one CPU at a time (recursive). */
    pthread_mutex_t dev_mu;
    /* Translating and inserting blocks, the JIT region and the slots. */
    pthread_mutex_t tr_mu;
    /* Stopping every CPU to flush all translations. */
    pthread_mutex_t stw_mu;
    pthread_cond_t stw_cv;
    int stw_active;
    pthread_mutex_t big_mu;
    pthread_cond_t big_cv;
    uint64_t big_next, big_serving;
    int stats_interval;  /* seconds between --stats lines, 0 = off */
    /* --profile: host PCs of the CPU thread sampled every millisecond, drained by the stats line. */
    uint64_t *prof;
    uint32_t prof_head, prof_tail;
} HvMachine;

static inline uint32_t hv_block_hash(uint64_t va, uint64_t pa, uint32_t flags) {
    uint64_t h = (va >> 2) ^ (pa >> 2) * 0x9e3779b97f4a7c15ull ^ flags;
    return (uint32_t)(h ^ (h >> 29)) & (HV_BLOCK_HASH - 1);
}

/* Lock-free: blocks are only added (release store) until a flush, which stops every CPU. */
static inline HvBlock *hv_block_find(HvMachine *m, uint32_t h, uint64_t va, uint64_t pa, uint32_t flags, uint32_t gen) {
    for (HvBlock *b = __atomic_load_n(&m->hash[h], __ATOMIC_ACQUIRE); b; b = __atomic_load_n(&b->next, __ATOMIC_ACQUIRE)) {
        if (b->va == va && b->pa == pa && b->flags == flags && b->gen == gen) {
            /*
             * The generation test above is per page and cannot tell one
             * occupancy of a RAM slot from the next: page_gen is freed and
             * reallocated by add_ram() and starts at zero again, so a block
             * made from the previous occupant matches whenever its own gen was
             * 0.  b->ram points at the same HvRam either way, because slots are
             * reused in place, so nothing else in this comparison notices.
             *
             * ram_epoch does, and it is the last check available here -- any
             * block that gets past it is returned to the dispatcher, which
             * jumps straight into code translated against memory the guest may
             * no longer own.
             *
             * (Scope, so nobody re-derives the wrong lesson: 13.35 measured
             * 4 reuses per disk boot with zero live blocks on the slot each
             * time, so this particular aliasing has never been observed.  The
             * retired-window case is the one with a real NULL in it, and it is
             * covered by the same counter plus the size test in lookup().)
             */
            if (b->ram_epoch != b->ram->epoch) {
                m->stats.epoch_stale++;
                {
                    uint32_t d = b->ram->epoch - b->ram_epoch;
                    if (d > m->stats.epoch_high_water) m->stats.epoch_high_water = d;
                }
                /* Counted only; this header has no stdio. */
                return NULL;
            }
            return b;
        }
    }
    return NULL;
}

int hv_machine_init(HvMachine *m, size_t jit_bytes);
/* The same with JIT memory the host provides (iOS: the region a debugger granted and its writable alias). */
int hv_machine_init_jit(HvMachine *m, void *rx, void *rw, size_t jit_bytes);
void hv_machine_free(HvMachine *m);
int hv_machine_add_ram(HvMachine *m, uint64_t pa, uint64_t size, void *host, int readonly);
int hv_machine_add_mmio(HvMachine *m, uint64_t pa, uint64_t size, void *opaque,
                        uint64_t (*read)(void *, uint64_t, unsigned),
                        void (*write)(void *, uint64_t, uint64_t, unsigned), const char *name);

HvRam *hv_ram_lookup(HvMachine *m, uint64_t pa);
/* Drop the translations made from the RAM page holding pa (it was written, or the guest invalidated it). */
void hv_invalidate_code(HvMachine *m, uint64_t pa);
void hv_ret_clear(HvCpu *cpu);
int hv_ic_ivau_drops(void);
/* Settings that say how to translate or wait, to compare ways of doing it in one running guest
   ("knob NAME VALUE" in HV_INPUT_FILE; a new way starts from an empty code cache). Each starts
   from the environment variable named in hv_knob_names. */
enum { HV_K_NO_RAS, HV_K_SUPERBLOCKS, HV_K_GROUPS, HV_K_WFI_SPIN, HV_K_FLUSH, HV_K_TEST1, HV_K_TEST2, HV_K_TEST3, HV_K_TLBT, HV_K_JITCAP, HV_K_RECHECK, HV_K_COUNT };
extern int hv_knob[HV_K_COUNT];
int hv_knob_set(HvMachine *m, const char *name, int value);
/* Debugging (HV_WATCH): which pages keep losing their translations. */
extern uint32_t *hv_smc_counts;
extern uint64_t *hv_smc_last;
extern uint64_t hv_smc_pages, hv_smc_cpu, hv_smc_dma;
/* A device wrote guest memory directly: translations made from it are out of date. Any thread. */
void hv_dma_written(HvMachine *m, uint64_t pa, uint64_t len);
HvMmio *hv_mmio_lookup(HvMachine *m, uint64_t pa);
/* Host pointer for `len` bytes of guest RAM at pa, or NULL. */
void *hv_phys_ptr(HvMachine *m, uint64_t pa, uint64_t len);

/* Physical accesses from C (page-table walks, devices doing DMA, slow paths). */
int hv_phys_read(HvMachine *m, uint64_t pa, void *buf, unsigned len);
int hv_phys_write(HvMachine *m, uint64_t pa, const void *buf, unsigned len);

void hv_cpu_reset(HvCpu *cpu, HvMachine *m); /* CPU 0 */
void hv_cpu_reset_index(HvCpu *cpu, HvMachine *m, uint32_t index);
/* The CPU this thread runs (NULL outside the dispatcher: tests, devices). */
extern __thread HvCpu *hv_self;
void hv_dev_lock(HvMachine *m);
void hv_dev_unlock(HvMachine *m);
/* Ask another CPU to apply a TLBI (or HV_REQ_* work); returns the sequence to wait for. */
uint64_t hv_cpu_post_tlbi(HvCpu *target, uint32_t op1, uint32_t crn, uint32_t crm, uint32_t op2, uint64_t xt);
uint64_t hv_cpu_post(HvCpu *target, uint32_t flags);
/* Wait until target has done everything up to seq (or is parked, and will before it runs). */
void hv_cpu_sync(HvCpu *self, HvCpu *target, uint64_t seq);
/* The owner: do what other CPUs asked. */
void hv_cpu_process_requests(HvCpu *cpu);
void hv_big_lock(HvMachine *m);
void hv_big_unlock(HvMachine *m);
/* Let a waiting CPU run (the lock is held again on return). */
void hv_big_yield(HvMachine *m);
/* Make every CPU leave its block at the next exit. */
void hv_machine_kick_all(HvMachine *m);
/* Wake one CPU out of WFI (and make it leave its block). */
void hv_cpu_wake(HvCpu *cpu);
/* Make it leave its block at the next checked exit, without waking it from WFI. */
void hv_cpu_kick(HvCpu *cpu);

/* From any thread: device work is waiting for the CPU thread's tick. Makes a
   running block leave and ends a WFI sleep. */
void hv_machine_wake(HvMachine *m);

#endif
