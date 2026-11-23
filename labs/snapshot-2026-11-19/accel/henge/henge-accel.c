/*
 * Henge accelerator: AccelClass side
 *
 * An ARM64->ARM64 dynamic binary translator running entirely in user space.
 * QEMU keeps ownership of RAM and devices; this accelerator owns only
 * "how a vCPU runs" (see henge-accel-ops.c).
 *
 * Division of labour, and why the software MMU survives:
 *
 *   guest VA -> guest PA   engine's hv_mmu_walk, reading the *guest's* page
 *                          tables out of guest RAM.  Unchanged under QEMU.
 *   guest PA -> host ptr   provided here, from QEMU's MemoryRegion host
 *                          pointers, via a MemoryListener.
 *
 * So the JIT, block cache, TLB, bank and the EL-based probe split are all
 * untouched: they only care what host pointer a PA maps to, not who owns it.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qapi/error.h"
#include "qapi/visitor.h"
#include "qemu/module.h"
#include "qemu/accel.h"
#include "qemu/main-loop.h"
#include "accel/accel-ops.h"
#include "accel/accel-cpu-ops.h"
#include "system/cpus.h"
/* henge-accel-ops.c: copy this thread's vCPU line into the engine. */
#include "system/memory.h"
#include "system/address-spaces.h"
#include "hw/core/cpu.h"
#include "hw/core/boards.h"
#include "qemu/timer.h"
#include "qemu/host-utils.h"
#include "system/runstate.h"
#include "system/reset.h"
#include "system/henge-accel.h"
#include "system/ramblock.h"
/* Migration is not gated by CONFIG_MIGRATION in this tree: the `migrate` QMP
 * command exists and runs even with --without-default-features (verified: it
 * started and emitted STOP before this notifier existed).  So the guard that
 * looked prudent was in fact the reason migration was not being refused. */
#include "migration/misc.h"
#include "system/henge-engine.h"
/* 注意：这里**不** include "trace.h"。这个配置（--without-default-features）下
   build/trace.h 不会生成，只有 build/trace/trace-root.h。accel/henge/trace-events
   仍然保留（trace/meson.build 要求它存在），等真的要用时再按 QEMU 的方式接。 */

bool henge_allowed;

/* See include/system/henge-accel.h.  Zero unless -accel henge,trace=... */
unsigned henge_trace;

static void henge_trace_parse(const char *spec)
{
    char *copy, *tok, *save = NULL;

    if (!spec) {
        return;
    }
    copy = g_strdup(spec);
    for (tok = strtok_r(copy, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
        if (!strcmp(tok, "all"))                        henge_trace = ~0u;
        else if (!strcmp(tok, "ram"))                   henge_trace |= HENGE_TRACE_RAM;
        else if (!strcmp(tok, "sysreg"))                henge_trace |= HENGE_TRACE_SYSREG;
        else if (!strcmp(tok, "irq"))                   henge_trace |= HENGE_TRACE_IRQ;
        else if (!strcmp(tok, "psci"))                  henge_trace |= HENGE_TRACE_PSCI;
        else if (!strcmp(tok, "timer"))                 henge_trace |= HENGE_TRACE_TIMER;
        else if (!strcmp(tok, "env"))                   henge_trace |= HENGE_TRACE_ENV;
        else if (!strcmp(tok, "dma"))                   henge_trace |= HENGE_TRACE_DMA;
        else if (!strcmp(tok, "mmio"))                  henge_trace |= HENGE_TRACE_MMIO;
        else warn_report("henge: unknown trace channel '%s'", tok);
    }
    g_free(copy);
}

struct HengeAccelState {
    AccelState parent_obj;

    HvMachine *m;   /* owned by the engine's allocator, opaque here */
    MemoryListener listener;

    /* Config knobs (QOM properties on the -accel object). */
    uint64_t jit_mb;
    int      stats;      /* -accel henge,stats=<seconds between dumps> */
    char     *trace;     /* -accel henge,trace=ram,sysreg,... */
    int      nregions;   /* mirror count, for HENGE_DEBUG_RAM */

    /*
     * MemoryRegion -> GPA base, recorded at mirror time.
     *
     * Needed because a host pointer cannot be turned into a GPA from the
     * RAMBlock alone.  Measured with the memfd backend (-machine
     * memory-backend=mem):
     *
     *     DMAhost mr=mem addr1=0x7efcd298 rb->offset=0x0 rb_off=0x7efcd298
     *
     * while the region's actual GPA is 0x40000000.  The memory backend creates
     * its own RAMBlock at offset 0 and the machine RAM then aliases it into the
     * address space, so neither rb->offset nor rb->offset+rb_off is the GPA.
     *
     * What IS exact is the pair QEMU hands to address_space_unmap(): the
     * MemoryRegion the pointer belongs to, and the offset inside it.  The GPA
     * base of that same MemoryRegion is what the MemoryListener reported when
     * the region was mirrored, so record it there and look it up by identity.
     */
    struct {
        MemoryRegion *mr;
        uint64_t gpa;
        uint64_t size;
    } ram_map[16];
    int nram_map;
    bool     started;    /* setup_post has run: the RAM table is the authority now */

    /*
     * romd windows that have entered their device's command mode at least once,
     * and are therefore never mirrored again.
     *
     * Why this is the right discriminator, and why nothing else is available:
     *
     * A QEMU pflash bank is a rom_device whose reads may be direct (romd) or
     * routed to the model.  Which of the two is in force is decided per access
     * by romd_mode, and pflash_write() clears it on the first write of every
     * command sequence.  WindowsiOS and WindowsPixel do not have this problem
     * because they create the device themselves and pass `readonly` explicitly
     * (devices/pflash.c: readonly -> hv_machine_add_ram, else
     * hv_machine_add_mmio).  Here both banks report is_rom=0/is_romd=1 and
     * -drive readonly=on only touches the block layer, so no static test in
     * common code can tell the code bank from the variable store.
     *
     * What separates them is behaviour, and it is visible: the code bank never
     * enters command mode, so its romd_mode never changes, so the flatview
     * never changes, so region_del never fires for it.  The variable store
     * fires twice per CFI command write.  A romd region that reaches
     * region_del is a region the guest reads as a device, and mirroring it is
     * exactly what produced 0xFFFFFFFF where a status register belonged.
     */
    struct { hwaddr pa; uint64_t size; } nomirror[8];
    int      nnomirror;
};

static HengeAccelState *henge_state;


HvMachine *henge_accel_machine(void)
{
    return henge_state ? henge_state->m : NULL;
}

/*
 * Tell the engine that a device wrote guest RAM through a host pointer.
 *
 * The caller has already resolved the pointer with qemu_ram_block_from_host(),
 * QEMU's authoritative reverse map (the same call virtio-balloon and
 * virtio-gpu us).  That is what makes this correct for anonymous RAM,
 * memfd/file-backed RAM and aliased regions alike.
 *
 * The previous implementation scanned the engine's own GPA->host table by
 * address range.  That only ever worked by luck on anonymous RAM: a
 * memfd-backed block is mapped at a host address outside the window recorded at
 * mirror time, so the scan missed silently, the engine kept a stale
 * translation, and UEFI read a stale FAT directory -- which surfaced as
 * "Image type X64 can't be loaded on AARCH64 UEFI system".
 *
 * RAMBlock->offset is the block's base in the RAM address space, which for
 * system memory is the guest physical address, so the GPA is the sum.
 */
uint64_t hv_engine_dma_written_mr(MemoryRegion *mr, uint64_t off, uint64_t len)
{
    HengeAccelState *h = henge_state;
    uint64_t pa, n;
    int i;

    if (!h || !h->m || !mr || !len) {
        return 0;
    }
    for (i = 0; i < h->nram_map; i++) {
        if (h->ram_map[i].mr != mr) {
            continue;
        }
        if (off >= h->ram_map[i].size) {
            return 0;
        }
        pa = h->ram_map[i].gpa + off;
        n = h->ram_map[i].size - off;
        if (n > len) {
            n = len;
        }
        hv_engine_dma_written(h->m, pa, n);
        if (getenv("HV_DMA_DEBUG")) {
            fprintf(stderr, "DMAhit mr=%s off=0x%" PRIx64 " -> gpa=0x%" PRIx64
                    " n=0x%" PRIx64 " (base=0x%" PRIx64 ")\n",
                    mr->name, off, pa, n, h->ram_map[i].gpa);
        }
        return n;
    }
    if (getenv("HV_DMA_DEBUG")) {
        fprintf(stderr, "DMAmiss mr=%s off=0x%" PRIx64 " (nram_map=%d)\n",
                mr->name, off, h->nram_map);
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* MMIO: hand everything the engine cannot resolve to QEMU            */
/* ------------------------------------------------------------------ */

/*
 * Called from a vCPU thread with the BQL *dropped* -- the engine services
 * device accesses inline, inside hv_run(), and hv_run is called after
 * bql_unlock() (MTTCG's lock order, see henge-accel-ops.c).  So this takes the
 * BQL itself rather than assuming it.
 *
 * This is the KVM arrangement: guest execution without the BQL, device
 * emulation with it.  It is safe for the same reason: everything the engine
 * touches while executing is either guest RAM (whose host pointer we mirrored)
 * or its own state, and every QEMU-side change of the memory layout takes the
 * BQL first and notifies our MemoryListener, which drops the affected
 * translations.
 */
/*
 * Which MMIO window the trace covers.
 *
 * Unfiltered, the serial console fills the budget before the guest reaches
 * anything interesting: edk2 emits a byte at a time, so a few hundred lines are
 * one banner.  HV_MMIO_PA/HV_MMIO_LEN narrow it to one device, and the function
 * becomes a scalpel instead of a firehose.  Parsed once; the trace path is
 * cold by definition.
 */
static bool henge_mmio_traced(uint64_t pa, uint32_t len)
{
    static uint64_t base, end;
    static bool init;

    if (!init) {
        const char *s = getenv("HV_MMIO_PA");
        init = true;
        if (s) {
            base = g_ascii_strtoull(s, NULL, 0);
            s = getenv("HV_MMIO_LEN");
            end = base + (s ? g_ascii_strtoull(s, NULL, 0) : 0x10000000ull);
        }
    }
    if (!base) {
        return true;
    }
    return pa < end && pa + len > base;
}

static int henge_mmio_forward(void *opaque, uint64_t pa, void *buf,
                              uint32_t len, int is_write)
{
    MemTxResult r;
    bool trace;
    uint64_t tpc;

    /*
     * Enforced, not just documented.  This runs on a vCPU thread inside
     * hv_run(), which the MTTCG lock order calls with the BQL released.  If it
     * were ever called with the BQL held, bql_lock() would deadlock the whole
     * VM -- and it would do so only under load, which is the failure mode that
     * costs days.  bql_locked() is per-thread, so this asks the right question.
     */
    assert(!bql_locked());

    /*
     * The access as the engine saw it, with the value read back for reads.
     *
     * Two things make this line load-bearing rather than decoration:
     *
     *  - the guest PC.  QEMU's own device traces show only the value handed to
     *    the device, so a repeated access looks identical whether the guest is
     *    retrying one instruction or the engine is replaying a stale access.
     *    The PC separates those two, and they need opposite fixes.
     *  - the value, printed *after* the access.  For a read that is the only
     *    place it exists: QEMU's pflash trace shows what was written, never
     *    what the guest got back, which is exactly the half that was wrong
     *    when the UEFI variable store read 0xFFFFFFFF (erased flash content)
     *    where it expected a CFI status register.
     *
     * Scoped by HV_MMIO_PA / HV_MMIO_LEN so a window can be isolated without
     * the serial console spending the whole budget first.
     */
    trace = henge_tracing(HENGE_TRACE_MMIO) && henge_mmio_traced(pa, len);
    tpc = hv_engine_access_pc(henge_accel_machine());

    bql_lock();
    r = address_space_rw(&address_space_memory, pa, MEMTXATTRS_UNSPECIFIED,
                         buf, len, is_write);
    bql_unlock();

    if (trace) {
        uint64_t v = 0;

        if (len <= sizeof v) {
            memcpy(&v, buf, len);
        }
        fprintf(stderr,
                "henge-mmio %c pa=0x%" HWADDR_PRIx " len=%u val=0x%" PRIx64
                " pc=0x%" PRIx64 "\n",
                is_write ? 'W' : 'R', pa, len, v, tpc);
    }

    /*
     * A device write that raises an interrupt for the CPU that issued it is
     * invisible to the engine unless somebody copies the line across, and on
     * this path nobody does:
     *
     *   guest MMIO store -> here -> address_space_rw -> the GIC
     *     -> arm_cpu_set_irq(cs) -> cpu_interrupt(cs)
     *     -> generic_handle_interrupt(): cpu_set_interrupt(mask), then
     *        `if (!qemu_cpu_is_self(cpu)) qemu_cpu_kick(cpu);`
     *
     * qemu_cpu_kick() is the only thing that reaches henge_kick_vcpu_thread(),
     * which is the only place that copies cs->interrupt_request into the
     * engine's line.  For a self-targeted interrupt it is skipped by design --
     * TCG has no need for it, because cpu_exec() re-reads interrupt_request at
     * every translation block.
     *
     * The concrete case is a GICv2 SGI, which the guest sends by writing
     * GICD_SGIR: a CPU that IPIs itself (reschedule, call-function) gets
     * CPU_INTERRUPT_HARD set in QEMU and nothing at all in the engine, so it
     * keeps executing straight past the point where it should have taken the
     * interrupt.  Measured: `-M virt` (GICv2) + `-smp 2` + default nohz stalls
     * in _nohz_idle_balance at 26 s and 89 s, while the same command under TCG
     * boots clean in 77 s -- so it is this accelerator, not the GICv2 model.
     *
     * GICv3 has no such hole: ICC_SGI1R_EL1 is a system register, and the seam
     * path re-syncs after servicing one.  That is why switching to
     * gic-version=3 made the stall disappear without anyone fixing anything.
     *
     * current_cpu is this thread's vCPU (QEMU keeps it in TLS), which is
     * exactly the CPU whose line went stale.
     */
    /*
     * 统计口径：virtio-net 的 doorbell 写、ISR 读都是 MMIO，每一次都会走到
     * 这里。HV_SYNC_IRQ_COUNT=1 时按 10 万次一档打到 stderr，用来判断
     * "每次 MMIO 都同步 IRQ" 到底是几千次还是几十万次——这个数量级决定
     * 该优化 sync_irq 还是去看网络栈。
     */
    /*
     * No interrupt sync after an MMIO access any more.
     *
     * This hook existed because an MMIO callback runs inside the engine on the
     * vCPU thread, so a device touched here could raise an interrupt the engine
     * would not see until it left.  Under read-through there is nothing to
     * publish: the device updated QEMU's state, and QEMU's state is what the
     * engine reads at its next block boundary -- same thread, same instant.
     * The old counter ("how often would we be syncing?") is gone with it.
     */
    return r == MEMTX_OK ? 0 : -1;
}

/* ------------------------------------------------------------------ */
/* Memory: let QEMU own RAM, mirror PA->host into the engine           */
/* ------------------------------------------------------------------ */

static void henge_mirror(HengeAccelState *h, MemoryRegion *mr, hwaddr pa,
                         uint64_t size, hwaddr offset_in_region)
{
    void *host;
    bool is_ram = memory_region_is_ram(mr);
    bool is_rom = memory_region_is_rom(mr);
    /*
     * romd ("ROM device, direct reads") is the third kind and the one that
     * gates UEFI.
     *
     * is_ram() is false for it and is_rom() is `mr->ram && mr->readonly`, which
     * is also false because romd mode clears ->readonly.  So the old
     * `is_ram || is_rom` test skipped virt.flash0 entirely -- the region edk2
     * resets into.  Measured with trace=ram:
     *
     *     henge: region virt.flash0  pa=0x0  size=0x4000000  ram=0 rom=0 romd=1
     *
     * and the guest then died at pc=0 with HV_EXIT_FAULT_LOOP on the first
     * fetch, while TCG printed the edk2 banner and reached BDS.
     *
     * romd semantics are "reads are direct, writes go to the device": that is
     * precisely why it is mirrored read-only here, with hv_phys_write() passing
     * writes through to the MMIO catch-all instead of dropping them (see the
     * matching change in the engine's machine.c).  Mapping it read-write would
     * let the guest scribble straight into the backing file and bypass the CFI
     * command state machine.
     */
    bool is_romd = memory_region_is_romd(mr);

    if (henge_tracing(HENGE_TRACE_RAM)) {
        fprintf(stderr, "henge: region %-24s pa=0x%" HWADDR_PRIx
                " size=0x%" PRIx64 " ram=%d rom=%d romd=%d\n",
                memory_region_name(mr), pa, size, is_ram, is_rom, is_romd);
    }

    /*
     * RAM *and* ROM, and romd.
     *
     * MMIO must NOT be registered as engine RAM: the engine has to trap those
     * addresses so it can forward them to QEMU (address_space_rw), which is what
     * keeps QEMU's device models authoritative.
     *
     * ROM is not an afterthought.  -kernel loads the guest image with
     * rom_add_blob(), which installs a ROM MemoryRegion *over* the RAM block;
     * memory_region_is_ram() is false for it.  With a RAM-only filter the
     * engine never learned about 0x40080000, the first guest fetch went
     * nowhere, and the run died as "exception vector faulted" at the entry PC.
     * pflash (UEFI) repeats exactly that failure through the romd door.
     */
    if (!size || (!is_ram && !is_rom && !is_romd)) {
        return;
    }

    /*
     * A romd window that has been seen in command mode is a device the guest
     * reads through the CFI state machine, not memory.  Leave it to the MMIO
     * catch-all so QEMU's romd_mode decides what a read returns -- the same
     * path TCG takes, and the one that makes the status register readable.
     * See the comment on nomirror[] for why "has it been del'd" is the test.
     */
    if (is_romd) {
        for (int i = 0; i < h->nnomirror; i++) {
            if (h->nomirror[i].pa == pa) {
                hv_machine_del_ram(h->m, pa, size);   /* in case an earlier add landed */
                if (henge_tracing(HENGE_TRACE_RAM)) {
                    fprintf(stderr, "henge: skip   %-20s pa=0x%" HWADDR_PRIx
                            " size=0x%" PRIx64 " (romd in command mode)\n",
                            memory_region_name(mr), pa, size);
                }
                return;
            }
        }
    }

    /*
     * A region can be re-added after a remove (memory hotplug, or a board that
     * rebuilds its memory tree); drop the stale entry first so the engine does
     * not end up with two windows over the same guest PA.
     */
    hv_machine_del_ram(h->m, pa, size);

    host = memory_region_get_ram_ptr(mr) + offset_in_region;

    /*
     * readonly = 0 for RAM and the kernel ROM: the region a kernel is loaded
     * into has to be writable (Linux relocates and patches itself in place),
     * and QEMU's ROM write protection is a device-model behaviour this
     * accelerator cannot honour without trapping every store to it.
     *
     * The romd case (virt.flash0/1 under -drive if=pflash) is NOT handled here
     * yet: mapping it, in either write mode, breaks the -kernel baseline
     * (measured: mirrored 1 region -> boots; 3 regions -> no output at all,
     * because the two 64 MB windows land below the RAM base).  UEFI therefore
     * remains unported; see the note in VENDORED-FROM.
     */
    if (hv_machine_add_ram(h->m, pa, size, host, is_romd ? 1 : 0) != 0) {
        error_report("henge: failed to mirror %s at 0x%" HWADDR_PRIx
                     " (%" PRIu64 " bytes)", memory_region_name(mr), pa, size);
        return;
    }

    /* Remember where this MemoryRegion lives, for the DMA host->GPA lookup. */
    {
        int i;

        for (i = 0; i < h->nram_map; i++) {
            if (h->ram_map[i].mr == mr) {
                break;
            }
        }
        if (i == h->nram_map && h->nram_map < (int)ARRAY_SIZE(h->ram_map)) {
            h->nram_map++;
        }
        if (i < (int)ARRAY_SIZE(h->ram_map)) {
            h->ram_map[i].mr   = mr;
            h->ram_map[i].gpa  = pa;
            h->ram_map[i].size = size;
        }
    }
    h->nregions++;
}

static void henge_region_add(MemoryListener *listener, MemoryRegionSection *s)
{
    henge_mirror(container_of(listener, HengeAccelState, listener), s->mr,
                 s->offset_within_address_space, int128_get64(s->size),
                 s->offset_within_region);
}

static void henge_region_del(MemoryListener *listener, MemoryRegionSection *s)
{
    HengeAccelState *h = container_of(listener, HengeAccelState, listener);
    int rc;

    if (henge_tracing(HENGE_TRACE_RAM)) {
        fprintf(stderr, "henge: del    %-20s pa=0x%" HWADDR_PRIx " size=0x%" PRIx64
                " romd=%d\n", memory_region_name(s->mr),
                s->offset_within_address_space, int128_get64(s->size),
                memory_region_is_romd(s->mr));
    }

    /*
     * Evidence, gathered on the way out: this romd window just proved it enters
     * its device's command mode, because that is the only thing that changes
     * romd_mode and therefore the only thing that makes the flatview change.
     * Once is enough -- pflash calls set_romd() twice per command sequence
     * forever after -- so it goes on the never-mirror list and every later
     * add of it is refused.  The code bank never arrives here at all, which is
     * what keeps it mirrored and its fetch path at native speed.
     */
    if (h->started && memory_region_is_romd(s->mr) && h->nnomirror < 8) {
        hwaddr npa = s->offset_within_address_space;
        int known = 0;

        for (int i = 0; i < h->nnomirror; i++) {
            if (h->nomirror[i].pa == npa) {
                known = 1;
                break;
            }
        }
        if (!known) {
            h->nomirror[h->nnomirror].pa = npa;
            h->nomirror[h->nnomirror].size = int128_get64(s->size);
            h->nnomirror++;
            if (henge_tracing(HENGE_TRACE_RAM)) {
                fprintf(stderr, "henge: romd   %-20s pa=0x%" HWADDR_PRIx
                        " entered command mode: stop mirroring it\n",
                        memory_region_name(s->mr), npa);
            }
        }
    }

    /*
     * Retire the window, then ask for the invalidation -- do not perform it.
     *
     * This runs on QEMU's main thread with the BQL held, while vCPUs are
     * executing.  Invalidating from here means hv_invalidate_code() walking the
     * chained-exit list and hv_tlb_flush() memsetting a TLB that a vCPU is
     * reading at that instant.  Measured on the engine's exact entry layout:
     * a reader that saw a valid tag and then loaded the addend across a
     * concurrent flush got 0x8080808080808080 as an addend 619,156 times in
     * five seconds -- every one of those is a wild host address.  Counted in
     * the field on edk2 -smp 2: 168 of 341 del_ram calls landed on a CPU whose
     * `active` was set, i.e. mid-dispatcher.
     *
     * hv_engine_request_flush() sets flush_pending, which every vCPU checks at
     * the top of its dispatcher loop; the first one to see it runs
     * stop_the_world() and flushes with everybody parked -- the engine's own
     * documented invariant ("the one moment the TLB layout can change").  It
     * cannot wait for that here: a vCPU inside henge_mmio_forward() is blocked
     * on the BQL this thread holds.
     */
    rc = hv_machine_del_ram_flags(h->m, s->offset_within_address_space,
                                  int128_get64(s->size), 1);
    /*
     * Flush only if the engine actually held this window.
     *
     * This is what makes the never-mirror list pay off.  A romd window that is
     * no longer mirrored produces region_del on every CFI command write all
     * the same -- the flatview still changes -- but there is nothing in the
     * engine to invalidate, because its reads and writes already go to the
     * device through the MMIO catch-all.  Requesting a flush for it cost a
     * stop-the-world per sequence: measured 379 requests / 240 flushes at
     * 735-847 us each, all of it for a window the engine had stopped caching.
     *
     * rc == -1 means "no window with this base PA", which is both the case for
     * a never-mirrored region and the case worth reporting (see below).
     */
    if (rc == 0) {
        hv_engine_request_flush(h->m);
    }
    /*
     * A -1 here is worth seeing.  hv_machine_del_ram() matches on the base PA,
     * so a section that is reported with a different base than the one that was
     * added silently survives -- and a romd window that survives a romd-off
     * transition is a window that answers reads from stale storage.  That is
     * the exact shape of the UEFI variable-store failure, so it must not be
     * swallowed again.
     */
    if (henge_tracing(HENGE_TRACE_RAM) && rc != 0) {
        fprintf(stderr, "henge: del    %-20s pa=0x%" HWADDR_PRIx
                " NOT MIRRORED\n", memory_region_name(s->mr),
                s->offset_within_address_space);
    }
}

static const MemoryListener henge_memory_listener = {
    .name = "henge",
    .region_add = henge_region_add,
    .region_del = henge_region_del,
};

/* flatview_for_each_range() walks the *finished* address space, which is the
 * only place the whole RAM map can be read in one go. */
static bool henge_flatview_cb(Int128 start, Int128 size,
                              const MemoryRegion *mr,
                              hwaddr offset_in_region, void *opaque)
{
    henge_mirror(opaque, (MemoryRegion *)mr, int128_get64(start),
                 int128_get64(size), offset_in_region);
    return false;   /* never stop early */
}

/* ------------------------------------------------------------------ */
/* The time base                                                       */
/* ------------------------------------------------------------------ */

/*
 * Calibrate the engine's counter against QEMU's virtual clock.
 *
 * QEMU's virtual clock is the authority for the guest's CNTPCT: it is what the
 * gtimer compares CVAL against when it decides to raise an interrupt.  The
 * engine has its own counter, so the two agree only if we say when they
 * started: epoch = engine ticks - host ticks.  After that every guest counter
 * read is one subtraction.
 *
 * Why this has to run again on every resume: QEMU_CLOCK_VIRTUAL stops while
 * the VM is stopped, and the host's counter does not.  A VM paused for ten
 * seconds comes back with engine time ten seconds ahead, and the guest sees
 * ten seconds vanish into a timer that should still have been pending.  That
 * is a clock jump, not a slow clock -- the kind of thing that shows up as a
 * mysterious timeout rather than as a wrong number.
 */
void henge_timer_calibrate(HvMachine *m)
{
    uint64_t freq, engine_ticks, host_ticks;

    if (!m) {
        return;
    }
    freq = hv_engine_timer_freq(m);
    if (!freq) {
        return;
    }
    engine_ticks = hv_engine_timer_ticks(m);
    host_ticks = muldiv64(qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL), freq,
                          NANOSECONDS_PER_SECOND);
    hv_engine_set_timer_epoch(m, engine_ticks - host_ticks);
}

void henge_timer_setup(HvMachine *m, uint64_t freq)
{
    if (!m || !freq) {
        return;
    }
    hv_engine_set_timer_freq(m, freq);
    henge_timer_calibrate(m);
    if (henge_tracing(HENGE_TRACE_TIMER)) {
        fprintf(stderr, "henge: timer CNTFRQ=%" PRIu64 " Hz (host clock), "
                "epoch=%" PRId64 "\n", freq,
                (int64_t)(hv_engine_timer_ticks(m) -
                          muldiv64(qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL), freq,
                                   NANOSECONDS_PER_SECOND)));
    }
}

/*
 * Resume (and reset) re-calibrate.  running == 1 is the transition that
 * matters: the virtual clock has been frozen for however long the VM was
 * stopped, and the host counter has not.
 */
static void henge_vm_state(void *opaque, bool running, RunState state)
{
    if (running) {
        henge_timer_calibrate(opaque);
    }
}

/* ------------------------------------------------------------------ */
/* Machine lifecycle: reset, and what must be refused                  */
/* ------------------------------------------------------------------ */

/*
 * system_reset, and why setup_post's one-shot mirror is not enough.
 *
 * On a reset QEMU tears the ROM contents down and reloads them, builds a new
 * flatview (possibly with different regions) and resets every CPU.  The engine
 * holds four things that a reboot invalidates and that nothing else drops:
 * translated blocks, the per-CPU software TLB, the per-page code/whint/gen
 * bookkeeping, and the indirect-branch caches.  A block is keyed by
 * {va, pa, flags, gen} -- a reboot changes none of those and changes every byte
 * behind them, so the second boot would run the *first* image's translations.
 *
 * A vCPU-level reset cannot cover this (it knows one CPU) and code
 * invalidation cannot either (it knows one page).  This callback is the only
 * place with the whole picture, and it runs after QEMU has reset the device
 * tree, so the flatview walk sees the new memory map.
 *
 * Called with the BQL held and every vCPU stopped (qemu_devices_reset runs
 * after vm_stop), which is what makes wiping shared engine state safe.
 */
static void henge_reset(void *opaque)
{
    HengeAccelState *h = opaque;

    if (!h || !h->m) {
        return;
    }
    /*
     * QEMU runs its reset handlers once during startup too, before the machine
     * has finished building.  Acting then would mirror a half-built flatview
     * and then mirror it again in setup_post, leaving a dead (size 0) entry
     * behind for every region -- harmless to lookups, but it made the mirror
     * count read 2 for 1 region, which is exactly the kind of thing that makes
     * a later memory bug take a day.  Before setup_post there is nothing to
     * invalidate anyway.
     */
    if (!h->started) {
        return;
    }

    /*
     * Only machine-wide state here.  The per-vCPU half of a reset is not this
     * callback's business and cannot be: re-syncing a vCPU means reading
     * CPUARMState, which lives in target/arm/cpu.h, and this file is common
     * code -- it may not include a per-target header.  That half already has a
     * home: henge_cpu_synchronize_post_reset() in henge-accel-ops.c, which QEMU
     * calls on every CPU around the same reset.  The two do not race: this one
     * touches blocks, TLB and the RAM table, that one touches registers, and
     * neither reads what the other writes.
     */
    hv_engine_machine_reset(h->m);

    /*
     * Re-mirror from scratch: a reset can add, remove or move regions, and the
     * engine's table holds host pointers into MemoryRegions that may have been
     * recreated.  Clearing and walking again is cheaper to reason about than
     * diffing a table against a flatview.
     */
    hv_engine_ram_clear(h->m);
    /* The rebooted guest starts its counters where QEMU's clock is now. */
    henge_timer_calibrate(h->m);
    h->nregions = 0;
    flatview_for_each_range(address_space_to_flatview(&address_space_memory),
                            henge_flatview_cb, h);

    if (henge_tracing(HENGE_TRACE_RAM)) {
        fprintf(stderr, "henge: reset, re-mirrored %d regions\n", h->nregions);
    }
}

/*
 * Migration and snapshots: refuse, loudly, at setup time.
 *
 * Every piece of engine state that makes the guest fast -- the JIT region and
 * its blocks, the four software TLB tables with their host addends, whint, the
 * indirect-branch caches, the whole HvCpu -- is a host pointer graph.  None of
 * it is serialisable, and none of it is in QEMU's migration stream.  QEMU has no
 * way to know that: hv_engine_save_state() puts the architectural registers in
 * env, which is what the stream carries, so a migrate would succeed and produce
 * a destination that starts executing with an empty JIT over a guest that was
 * mid-syscall.  The failure mode is a corrupt snapshot that looks fine.
 *
 * MIG_EVENT_SETUP is the one hook that can still say no (its handler may return
 * an error; the others may not), and saying no there is better than a doc note.
 */
static int henge_migration_notify(NotifierWithReturn *n, MigrationEvent *e,
                                  Error **errp)
{
    if (e->type == MIG_EVENT_SETUP) {
        error_setg(errp, "henge: migration is not supported (the JIT cache, "
                   "software TLB and per-CPU state are host pointers and are "
                   "not in the migration stream)");
        return -1;
    }
    return 0;
}

static NotifierWithReturn henge_migration_notifier;

/* henge-cpu.c: the engine's tick source, in 24 MHz host ticks, or 0. */
uint64_t henge_tick_delta24(void *opaque, uint32_t index);

/* ------------------------------------------------------------------ */
/* AccelClass                                                          */
/* ------------------------------------------------------------------ */

static int henge_init_machine(AccelState *as, MachineState *ms)
{
    HengeAccelState *h = HENGE_ACCEL(as);

    henge_state = h;
    henge_trace_parse(h->trace);


    /*
     * Create the engine but do NOT create RAM: QEMU owns it and will tell us
     * about it through the listener below.  JIT memory is ours.
     *
     * The engine owns HvMachine (its sizeof is private to the engine), so it
     * allocates and returns the pointer.
     */
    h->m = hv_engine_machine_new(h->jit_mb << 20);
    if (!h->m) {
        error_report("henge: engine machine allocation failed (jit-mb=%" PRIu64 ")",
                     h->jit_mb);
        return -ENOMEM;
    }

    /* The catch-all device window.  Installed before any vCPU exists and
     * before devices are realized, so it is in place for the first access. */
    hv_engine_set_mmio_forward(h->m, henge_mmio_forward, h);

    /*
     * The tick source.  Without it m->tick stays NULL and wait_for_interrupt()
     * can only give up and unwind the run -- measured at 512 B-path returns per
     * vCPU on a two-vCPU boot -- so the engine can never sleep to a deadline and
     * has to be kicked once per timer event.
     *
     * Registered here rather than at first vCPU start because the engine reads
     * m->tick from the WFI path of any CPU, and a half-started machine must not
     * see one installed for some CPUs and not others.  The callback resolves the
     * vCPU by index through qemu_get_cpu(), so it is valid as soon as the
     * CPUStates exist, which is before this point.
     */
    hv_engine_set_tick(h->m, henge_tick_delta24, h);

    /*
     * stats_interval: counting always on, printing off unless asked.
     *
     * This one field does two different jobs in the engine, and the port needs
     * both of them pointed in different directions:
     *
     *   it gates *counting* -- mmu.c and translate.c wrap a whole class of
     *   increments in `if (m->stats_interval)`: TLB range flushes, kernel
     *   ranges, code-page protection kinds, the remote-drop race counters,
     *   chained-early.  Zero here does not mean "nothing happened", it means
     *   "nothing is being counted", and since the port never assigned the
     *   field, every one of those numbers read as 0 for the entire life of
     *   this accelerator.
     *
     *   it gates *printing* -- print_stats() returns early unless
     *   `now - last_t >= stats_interval * 24MHz`.
     *
     * So the default is one hour: far longer than any boot, which keeps the
     * counters live and the log clean.  -accel henge,stats=<seconds> or
     * HV_STATS=<seconds> overrides it when a stats stream is actually wanted.
     *
     * Cost of having it non-zero: translate.c takes two mach_absolute_time()
     * reads per translation to account for translate_ticks.  That is the
     * translation path, not the execution path, and it is the same price the
     * standalone runner has always paid.  Set before any vCPU exists so no
     * interval starts half-counted.
     */
    {
        const char *st = getenv("HV_STATS");
        int secs = h->stats > 0 ? h->stats : (st ? atoi(st) : 3600);
        hv_engine_set_stats_interval(h->m, secs);
    }

    /*
     * The copy is the fix, not boilerplate.
     *
     * MemoryListener callbacks are dispatched with `if (_listener->_callback)`,
     * so a listener whose hooks were never installed is skipped in silence:
     * register() succeeds, the struct sits in the address space's queue, and
     * nothing is ever called.  That is what this did for its whole life --
     * henge_memory_listener was defined and never assigned, so region_add and
     * region_del were both NULL.
     *
     * It stayed invisible because setup_post walks the finished flatview
     * directly, which covers the initial map completely.  The gap only opens
     * later: pflash calls memory_region_rom_device_set_romd() on every
     * command-sequence write, and a flatview rebuild is the *only* signal that
     * the window must change.  With no callback the mirror survived the
     * romd-off transition, so the guest kept reading the variable store out of
     * RAM instead of the CFI state machine, read 0xFFFFFFFF (erased flash) as
     * the status register, and looped forever unlocking a block it could never
     * unlock.  UEFI then had no Variable Arch Protocol to install and DxeCore
     * asserted.
     */
    h->listener = henge_memory_listener;
    memory_listener_register(&h->listener, &address_space_memory);

    /*
     * Both seam flags on: QEMU owns the system registers the engine does not
     * model, and it owns PSCI too.
     *
     * PSCI must be QEMU's once -smp > 1: the engine's own conduit resets the
     * target HvCpu directly, behind the back of the CPUState and the parked
     * vCPU thread that QEMU owns, and it matches CPUs by its own MPIDR layout
     * rather than the one the device tree describes.  With both fixed (MPIDR
     * now forwarded, PSCI now dispatched into psci.c) a secondary can actually
     * be brought up.  See henge_service_psci().
     */
    hv_engine_set_external(h->m, 1, 1);

    qemu_register_reset(henge_reset, h);
    qemu_add_vm_change_state_handler(henge_vm_state, h->m);

    migration_add_notifier(&henge_migration_notifier, henge_migration_notify);

    return 0;
}

static void henge_setup_post(AccelState *as)
{
    HengeAccelState *h = HENGE_ACCEL(as);
    FlatView *fv;

    /*
     * Walk the finished flatview once, whatever the listener did.
     *
     * The listener's region_add is the normal path, but it is not a substitute
     * for this: init_machine runs before the board has created its regions, so
     * at registration time there is almost nothing to add, and a listener that
     * is registered on an AddressSpace that has not been initialised yet can
     * lose its queue entry.  Walking here means the initial map is correct
     * regardless of either.
     *
     * It is idempotent: henge_mirror() drops any window already covering the
     * same base before adding, so the overlap between the two paths costs one
     * add/del pair per region and nothing else.
     *
     * The listener is still what handles everything *after* this point --
     * hotplug, memory-tree rebuilds, and the romd toggles that pflash drives.
     */
    fv = address_space_to_flatview(&address_space_memory);
    flatview_for_each_range(fv, henge_flatview_cb, h);
    h->started = true;
    if (henge_tracing(HENGE_TRACE_RAM)) {
        fprintf(stderr, "henge: setup_post mirrored %d regions\n", h->nregions);
    }
    /*
     * RAM is mirrored and devices are realized by now, so the engine's RAM
     * table is complete -- which is what it needs before the first
     * translation.  Nothing to publish here: the MMIO forwarder was installed
     * in init_machine.
     */
}

/* QOM: -accel henge,jit-mb=512 */
static void henge_accel_instance_init(Object *obj)
{
    HengeAccelState *h = HENGE_ACCEL(obj);

    h->jit_mb = 256;
    h->stats = 0;        /* 0: keep the default (counting on, printing off) */
    h->trace = NULL;
}

static char *henge_get_trace(Object *obj, Error **errp)
{
    HengeAccelState *h = HENGE_ACCEL(obj);

    return g_strdup(h->trace ? h->trace : "");
}

static void henge_set_trace(Object *obj, const char *value, Error **errp)
{
    HengeAccelState *h = HENGE_ACCEL(obj);

    g_free(h->trace);
    h->trace = (value && *value) ? g_strdup(value) : NULL;
}

/* QOM: -accel henge,jit-mb=512,stats=5 */
static void henge_get_stats(Object *obj, Visitor *v, const char *name,
                            void *opaque, Error **errp)
{
    int64_t value = HENGE_ACCEL(obj)->stats;

    visit_type_int(v, name, &value, errp);
}

static void henge_set_stats(Object *obj, Visitor *v, const char *name,
                            void *opaque, Error **errp)
{
    int64_t value;

    if (!visit_type_int(v, name, &value, errp)) {
        return;
    }
    HENGE_ACCEL(obj)->stats = (int)value;
}

static void henge_accel_class_init(ObjectClass *oc, const void *data)
{
    AccelClass *ac = ACCEL_CLASS(oc);

    object_class_property_add_str(oc, "trace", henge_get_trace, henge_set_trace);
    object_class_property_set_description(oc, "trace",
        "Diagnostic channels: ram,sysreg,irq,psci,timer,env,dma,all");

    /*
     * Seconds between engine stats dumps.
     *
     * Note what 0 does NOT mean: the field is not only a print interval, it is
     * also the gate on a whole class of counters (see its use in
     * henge_init_machine).  0 means "stop counting", not "be quiet" -- the
     * default of 3600 already gives quiet without losing the counters.  Lower
     * it to see a stream; there is no reason to raise it.
     */
    object_class_property_add(oc, "stats", "int", henge_get_stats,
                              henge_set_stats, NULL, NULL);
    object_class_property_set_description(oc, "stats",
        "Seconds between engine stats dumps (default 3600: counters on, quiet)");

    ac->name = "Henge";
    ac->init_machine = henge_init_machine;
    ac->setup_post = henge_setup_post;
    ac->allowed = &henge_allowed;
}

static const TypeInfo henge_accel_type = {
    .name = TYPE_HENGE_ACCEL,
    .parent = TYPE_ACCEL,
    .instance_size = sizeof(HengeAccelState),
    .instance_init = henge_accel_instance_init,
    .class_init = henge_accel_class_init,
};
module_obj(TYPE_HENGE_ACCEL);

static void henge_type_init(void)
{
    type_register_static(&henge_accel_type);
}

type_init(henge_type_init);
