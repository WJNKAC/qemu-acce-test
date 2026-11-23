/*
 * Henge accelerator: the engine-side half of the bridge
 *
 * Everything QEMU calls that has to know the engine's private layouts lives
 * here.  This file is compiled as part of the engine static library, so it
 * sees engine/core/*.h and NOT QEMU's headers: the two worlds share a
 * vocabulary (HvMachine, HvCpu) but their headers must never be included in
 * the same translation unit, because the engine defines its own cpu.h /
 * machine.h with names QEMU also uses.
 *
 * The QEMU-side half is henge-cpu.c (registers) plus henge-accel*.c.
 *
 * Three obligations of the engine that are easy to miss, and that this file
 * exists to honour:
 *
 *   1. HvCpu needs 128-byte alignment.  It has `aligned(128)` members (the
 *      TLB tables and ret_salt), so plain malloc - 8 or 16 bytes on glibc -
 *      is not enough.  main_android.c got away with a static array, where the
 *      compiler does it for you.
 *   2. The storage must be ZERO before hv_cpu_reset_index().  That function
 *      reads p->ijc_tables_used and p->ijc_tables_used is part of HvPerCpu,
 *      which lives in the machine, not in the CPU -- but it also memsets the
 *      CPU in three ranges that deliberately skip m and pc_state.  Passing
 *      uninitialised heap would make it walk garbage table pointers.
 *   3. hv_machine_init() does NOT read the HV_* environment knobs (only
 *      hv_machine_init_jit() calls knobs_init()).  That is not a bug to fix
 *      here: every measurement this project has - 74.0 ns at 512 MB, the
 *      +8.0% boot cost of the EL split - was taken with the knobs at zero.
 *      "Fixing" it would silently move the baseline.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* mach_absolute_time() is the engine's portable name for "host counter, 24 MHz"
 * (compat/mach/mach_time.h defines it as hv_host_ticks_24mhz()).  The WFI path
 * in dispatch.c compares tick()'s return value against it, so the tick stub
 * below has to be in the same domain. */
#include <mach/mach_time.h>

#include "engine/core/cpu.h"
#include "engine/core/machine.h"
#include "engine/core/mmu.h"
#include "engine/core/exception.h"
#include "engine/core/sysreg.h"   /* hv_guest_ticks */
#include "engine/core/dispatch.h"

/* The contract header is written for QEMU TUs (it pulls in qemu/osdep.h), so
 * it cannot be included here.  What this file needs from it are the two
 * prototypes QEMU expects, declared identically; henge-cpu.c asserts they
 * still match.  Keep these in sync with include/system/henge-engine.h. */
typedef int (*HvMmioForward)(void *opaque, uint64_t pa, void *buf,
                             uint32_t len, int is_write);

/* ------------------------------------------------------------------ */
/* Machine                                                             */
/* ------------------------------------------------------------------ */

HvMachine *hv_engine_machine_new(size_t jit_bytes)
{
    HvMachine *m;

    if (jit_bytes < (1u << 20)) {
        jit_bytes = 1u << 20;
    }
    m = calloc(1, sizeof *m);
    if (!m) {
        return NULL;
    }
    /* Allocates the JIT region and every per-machine table.  No RAM: under
     * QEMU the memory belongs to a MemoryRegion and arrives later through
     * hv_machine_add_ram(). */
    if (hv_machine_init(m, jit_bytes) != 0) {
        free(m);
        return NULL;
    }
    /* Read once: the deferred-flush instrumentation is off unless asked for. */
    m->dbg_flush = getenv("HV_DBG_FLUSH") != NULL;
    return m;
}

/*
 * @defer_flush: caller is a host thread that must not touch any vCPU's TLB
 * (QEMU's MemoryListener, which runs on the main thread holding the BQL while
 * vCPUs are live).  It retires the window here and expects a following
 * hv_engine_request_flush() to do the invalidation at a point where every vCPU
 * is parked.  Without it, hv_tlb_flush() would memset a TLB that a running
 * vCPU is reading: measured at 619,156 torn reads in five seconds on a single
 * entry, each one an addend of 0x8080808080808080 added to a guest address.
 */
int hv_machine_del_ram_flags(HvMachine *m, uint64_t pa, uint64_t size,
                             int defer_flush)
{
    HvRam *r = NULL;
    int i;

    /*
     * Slot-identity counters, printed unconditionally every 64 calls.
     *
     * Unconditionally is the whole point, and it is the lesson of 13.34/13.35:
     * the first version of this probe was gated twice -- once by
     * getenv("HV_P0A_STATS"), which nothing ever set, and once by living
     * inside print_stats(), which the port never enabled because it never
     * assigned m->stats_interval.  A run then produced a log with no probe
     * lines in it, and that absence was written down as "measured zero".  An
     * instrument that has never printed a non-zero value is worse than no
     * instrument: it carries the appearance of having measured something.
     *
     * So: no getenv, no stats_interval, no level.  A disk boot makes 700+ of
     * these calls, which is eleven lines.
     */
    {
        static unsigned ndel;
        unsigned n = __atomic_add_fetch(&ndel, 1, __ATOMIC_RELAXED);

        if ((n & 63) == 0) {
            fprintf(stderr, "henge: del#%u defer=%d del_hit=%llu del_miss=%llu "
                    "ram_reuse=%llu retired_hit=%llu epoch_stale=%llu hw=%llu nram=%d\n",
                    n, defer_flush,
                    (unsigned long long)m->stats.del_hit,
                    (unsigned long long)m->stats.del_miss,
                    (unsigned long long)m->stats.ram_reuse,
                    (unsigned long long)m->stats.retired_hit,
                    (unsigned long long)m->stats.epoch_stale,
                    (unsigned long long)m->stats.epoch_high_water,
                    m->nram);
        }
    }

    for (i = 0; i < m->nram; i++) {
        if (m->ram[i].host && m->ram[i].pa == pa) {
            r = &m->ram[i];
            break;
        }
    }
    if (!r) {
        /* No live, still-mirrored window at this base.  Most dels on a disk
           boot are these: once the romd variable store has entered command
           mode it is on the never-mirror list, so every later toggle of it
           produces a region_del with nothing left in the engine to retire. */
        m->stats.del_miss++;
        return -1;
    }
    m->stats.del_hit++;
    /*
     * Both of these reach into state another vCPU may be using right now --
     * hv_invalidate_code() walks the chained-exit list and the IJC, and
     * hv_tlb_flush() memsets the TLB -- so a deferred caller skips them and
     * leaves the whole job to the flush it requests.  That flush empties the
     * blocks, the JIT, every IJC, the return tables and (via need_tlb_flush)
     * every TLB entry, which is a superset of what these two do.
     */
    if (!defer_flush) {
        /* 1. Kill every translation that came from these pages.  hv_invalidate_code
         *    bumps page_gen so the next lookup retranslates, and reaches into the
         *    chained exits and the indirect-branch caches of other CPUs.  Doing
         *    this before dropping the arrays is deliberate: it needs
         *    code_pages/page_gen to still be there. */
        {
            uint64_t pages = (r->size + (1u << HV_TLB_PAGE_BITS) - 1) >> HV_TLB_PAGE_BITS;
            uint64_t pg;

            for (pg = 0; pg < pages; pg++) {
                if (r->code_pages[pg]) {
                    hv_invalidate_code(m, r->pa + (pg << HV_TLB_PAGE_BITS));
                }
            }
        }

        /* 2. Drop every CPU's TLB: entries hold host addresses into memory that
         *    QEMU is about to hand to somebody else.  Legitimate here only
         *    because a non-deferring caller is the owner (reset, boot) or has
         *    already parked everybody. */
        for (i = 0; i < HV_MAX_CPUS; i++) {
            if (m->cpus[i]) {
                hv_tlb_flush(m->cpus[i]);
            }
        }
    }

    /* 3. Release the bookkeeping, then *retire the slot*.  size = 0 alone made
     *    hv_ram_lookup() (pa - r->pa < r->size) miss it, which covers
     *    hv_phys_ptr and the DMA path -- but it left m->nram untouched, and
     *    add_ram() consumes a slot every call.  HV_MAX_RAM is 8, so eight
     *    add/remove cycles exhausted the table and every later add failed
     *    with "failed to mirror".
     *
     *    That was not theoretical: pflash calls
     *    memory_region_rom_device_set_romd() on every CFI command write, and
     *    with the listener finally wired each toggle is a del + add of the
     *    whole 64 MB variable-store window.  UEFI reached the shell with
     *    twenty-seven "failed to mirror virt.flash1" lines behind it, i.e. it
     *    had been running with the window absent from the engine.
     *
     *    Compaction is what makes the slot reusable.  The last entry moves
     *    into the hole, so main_ram (a pointer into the array) needs the same
     *    move applied -- otherwise it dangles into the vacated tail. */
    /*
     * Bump the epoch on the way out.  This is the load-bearing line.
     *
     * This function frees page_gen and zeroes size, so from here until the
     * next add_ram() the slot is "retired": a block translated from it still
     * carries the same pa and flags, and -- before this line existed -- the
     * same epoch too, because only add_ram() bumped it.  Every test in the
     * dispatcher's fast path therefore passed, and the next thing it evaluated
     * was b->ram->page_gen[b->pg], i.e. NULL[pg]: a SIGSEGV in the host, not a
     * wrong guest read.
     *
     * Upstream never hits it because the standalone engine deletes RAM only at
     * teardown, with no blocks in flight.  The port deletes it constantly, from
     * a MemoryListener, while vCPUs run -- pflash toggles the romd variable
     * store twice per CFI command write, 704 times in one disk boot.  So this
     * is a genuine engine-API hazard made reachable by a hosted caller, and it
     * is a candidate for the first patch sent upstream rather than kept in
     * local-edits.patch.  Tracked in QEMU-BACKEND.md 13.36; not urgent.
     *
     * Not observed in the field yet (retired_hit = 0 across six boots, 13.35):
     * of the 704 calls only 5 found a live window, and those 5 all happened
     * before any block existed.  Correct by construction, with nrun v2's reset
     * loop as its designated observer.
     */
    r->epoch++;
    free(r->code_pages);
    free(r->page_gen);
    free(r->whint);
    r->code_pages = NULL;
    r->page_gen = NULL;
    r->whint = NULL;
    r->host = NULL;
    r->size = 0;
    r->pa = 0;
    r->readonly = 0;
    if (m->main_ram == r) {
        /* Leave no dangling main_ram.  Do NOT compact the array to do this:
         * hv_ram_lookup() hands out HvRam * that callers hold across further
         * add/remove calls, so moving entries turns those into use-after-move.
         * Measured as an immediate SIGSEGV at the first romd toggle.  add_ram()
         * reuses a retired slot instead, which keeps every pointer stable. */
        m->main_ram = NULL;
        for (i = 0; i < m->nram; i++) {
            if (m->ram[i].size &&
                (!m->main_ram || m->ram[i].size > m->main_ram->size)) {
                m->main_ram = &m->ram[i];
            }
        }
    }
    return 0;
}

int hv_machine_del_ram(HvMachine *m, uint64_t pa, uint64_t size)
{
    return hv_machine_del_ram_flags(m, pa, size, 0);
}

/*
 * Ask for a full invalidation at the next safe point, from a thread that must
 * not touch a vCPU itself.
 *
 * This is the engine's own mechanism, not a new one: flush_pending is what
 * helpers use, and dispatch.c's loop already heads every iteration with
 *
 *     if (flush_pending || stw_active) { stop_the_world(cpu); continue; }
 *
 * stop_the_world parks everybody (active == 0, the two-phase handshake in
 * park/unpark is what closes the entry race), then calls hv_flush_blocks under
 * tr_mu.  need_tlb_flush makes that flush empty the entries as well, which is
 * what a removed or demoted RAM window requires.
 *
 * Deliberately does not wait: the caller holds the BQL, and a vCPU that is
 * inside henge_mmio_forward() is waiting for that same BQL.  Blocking here
 * would deadlock the VM.  The window between this call and the flush is real
 * and bounded by one block's execution plus the stop-the-world handshake; the
 * guest still reads the old mapping through its TLB for that long, which is
 * what the caller's own "retire the window first" step is for.
 */
void hv_engine_request_flush(HvMachine *m)
{
    int i;

    if (!m) {
        return;
    }
    /*
     * HV_DBG_FLUSH doubles as the Phase 1 acceptance gate: it stamps the
     * request and reports the delay when the flush actually happens, so the
     * semantic window is a number instead of a hope.  Off by default.
     */
    if (m->dbg_flush) {
        m->flush_req_ns = mach_absolute_time();
        m->flush_reqs++;
    }
    __atomic_store_n(&m->need_tlb_flush, 1, __ATOMIC_SEQ_CST);
    __atomic_store_n(&m->flush_pending, 1, __ATOMIC_SEQ_CST);
    for (i = 0; i < m->ncpus; i++) {
        if (m->cpus[i]) {
            /* Wake, not just kick: a vCPU sleeping in WFI inside
             * wait_for_interrupt() is parked and has to come back to a
             * dispatcher iteration to see flush_pending at all. */
            hv_cpu_wake(m->cpus[i]);
        }
    }
}


HvCpu *hv_engine_cpu_new(HvMachine *m, uint32_t index)
{
    HvCpu *cpu = NULL;
    void *p = NULL;

    if (!m || index >= (uint32_t)HV_MAX_CPUS) {
        return NULL;
    }
    if (posix_memalign(&p, 128, sizeof *cpu) != 0) {
        return NULL;
    }
    cpu = p;
    memset(cpu, 0, sizeof *cpu);   /* see obligation (2) above */
    /* The _index form: hv_cpu_reset() would hardcode 0 and alias every vCPU
     * onto m->cpus[0]. */
    hv_cpu_reset_index(cpu, m, index);
    return cpu;
}

void hv_engine_cpu_set_mpidr(HvCpu *cpu, uint64_t mpidr)
{
    cpu->mpidr = mpidr;
}

/* ------------------------------------------------------------------ */
/* MMIO: one catch-all region that forwards everything to QEMU          */
/* ------------------------------------------------------------------ */

static HvMmioForward mmio_forward;
static void *mmio_opaque;

/*
 * The engine resolves a physical access in two steps: hv_ram_lookup() for RAM,
 * then hv_mmio_lookup() over a small table of registered windows.  Under QEMU
 * the set of device windows is large, dynamic and owned by the other side, so
 * instead of mirroring it we register ONE window covering the whole physical
 * address space.  RAM wins the race because hv_phys_read/hv_phys_write check
 * RAM first, so this only ever sees what RAM did not claim.
 *
 * The engine passes the offset within the window, not the address; with a base
 * of 0 they are the same number.  That is why the base is 0 and not the
 * beginning of the device range.
 */
static uint64_t mmio_fwd_read(void *opaque, uint64_t off, unsigned size)
{
    uint64_t v = 0;

    if (!mmio_forward || size > 8) {
        return 0;
    }
    if (mmio_forward(mmio_opaque, off, &v, size, 0) != 0) {
        /* Nothing to raise from here: the engine's callback API has no error
         * return, so a failed device read becomes zeroes.  QEMU's own
         * unassigned-memory path logs the access, which is where to look. */
        return 0;
    }
    return v;
}

static void mmio_fwd_write(void *opaque, uint64_t off, uint64_t val,
                           unsigned size)
{
    if (!mmio_forward || size > 8) {
        return;
    }
    mmio_forward(mmio_opaque, off, &val, size, 1);
}

void hv_engine_set_mmio_forward(HvMachine *m, HvMmioForward fn, void *opaque)
{
    mmio_forward = fn;
    mmio_opaque = opaque;
    if (!m || !fn || m->nmmio) {
        return;
    }
    if (hv_machine_add_mmio(m, 0, ~0ull, NULL,
                            mmio_fwd_read, mmio_fwd_write, "qemu") != 0) {
        fprintf(stderr, "henge: cannot register the MMIO catch-all; "
                        "device accesses will fault the guest\n");
        return;
    }
    /* self_locked: the forwarder serialises itself (it takes QEMU's BQL), so
     * the engine must not also take its own device lock around it -- that
     * would invert the QEMU-side lock order on the next MemoryListener
     * callback. */
    m->mmio[m->nmmio - 1].self_locked = 1;
}

/* ------------------------------------------------------------------ */
/* Seams: what the host owns instead of the engine                     */
/* ------------------------------------------------------------------ */

/*
 * Install the read-through interrupt hook (machine.h irq_line_get).
 *
 * The implementation lives on the QEMU side (henge-accel-ops.c): this file
 * cannot see CPUState or qatomic_read -- it deliberately includes no QEMU
 * headers -- so all it does is store the callback and its context.  Keeping
 * the split here is what lets the engine build standalone (AppleVM) with its
 * own GIC behind the same field.
 */
void hv_engine_set_irq_hook(HvMachine *m,
                            int (*fn)(void *ctx, unsigned cpu_index, int fiq),
                            void *ctx)
{
    if (!m) {
        return;
    }
    m->irq_line_get = fn;
    m->irq_line_ctx = ctx;
}

void hv_engine_set_external(HvMachine *m, int sysreg, int psci)
{
    if (!m) {
        return;
    }
    m->sysreg_external = sysreg ? 1 : 0;
    m->psci_external = psci ? 1 : 0;
}

/*
 * stats_interval: one field, two jobs, and that is the trap.
 *
 * It gates *counting* -- a whole class of increments in mmu.c and translate.c
 * is wrapped in `if (m->stats_interval)`: tlb_range_flushes, kernel_ranges,
 * protect_kind, race_kind, chained_early.  Zero does not mean "nothing
 * happened", it means "nothing is being counted".
 *
 * It also gates *printing* -- print_stats() returns early unless
 * `now - last_t >= stats_interval * 24MHz`.
 *
 * The standalone runner sets it from --stats.  The QEMU port never set it at
 * all, so every one of those numbers has been structurally zero since the port
 * began, and the absence of the dump was read as the absence of the event --
 * five separate times.
 *
 * Callers that want counting without a stats stream should pass a value longer
 * than the run (the accelerator uses one hour).  A caller that passes 0 gets
 * silence *and* no counting, which is never what anyone means.
 */
void hv_engine_set_stats_interval(HvMachine *m, int secs)
{
    if (m && secs > 0) {
        m->stats_interval = secs;
    }
}

int hv_engine_sysreg_pending(const HvCpu *cpu, uint32_t *reg, int *rt,
                             int *is_write, uint64_t *pc, uint64_t *value,
                             int *el)
{
    uint32_t insn;

    if (cpu->exit_reason != HV_EXIT_SYSREG_EXT) {
        return 0;
    }
    insn = cpu->exit_insn;
    /* The engine's own packing (see R() in core/sysreg.c): op0:op1:crn:crm:op2
       in 16 bits.  Handing this over rather than the raw instruction keeps the
       decoding in one place -- the engine already got it right, including the
       deprecation aliases. */
    if (reg) {
        *reg = (insn >> 5) & 0xffff;
    }
    if (rt) {
        *rt = insn & 0x1f;
    }
    if (is_write) {
        /* AArch64: bit 21 is L -- 1 for MRS (read), 0 for MSR (write). */
        *is_write = ((insn >> 21) & 1) ? 0 : 1;
    }
    if (pc) {
        *pc = cpu->pc;
    }
    if (value) {
        /*
         * For an MSR, the value the guest wrote, out of Rt.  Passing it here
         * rather than exposing HvCpu.x[] keeps the register file's layout in
         * one place -- the same reason HvCpu is opaque to QEMU.
         *
         * Rt == 31 is XZR for a write, and must contribute 0 -- not x[31].
         * HvCpu.x is `uint64_t x[31]` (indices 0..30, XZR is not stored,
         * because it is not a register), so x[31] reads whatever field the
         * compiler put next, which here is a host pointer.  Getting this wrong
         * is not a rounding error: `MSR ICC_BPR1_EL1, xzr` -- which is how
         * Linux zeroes the binary point register -- carried
         * 0xffff800082ae3af0 into icc_bpr_write(), `value & 7` became 0, and
         * QEMU's GICv3 asserted on `bpr > 0` a few instructions later.  The
         * engine's own path (core/sysreg.c, hv_sysreg_msr) has always done
         * `rt == 31 ? 0 : cpu->x[rt]`; this bridge is the copy that forgot.
         */
        unsigned rt = insn & 0x1f;

        *value = ((insn >> 21) & 1) ? 0 : (rt == 31 ? 0 : cpu->x[rt]);
    }
    if (el) {
        /* The engine's PSTATE is the authority, not QEMU's env: env is only
           written when the two are synchronised, and this exit happens in the
           middle of a run.  A permission check against a stale EL would let an
           EL0 access to a PL1 register through. */
        *el = (int)cpu->el;
    }
    return 1;
}

void hv_engine_sysreg_resume(HvCpu *cpu, uint64_t value, int handled)
{
    int is_write = ((cpu->exit_insn >> 21) & 1) ? 0 : 1;
    int rt = cpu->exit_insn & 0x1f;

    if (!handled) {
        /* The host does not know it either: put back the semantics the engine
           would have applied on its own, which is UNDEF.  hv_raise_undef moves
           pc to the vector and sets HV_EXIT_EXCEPTION, so the caller's next
           hv_run() carries on inside the guest's handler. */
        hv_raise_undef(cpu, cpu->pc);
        return;
    }

    if (!is_write && rt != 31) {
        cpu->x[rt] = value;
    }
    cpu->pc += 4;
    cpu->exit_reason = HV_EXIT_BRANCH;
    /* An MSR can unmask interrupts or program a timer that fires at once; the
       engine's own path rechecks for that here, and a forwarded write must not
       be the one case where it is skipped. */
    if (is_write) {
        hv_check_interrupts(cpu);
    }
}

int hv_engine_psci_pending(const HvCpu *cpu, uint64_t *pc, uint64_t args[4],
                           int *is_smc)
{
    if (cpu->exit_reason != HV_EXIT_PSCI_EXT) {
        return 0;
    }
    if (is_smc) {
        /* SMC is ll == 3, HVC is ll == 2 (instruction bits 1:0).  The host
           needs it because its conduit decides by exception type. */
        *is_smc = (cpu->exit_insn & 3) == 3;
    }
    if (pc) {
        *pc = cpu->pc;
    }
    if (args) {
        int i;
        for (i = 0; i < 4; i++) {
            args[i] = cpu->x[i];
        }
    }
    return 1;
}

void hv_engine_psci_resume(HvCpu *cpu, uint64_t ret, int handled)
{
    if (!handled) {
        /* No conduit answered: the call is undefined, as SMC is without EL3. */
        hv_raise_undef(cpu, cpu->pc);
        return;
    }
    cpu->x[0] = ret;
    cpu->pc += 4;
    cpu->exit_reason = HV_EXIT_BRANCH;
}

/* ------------------------------------------------------------------ */
/* Machine reset: what a system_reset has to throw away                */
/* ------------------------------------------------------------------ */

/*
 * The engine keeps four kinds of derived state that outlive a reboot if nobody
 * drops them, and every one of them is silently wrong afterwards:
 *
 *   translated blocks   the new image is at the same addresses with different
 *                       bytes; a block key is {va, pa, flags, gen}, and none of
 *                       those four changed, so the old translation is a match
 *   software TLB        entries hold host addends for the previous page tables
 *   whint / code_pages  which pages held code, and which TLB entries mapped
 *                       them writable
 *   indirect-branch     targets into blocks that no longer exist
 *   caches, ret_tab
 *
 * hv_flush_blocks() drops blocks and every reference to them; hv_tlb_flush()
 * empties a CPU's tables.  Doing both for every CPU here is the only place
 * that can: a vCPU-level reset knows about one CPU, and code invalidation
 * knows about one page.
 */
void hv_engine_machine_reset(HvMachine *m)
{
    int i;

    if (!m) {
        return;
    }
    hv_flush_blocks(m);
    for (i = 0; i < HV_MAX_CPUS; i++) {
        if (m->cpus[i]) {
            hv_tlb_flush(m->cpus[i]);
        }
    }
    /* Whint (which entries mapped a now-code page writable) and the per-page
       generation counters describe the previous address space.  Zeroing the
       generations is enough: a block remembers the generation it was made
       under, and nothing is left to compare against. */
    for (i = 0; i < m->nram; i++) {
        HvRam *r = &m->ram[i];
        uint64_t pages = (r->size + (1u << HV_TLB_PAGE_BITS) - 1) >> HV_TLB_PAGE_BITS;

        if (r->code_pages) {
            memset(r->code_pages, 0, (size_t)1 << r->pages_log2);
        }
        if (r->page_gen) {
            memset(r->page_gen, 0, pages * sizeof *r->page_gen);
        }
        if (r->whint) {
            memset(r->whint, 0, pages * HV_MAX_CPUS * sizeof *r->whint);
        }
    }
}

/* Drop every RAM window.  A system_reset re-mirrors from the new flatview, and
   a region that disappeared would otherwise stay in the table pointing at
   memory QEMU has released. */
void hv_engine_ram_clear(HvMachine *m)
{
    int i;

    if (!m) {
        return;
    }
    for (i = 0; i < m->nram; i++) {
        HvRam *r = &m->ram[i];

        free(r->code_pages);
        free(r->page_gen);
        free(r->whint);
        r->code_pages = NULL;
        r->page_gen = NULL;
        r->whint = NULL;
        r->host = NULL;
        r->size = 0;
        r->pa = 0;
        r->readonly = 0;
    }
    m->nram = 0;
    m->main_ram = NULL;
}

uint64_t hv_engine_access_pc(const HvMachine *m)
{
    return m ? m->access_pc : 0;
}

/* ------------------------------------------------------------------ */
/* The time base                                                       */
/* ------------------------------------------------------------------ */

/*
 * K, not a callout.  The guest's CNTFRQ comes from the host's timer model and
 * on this machine is 62.5 MHz, while the engine counts at 24 MHz; the two
 * clocks run at the same *rate* only after scaling, and differ by a constant.
 * So: scale once (a multiply by a fixed ratio), then subtract an epoch.  Guest
 * counter reads stay pure arithmetic -- no host call, no lock, no clock read
 * beyond the one already needed.
 *
 * timer_freq is not a #define any more.  Hardcoding 24 MHz is how the guest
 * ends up calibrating its delay loop against a frequency the deadlines are not
 * measured in.
 */
void hv_engine_set_timer_freq(HvMachine *m, uint64_t freq)
{
    if (!m || !freq) {
        return;
    }
    m->timer_freq = freq;
    /* counter() domain -> guest domain, as an exact rational: the port's
       counter is 24 MHz (compat/mach/mach_time.h scales the host's CNTVCT
       there), so num/den is freq/24000000.  Kept unreduced on purpose: den > 1
       is what tells the read path whether it needs the multiply at all. */
    m->timer_scale_num = freq;
    m->timer_scale_den = 24000000ull;
}

uint64_t hv_engine_timer_freq(const HvMachine *m)
{
    return m ? m->timer_freq : 0;
}

uint64_t hv_engine_timer_ticks(HvMachine *m)
{
    return m ? hv_guest_ticks(m) : 0;
}

void hv_engine_set_timer_epoch(HvMachine *m, uint64_t epoch)
{
    if (!m) {
        return;
    }
    /* Read on every counter access from other threads, so publish it as one
       64-bit store rather than a plain assignment the compiler may tear. */
    __atomic_store_n(&m->timer_epoch, epoch, __ATOMIC_RELEASE);
}



/* ------------------------------------------------------------------ */
/* Interrupt lines                                                     */
/* ------------------------------------------------------------------ */

/*
 * The host's GIC drives its own qemu_irq into the CPU, which lands in
 * CPUState.interrupt_request; the engine only ever looks at HvPerCpu's two
 * line bytes.  This is the join between them, and it is deliberately a plain
 * level copy with no edge logic: the engine's own hv_check_interrupts() decides
 * whether the current PSTATE lets the interrupt in, exactly as it does for its
 * own standalone GIC.  Duplicating that decision here (against QEMU's env,
 * which is stale mid-run) is how you get an interrupt delivered at EL0 that
 * should have waited for EL1.
 */
void hv_engine_set_irq(HvCpu *cpu, int irq, int fiq)
{
    HvPerCpu *p;

    if (!cpu || !(p = cpu->pc_state)) {
        return;
    }
    __atomic_store_n(&p->irq_line, irq ? 1 : 0, __ATOMIC_RELEASE);
    __atomic_store_n(&p->fiq_line, fiq ? 1 : 0, __ATOMIC_RELEASE);
}

int hv_engine_get_irq(HvCpu *cpu, int fiq)
{
    HvPerCpu *p;

    if (!cpu || !(p = cpu->pc_state)) {
        return -1;
    }
    /*
     * Answer from the same place the dispatcher asks (irq_line_get), so the
     * monitor shows the level the engine is actually acting on rather than a
     * shadow that nothing refreshes any more.  Falls back to the byte for a
     * standalone machine with no hook installed, which is authoritative there.
     */
    if (cpu->m && cpu->m->irq_line_get) {
        return cpu->m->irq_line_get(cpu->m->irq_line_ctx, cpu->index, fiq);
    }
    return fiq ? __atomic_load_n(&p->fiq_line, __ATOMIC_ACQUIRE)
               : __atomic_load_n(&p->irq_line, __ATOMIC_ACQUIRE);
}

void hv_engine_get_cpu_state(HvCpu *cpu, uint64_t *pc, uint64_t *daif,
                             uint64_t *el)
{
    if (!cpu) {
        *pc = *daif = *el = (uint64_t)-1;
        return;
    }
    *pc = cpu->pc;
    *daif = cpu->daif;
    *el = cpu->el;
}

uint64_t hv_engine_get_irq_injections(HvCpu *cpu)
{
    if (!cpu) {
        return 0;
    }
    return __atomic_load_n(&cpu->irq_injected, __ATOMIC_RELAXED);
}

/* ------------------------------------------------------------------ */
/* DMA: a write that did not come from the CPU                          */
/* ------------------------------------------------------------------ */

/*
 * The engine's own stores invalidate code inline (hv_phys_write checks
 * code_pages).  A device writing guest RAM never goes through that path: it
 * enters QEMU, and without this the engine would keep executing the old
 * translation of a page that has just been overwritten -- the classic
 * DMA->self-modifying-code hole, and the one thing that makes "load a kernel
 * module and run it" fail in a way that looks like memory corruption.
 *
 * hv_dma_written() is the engine's existing primitive for this (the standalone
 * build needs it too, for its inlined NVMe), and it is already cheap in the
 * right way: it looks the page up and only does work for pages that are
 * actually marked as code.  The caller guards on RAM-ness, so an MMIO write
 * never reaches even that.
 */
void hv_engine_dma_written(HvMachine *m, uint64_t pa, uint64_t len)
{
    /* The engine's own store path does this inline (hv_phys_write checks
     * code_pages); a write from outside -- a device DMA, the monitor -- does
     * not, and would otherwise leave a stale translation of bytes that just
     * changed.  hv_dma_written is the same primitive either way. */
    if (!m || !len) {
        return;
    }
    hv_dma_written(m, pa, len);
}

/*
 * The mapped-DMA form used to live here as a hand-rolled reverse scan over the
 * engine's own GPA->host table.  It was removed: it only worked for anonymous
 * RAM, and silently missed for memfd/file-backed RAM (the host pointer QEMU
 * hands out is not inside the recorded window), leaving stale translations
 * behind.  The reverse lookup now uses qemu_ram_block_from_host() on the QEMU
 * side, in accel/henge/henge-accel.c:hv_engine_dma_written_ram().
 */

/* ------------------------------------------------------------------ */
/* The tick that never was                                             */
/* ------------------------------------------------------------------ */

/*
 * Until this existed, m->tick was NULL under henge, and that has a
 * consequence much sharper than "WFI costs one host round trip":
 *
 *     wait_for_interrupt():
 *         uint64_t deadline = m->tick ? m->tick(m, cpu) : 0;
 *         ...
 *         if (!m->tick) return -1;     // "nothing could ever wake us"
 *
 * So every WFI unwound the whole engine and handed the vCPU back to QEMU,
 * which parked it on halt_cond until something else kicked it.  Measured on a
 * two-vCPU boot: 512 B-path returns per CPU, and 4 / 2 A-path returns.  The
 * parking itself is correct -- that is not the bug.  The bug is that the engine
 * had no idea when the guest next needed to run, so it could only ever be
 * woken from outside, one host round trip per event.
 *
 * Semantics are copied from the standalone board (port-android/linuxvirt.c),
 * because two hosts must not disagree about what tick() means:
 *
 *     returns  "the counter value of the next expiry, or 0"
 *
 * The standalone returns it in the engine's own 24 MHz counter domain, because
 * there it is the engine that owns the GIC and compares against counter().
 * Here the timer belongs to QEMU -- sysreg_external routes CNTV_* to the
 * cpreg table, so the engine's own cntv_cval/cntv_ctl are stale forever -- so
 * the value cannot come from the engine at all.  A QEMU-side callback computes
 * "how far in the future is this vCPU's next expiry, in 24 MHz ticks" and this
 * stub turns that into the absolute host-counter value the WFI path expects.
 *
 * Why a relative delta rather than an absolute conversion: the guest deadline
 * lives in the guest's CNTFRQ domain and the engine sleeps in the 24 MHz host
 * domain, and the two are only related through timer_epoch (which QEMU
 * recalibrates on every stop/cont).  Converting the difference is epoch-free;
 * converting the absolute deadline would have to reconstruct the epoch a second
 * time and would silently disagree with the calibration after a pause.
 */
static uint64_t (*tick_delta24)(void *opaque, uint32_t index);
static void *tick_opaque;

static uint64_t engine_tick(HvMachine *m, HvCpu *cpu)
{
    uint64_t delta;

    if (!tick_delta24) {
        return 0;
    }
    delta = tick_delta24(tick_opaque, cpu->index);
    if (!delta) {
        return 0;                  /* nothing armed: park, do not time out */
    }
    /* The WFI path compares this against mach_absolute_time(). */
    return mach_absolute_time() + delta;
}

void hv_engine_set_tick(HvMachine *m, uint64_t (*fn)(void *, uint32_t),
                        void *opaque)
{
    if (!m) {
        return;
    }
    tick_delta24 = fn;
    tick_opaque = opaque;
    /* Both or neither: a tick with no source would make wait_for_interrupt()
     * take the "sleep" branch and block until the 10 ms cap, every time. */
    m->tick = fn ? engine_tick : NULL;
    m->tick_opaque = opaque;
}

/* ------------------------------------------------------------------ */
/* Host lifecycle: making hv_run() come back                           */
/* ------------------------------------------------------------------ */

/*
 * The engine decides when to return.  That is fine for the engine's own
 * reasons (WFI, an unmodelled sysreg, an unencodable instruction) and fatal for
 * the host's, and the failure is not subtle once you see it:
 *
 *     guest: reboot: Power down
 *     qemu:  (still alive 20 minutes later, and ignores SIGTERM)
 *
 * QEMU asks a vCPU to leave with qemu_cpu_kick(), which sets cs->exit_request
 * and calls the accelerator's kick.  Ours called hv_cpu_wake(), which sets the
 * engine's own exit_req -- but exit_req is *not* a "return to the host" flag.
 * run_loop() consumes it as "let another CPU have a turn", services devices and
 * carries straight on.  So a vCPU with no reason of its own to leave never
 * leaves, pause_all_vcpus() waits for it forever, and the process cannot shut
 * down.  Under TCG this cannot happen because cpu_exec() tests exit_request at
 * every translation block and returns EXCP_INTERRUPT.
 *
 * halted is the engine's one exit that the host can pull.  run_loop() tests it
 * at the top of every iteration:
 *
 *     hv_cpu_process_requests(cpu);
 *     if (cpu->halted) return HV_EXIT_HALT;
 *
 * so setting it makes the next block boundary an exit, which is the same
 * latency class as TCG's per-block test.  It is also the flag PSCI CPU_OFF
 * already uses, so the host-requested stop and the guest-requested one converge
 * on the exit that henge_dispatch_exit() already knows how to report.
 *
 * Clearing it is the counterpart and must not be forgotten: a vCPU resumed
 * after a stop would otherwise return HV_EXIT_HALT forever without executing
 * anything.
 */
void hv_engine_cpu_request_stop(HvCpu *cpu)
{
    if (!cpu) {
        return;
    }
    cpu->halted = 1;
    hv_cpu_wake(cpu);      /* end a WFI too, not just a running block */
}

void hv_engine_cpu_clear_stop(HvCpu *cpu)
{
    if (!cpu) {
        return;
    }
    cpu->halted = 0;
}

/* ------------------------------------------------------------------ */
/* Advertised features                                                 */
/* ------------------------------------------------------------------ */

/*
 * Tell the translator which extension bits the guest is actually being told it
 * has.
 *
 * Only LSE matters today, and only in one direction: the translator implements
 * ARMv8.1 atomics unconditionally, so on a CPU whose ID_AA64ISAR0.ATOMIC reads
 * zero the guest should get UNDEF but gets execution instead -- wider than the
 * architecture.  TCG traps; henge did not.
 *
 * The engine cannot work this out itself: under a host that owns the system
 * registers, the ID group is forwarded, so the engine's built-in constants are
 * not what the guest sees.  Hence a setter rather than a lookup.
 */
void hv_engine_set_lse(HvMachine *m, int on)
{
    if (m) {
        m->feat_lse = on ? 1 : 0;
    }
}
