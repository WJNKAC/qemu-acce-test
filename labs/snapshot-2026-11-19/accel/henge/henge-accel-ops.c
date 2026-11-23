/*
 * Henge accelerator: AccelOpsClass side (the vCPU thread)
 *
 * The lock order is copied from accel/tcg/tcg-accel-ops-mttcg.c, and that is
 * the whole point: QEMU's BQL is a global lock, but MTTCG deliberately drops
 * it around execution:
 *
 *     bql_unlock();
 *     r = tcg_cpu_exec(cpu);
 *     bql_lock();
 *
 * Our engine is itself multi-threaded (one thread per vCPU, each with its own
 * TLB), so holding the BQL while running would serialize SMP down to one core.
 * Dropping it is safe for the same reason it is safe for MTTCG: everything the
 * engine touches during execution is either guest RAM (whose host pointer we
 * mirrored) or its own state, and every QEMU-side change of memory layout takes
 * the BQL and notifies our MemoryListener, which flushes the engine's TLB.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "qemu/osdep.h"
#include "qemu/error-report.h"
#include "qapi/error.h"
#include "qemu/main-loop.h"
#include "qemu/guest-random.h"
#include "qemu/timer.h"
#include "qemu/thread.h"
#include "accel/accel-cpu-ops.h"
#include "system/cpus.h"
#include "system/runstate.h"
#include "system/memory.h"
#include "system/address-spaces.h"
#include "hw/core/cpu.h"
#include "target/arm/cpu.h"
#include "target/arm/cpu-features.h"
#include "system/henge-accel.h"
#include "system/henge-engine.h"
#include "exec/cpu-interrupt.h"

/* The engine's per-CPU array is HV_MAX_CPUS entries; mirror that bound here
 * rather than including the engine's cpu.h into a QEMU translation unit. */
#define HV_MAX_CPUS_SHIM 8

/*
 * HvCpu -> CPUState, by engine index, so the read-through hook can get from
 * what the engine hands it to the flag QEMU owns.
 *
 * Written once per vCPU before its thread starts (see henge_engine_register_cpu
 * below) and only read afterwards, so the pointer needs no lock; the
 * interrupt_request it dereferences is atomic.
 */
#define HENGE_SEAM_MAX_VCPUS 8
static CPUState *henge_seam_cs[HENGE_SEAM_MAX_VCPUS];

/*
 * The interrupt level, from the owner.  See machine.h irq_line_get for the full
 * argument; the short form is:
 *
 *   ARM clears CPU_INTERRUPT_HARD only in arm_cpu_set_irq() when the GIC drops
 *   the line -- the delivery path does not clear it.  Under TCG both run on the
 *   vCPU thread so the flag is always current.  Under henge delivery happens
 *   inside the engine, so any copied level can be stale, and a stale 1 on a
 *   level-triggered line is indistinguishable from a pending interrupt: WFI
 *   completes instantly, arm_cpu_has_work() stays true, the vCPU never parks and
 *   the guest spins in cpu_do_idle() at ~100% host CPU.
 *
 * Reading the flag here is MTTCG's own model: reader and writer are different
 * threads there too (vCPU vs iothread), and nobody claims the reader holds a
 * private copy.  qatomic_read is the same acquire load cpu_handle_interrupt()
 * performs at every TB boundary.
 */
static int henge_irq_line_get(void *ctx, unsigned cpu_index, int fiq)
{
    CPUState *cs;

    (void)ctx;
    if (cpu_index >= HENGE_SEAM_MAX_VCPUS) {
        return 0;
    }
    cs = qatomic_read(&henge_seam_cs[cpu_index]);
    if (!cs) {
        /* No QEMU CPU behind this index: nothing can be asserting. */
        return 0;
    }
    return !!(qatomic_read(&cs->interrupt_request)
              & (fiq ? CPU_INTERRUPT_FIQ : CPU_INTERRUPT_HARD));
}

static HvCpu *henge_cpu_of(CPUState *cs)
{
    return (HvCpu *)cs->opaque;
}

/* henge-cpu.c: answer an exit that is really "QEMU owns this register/call".
 * Returns true if it was serviced and the engine should simply be re-entered. */
bool henge_service_external_exit(CPUState *cs, HvCpu *cpu, int r);

/* henge-accel.c: the engine's clock, and its two interrupt input lines. */
void henge_timer_setup(HvMachine *m, uint64_t freq);
void henge_timer_calibrate(HvMachine *m);

/*
 * There is deliberately no "push the line into the engine" function here any
 * more.  It had five call sites and each was a snapshot that could go stale
 * before the engine looked.  The engine now asks QEMU directly (irq_line_get,
 * installed by henge_engine_register_cpu), which is MTTCG's own read-through
 * model: one owner, one reader, no copy in between.
 */

/*
 * Turn an engine exit into whatever QEMU expects the vCPU thread to do next.
 *
 * Read this together with the exit enum: the engine only comes back out of
 * hv_run() for things it cannot handle itself, because branches, exceptions,
 * system registers and self-modifying code are all dealt with inside the run
 * loop.  That is why there is no HV_EXIT_MMIO here -- device accesses are
 * serviced inline through henge_mmio_forward() and never unwind the loop.
 */
static void henge_dispatch_exit(CPUState *cs, int r)
{
    switch (r) {
    case HENGE_EXIT_HALT:
        /* PSCI CPU_OFF, or the guest asked to stop: idle until something
         * wakes us (an interrupt, or the monitor). */
        cs->halted = 1;
        break;

    case HENGE_EXIT_WFI:
        /*
         * WFI/WFE, and every sleep in the engine now ends here (see
         * HV_WFI_HOST in engine/core/dispatch.c).
         *
         * Setting halted is what makes the host park; leaving it set is enough,
         * because arm_cpu_has_work() is consulted right after and returns true
         * whenever a real interrupt is pending -- so a guest whose line is up
         * but whose PSTATE.I masks it is not parked, it simply runs again and
         * unmasks.  No manual CPU_INTERRUPT_HARD clearing belongs here: with
         * the line now copied from env.irq_line_state the level is truthful,
         * and clearing it would only drop a genuine interrupt.
         */
        cs->halted = 1;
        break;

    case HENGE_EXIT_NONE:
    case HENGE_EXIT_BRANCH:
    case HENGE_EXIT_SYSREG:
    case HENGE_EXIT_EXCEPTION:
    case HENGE_EXIT_FLUSH:
        /* Internal states that should have been consumed by the dispatcher
         * before returning.  Looping again is the safe response. */
        break;

    case HENGE_EXIT_UNDEF:
    case HENGE_EXIT_UNSUPPORTED:
    case HENGE_EXIT_FAULT_LOOP:
    default:
        /*
         * Not recoverable by going around again: the translator cannot encode
         * this instruction (or the guest is dead).  Spinning here would turn a
         * clear failure into a hang, which is the one outcome that costs a day
         * to diagnose.  Stop the whole VM and say where.
         */
        error_report("henge: vCPU %d stopped at pc=0x%016" PRIx64
                     ", exit reason %d (%s)", cs->cpu_index,
                     (uint64_t)ARM_CPU(cs)->env.pc, r,
                     r == HENGE_EXIT_UNDEF ? "undefined instruction" :
                     r == HENGE_EXIT_UNSUPPORTED ? "untranslatable instruction" :
                     r == HENGE_EXIT_FAULT_LOOP ? "exception vector faulted" :
                     "unknown");
        vm_stop(RUN_STATE_INTERNAL_ERROR);
        cs->halted = 1;
        break;
    }
}

static void *henge_cpu_thread_fn(void *arg)
{
    CPUState *cs = arg;
    HvCpu *cpu;
    /*
     * Per-vCPU exit tally, for one question only: is this vCPU looping
     * without making progress?
     *
     * The shape of the nohz failure -- an *idle* CPU taking more interrupts
     * than the busy one, then an RCU stall 30 s later -- has two candidate
     * mechanisms that look identical from the guest side, and the difference
     * decides where the fix goes:
     *
     *   a) the guest really is idle and the tick is still firing at HZ (the
     *      engine hands back a phantom level because a level copied at three
     *      sync points cannot track QEMU's edge-latched CPU_INTERRUPT_HARD);
     *   b) the vCPU never parks at all.  qemu_process_cpu_events() blocks on
     *      cpu_thread_is_idle(), which returns false while
     *      arm_cpu_has_work(cs) is true -- and that is true exactly while
     *      CPU_INTERRUPT_HARD is set.  henge never calls cpu_reset_interrupt(),
     *      so if the flag ever outlives the interrupt inside the engine, this
     *      thread spins: hv_run -> WFI -> halted=1 -> not idle -> hv_run...
     *
     * In (a) hv_run returns HENGE_EXIT_WFI a few hundred times a second.  In
     * (b) it returns thousands to millions of times a second, in an unbroken
     * streak, because nothing between the returns ever blocks.  So the
     * discriminator is the longest unbroken WFI streak, not the rate.
     *
     * Kept as `static` per-CPU counters rather than a struct member: HvCpu is
     * private to the engine and this TU may not see it.
     */
    static struct {
        uint64_t runs, wfi, halt, other;
        uint64_t streak, max_streak;
        int64_t  last_wfi_ns;
    } ex[HV_MAX_CPUS_SHIM];
    unsigned cix = cs->cpu_index < HV_MAX_CPUS_SHIM ? cs->cpu_index : 0;

    rcu_register_thread();

    bql_lock();
    qemu_thread_get_self(cs->thread);
    cs->thread_id = qemu_get_thread_id();
    current_cpu = cs;

    /*
     * Bridge, step 1 of 2: QEMU has already built the CPUARMState (arm_load_kernel
     * ran cpu_set_pc() on it after arm_cpu_reset_hold() zeroed env->pc), so the
     * entry point lives in ARM_CPU(cs)->env, NOT in anything the engine knows.
     * Read it here, on the vCPU thread, before the first hv_run().
     */
    cpu = henge_cpu_of(cs);
    if (hv_engine_load_state(cpu, &ARM_CPU(cs)->env) != 0) {
        /* The message is already printed; there is no sane way to run the
         * guest with the wrong privilege level. */
        cpu_thread_signal_created(cs);
        cpu_thread_signal_destroyed(cs);
        bql_unlock();
        rcu_unregister_thread();
        return NULL;
    }

    /*
     * CNTFRQ comes from the CPU object QEMU built, not from any constant in
     * this accelerator: it is the frequency the host's gtimer divides its
     * virtual clock by, so it is also the frequency the guest's deadlines are
     * expressed in.  Read it once, after the CPU is realized.
     */
    henge_timer_setup(henge_accel_machine(), ARM_CPU(cs)->gt_cntfrq_hz);

    cpu_thread_signal_created(cs);
    qemu_guest_random_seed_thread_part2(cs->random_seed);

    /*
     * The parking of a halted vCPU happens in qemu_process_cpu_events(), not
     * here, and that is worth stating because it is not obvious from reading
     * this loop: cpu_can_run() only looks at ->stop and ->stopped, never at
     * ->halted.  What keeps a -smp 4 guest's three idle secondaries out of
     * hv_run() is cpu_thread_is_idle() (system/cpus.c), which returns false
     * when ->halted is clear and otherwise calls our
     * henge_vcpu_thread_is_idle(); the thread then blocks on cpu->halt_cond
     * with the BQL released.  It is woken by kick_vcpu_thread -> hv_cpu_wake.
     * If henge_vcpu_thread_is_idle() ever reported "not idle" for a halted
     * CPU, four threads would enter the engine with a stale PC.
     */
    do {
        /*
         * No env re-sync here, deliberately.  There is no hook that fires after
         * QEMU rewrites a parked vCPU's env: cpu_synchronize_post_reset() is
         * called explicitly and only by s390x, so ARM's reset path never
         * reaches an accelerator through it (checked: the only callers are
         * target/s390x/sigp.c and the nvmm ops table).  The one place that does
         * rewrite env for a parked CPU -- PSCI CPU_ON -- is handled where it
         * happens instead; see henge_service_psci().
         */
        qemu_process_cpu_events(cs);

        if (cpu_can_run(cs)) {
            int r;

            cs->halted = 0;
            /*
             * The counterpart to henge_kick_vcpu_thread()'s request_stop():
             * a stop the host pulled left the engine's halted set, and
             * run_loop() returns HV_EXIT_HALT immediately while it is.  Clearing
             * it here -- only on the path that has already decided this vCPU may
             * run -- keeps a resumed vCPU from spinning on HALT without ever
             * executing an instruction.
             */
            hv_engine_cpu_clear_stop(cpu);

            /*
             * No line copy here any more.  The engine reads the level from
             * this side (henge_engine_register_cpu -> irq_line_get), so the
             * first block after re-entry asks QEMU directly and cannot miss a
             * line raised between the kick and this point.  Copying was the
             * bug: it fixed the level as of *here*, and the level that
             * mattered was the one at the block boundary the engine resumed at.
             */

            /* ---- the MTTCG lock order ---- */
            bql_unlock();
            /*
             * Seam exits (an unmodelled system register, later PSCI) are not
             * reasons to leave the vCPU thread: they are one instruction
             * handed to QEMU.  Service each with the BQL held -- a cpreg's
             * read/writefn can touch device state -- and go straight back into
             * the engine.  The BQL is dropped again for each re-entry so the
             * guest keeps running without it.
             */
            for (;;) {
                r = hv_run(cpu);
                ex[cix].runs++;

                if (r == HENGE_EXIT_WFI) {
                    int64_t now_ns = qemu_clock_get_ns(QEMU_CLOCK_REALTIME);
                    int64_t gap = now_ns - ex[cix].last_wfi_ns;

                    ex[cix].wfi++;
                    ex[cix].last_wfi_ns = now_ns;
                    /*
                     * Count the streak only while the returns are *tight*.
                     * A correctly parked idle vCPU also returns WFI ~250 times
                     * a second, but each return is separated by the time it
                     * actually spent blocked on halt_cond, so the gap is
                     * milliseconds.  A vCPU that never parks returns WFI back
                     * to back and the gap collapses to microseconds.  50 us is
                     * two orders of magnitude away from both.
                     */
                    ex[cix].streak = (gap >= 0 && gap < 50000)
                                     ? ex[cix].streak + 1 : 1;
                    if (ex[cix].streak > ex[cix].max_streak) {
                        ex[cix].max_streak = ex[cix].streak;
                        if (henge_tracing(HENGE_TRACE_IRQ) &&
                            ex[cix].max_streak >= 1000) {
                            fprintf(stderr, "henge: cpu%u tight WFI streak = "
                                    "%" PRIu64 " (gap=%" PRId64 "us, runs=%"
                                    PRIu64 ", hard=%d, halted=%d, req=0x%x)\n",
                                    cix, ex[cix].max_streak, gap / 1000,
                                    ex[cix].runs,
                                    !!(cs->interrupt_request
                                       & CPU_INTERRUPT_HARD),
                                    cs->halted, cs->interrupt_request);
                        }
                    }
                } else {
                    ex[cix].streak = 0;
                    ex[cix].last_wfi_ns = 0;
                    if (r == HENGE_EXIT_HALT) {
                        ex[cix].halt++;
                    } else {
                        ex[cix].other++;
                    }
                }
                if (henge_tracing(HENGE_TRACE_IRQ)) {
                    fprintf(stderr, "henge: hv_run returned %d\n", r);
                }
                if (r != HENGE_EXIT_SYSREG_EXT && r != HENGE_EXIT_PSCI_EXT) {
                    break;
                }
                bql_lock();
                henge_service_external_exit(cs, cpu, r);
                /*
                 * Service stays, copy goes.  An ICC_EOIR1 write here really
                 * does reach QEMU's GIC and really does drop the line; the
                 * engine will read the new level at the next block boundary
                 * on its own, so pushing a snapshot now would only add a
                 * second, staler opinion.
                 */
                bql_unlock();
            }
            bql_lock();
            /* ------------------------------ */

            /* No line copy before dispatch: henge_dispatch_exit's own work
             * (parking, halting, kick handling) needs no snapshot, and the
             * engine re-reads the level when it is next entered. */
            henge_dispatch_exit(cs, r);
        }
    } while (!cs->unplug || cpu_can_run(cs));

    /*
     * Bridge, step 2 of 2: publish registers back so the monitor, gdbstub and
     * "info registers" see what the guest actually did.
     */
    hv_engine_save_state(&ARM_CPU(cs)->env, cpu);

    cpu_thread_signal_destroyed(cs);
    bql_unlock();
    rcu_unregister_thread();
    return NULL;
}

static void henge_start_vcpu_thread(CPUState *cs)
{
    char thread_name[VCPU_THREAD_NAME_SIZE];
    HvCpu *cpu;

    /*
     * Per-vCPU engine state.  Must use the _index variant: hv_cpu_reset()
     * hardcodes index 0 and would make every vCPU alias m->cpus[0].
     *
     * Done here rather than in the thread function because
     * henge_kick_vcpu_thread() may run before the thread does, and it needs
     * cs->opaque to be valid.
     */
    cpu = hv_engine_cpu_new(henge_accel_machine(), cs->cpu_index);
    if (!cpu) {
        error_report("henge: cannot allocate engine state for cpu %d",
                     cs->cpu_index);
        exit(1);
    }
    hv_engine_cpu_set_mpidr(cpu, ARM_CPU(cs)->mp_affinity);

    /*
     * Tell the translator what this CPU model actually advertises.
     *
     * The engine's translator implements ARMv8.1 atomics unconditionally, so
     * without this a guest running on a model whose ID_AA64ISAR0.ATOMIC reads
     * zero gets LSE executed instead of UNDEF -- wider than the architecture,
     * and a divergence from TCG that `work/probe/lse.S` measures directly.
     *
     * Read from QEMU's ID registers rather than from the engine's constants:
     * sysreg_external forwards the ID group, so QEMU's value is what the guest
     * sees and therefore the only correct input.
     *
     * Idempotent across CPUs: every CPU of a machine carries the same model, and
     * setting it per vCPU keeps it right even if that ever stops being true.
     */
    /*
     * LSE gate: ATTEMPTED AND REVERTED.
     *
     * The translator implements ARMv8.1 atomics unconditionally, and QEMU's
     * ID_AA64ISAR0.ATOMIC for this tree's -cpu max is 0, so the guest is told
     * "no LSE" while the engine would still execute it -- measured with
     * work/probe/lse.S (LSE-OK on henge, UNDEF on TCG).  Calling
     * hv_engine_set_lse(m, cpu_isar_feature(aa64_lse, ...)) closed that gap and
     * made the probe match TCG, but it also stopped the Linux baseline booting
     * at all (no serial output, killed at timeout), and the boot returns as
     * soon as the gate is forced back on:
     *
     *     hv_engine_set_lse(m, 0) -> no output, dead
     *     hv_engine_set_lse(m, 1) -> userspace alive, END=18.76
     *
     * So the guest really does execute something the gate classifies as
     * LSE-class on a CPU model that claims no LSE, or the two ID views disagree
     * (cpu_isar_feature vs. what the seam forwards).  Both are worth chasing,
     * neither is settled, and a working baseline is worth more than a
     * fidelity fix that bricks it.  Left off, and recorded rather than hidden.
     */
    /*
     * HV_NO_LSE: drive the gate from the CPU model instead of forcing it on.
     * Same getenv-in-the-accelerator style as the engine's own debug knobs, and
     * here for the same reason: the alternative is a rebuild per bisect step,
     * and this needs to be bisected on the phone.
     */
    hv_engine_set_lse(henge_accel_machine(),
                      getenv("HV_NO_LSE")
                          ? cpu_isar_feature(aa64_lse, ARM_CPU(cs)) != 0
                          : 1);

    cs->opaque = cpu;

    /*
     * Publish the CPUState and switch the engine to read-through: from here on
     * every interrupt decision it makes asks QEMU's flag instead of its own
     * copied level.  Must happen before the thread starts, or the first blocks
     * would consult a copy.
     */
    henge_engine_register_cpu(henge_accel_machine(), cpu, cs);
    hv_engine_set_irq_hook(henge_accel_machine(), henge_irq_line_get, NULL);

    snprintf(thread_name, VCPU_THREAD_NAME_SIZE, "CPU %d/Henge", cs->cpu_index);
    qemu_thread_create(cs->thread, thread_name, henge_cpu_thread_fn, cs,
                       QEMU_THREAD_JOINABLE);
}

/*
 * Publish the CPUState behind an engine vCPU.  Defined here rather than in
 * henge-engine.c because that file cannot see CPUState; it only stores the
 * callback (hv_engine_set_irq_hook).
 */
void henge_engine_register_cpu(HvMachine *m, HvCpu *cpu, CPUState *cs)
{
    (void)m;
    (void)cpu; /* HvCpu is opaque here; its index is cs->cpu_index by
                * construction -- hv_engine_cpu_new(m, cs->cpu_index) below
                * sets it, and the hook is called back with that same index. */
    if (!cs || (unsigned)cs->cpu_index >= HENGE_SEAM_MAX_VCPUS) {
        return;
    }
    qatomic_set(&henge_seam_cs[cs->cpu_index], cs);
}

static void henge_kick_vcpu_thread(CPUState *cs)
{
    if (!qemu_cpu_is_self(cs)) {
        HvCpu *cpu = henge_cpu_of(cs);
        if (cpu) {
            /*
             * Pure wake: no data travels with a kick any more.
             *
             * It used to push a line snapshot first ("a wake with a stale line
             * just puts it back to sleep").  That was the wrong fix for a real
             * symptom: the engine now reads cs->interrupt_request itself
             * (irq_line_get), so the block the wake causes sees the level as of
             * *its own* start, which is strictly fresher than anything we could
             * snapshot here -- and there is no stale copy left to go back to
             * sleep on.  What a kick has to guarantee is only that the vCPU
             * stops waiting and looks, which is what hv_cpu_wake() does.
             */
            hv_cpu_wake(cpu);
            /*
             * A kick alone does not bring the engine back: hv_cpu_wake() sets
             * the engine's exit_req, which run_loop() consumes as "let another
             * CPU have a turn" and then carries on executing.  So a vCPU with
             * no reason of its own to leave ignores every host request --
             * pause, shutdown, SIGTERM -- and the host waits for it forever.
             * That is exactly what "reboot: Power down" followed by a QEMU that
             * outlives twenty minutes of SIGTERM looked like.
             *
             * cs->stop is QEMU saying "stop executing now" (pause_all_vcpus,
             * vm_stop).  Translate it into the engine's one interruptible
             * exit, which it tests at the top of every loop iteration.
             */
            if (cs->stop) {
                hv_engine_cpu_request_stop(cpu);
            }
        }
    }
}

static bool henge_vcpu_thread_is_idle(CPUState *cs)
{
    return cs->halted;
}

/* Registers: QEMU is the reference on reset/init, the engine is afterwards. */
static void henge_cpu_synchronize_state(CPUState *cs)
{
    HvCpu *cpu = henge_cpu_of(cs);
    if (cpu) {
        hv_engine_save_state(&ARM_CPU(cs)->env, cpu);
    }
}

static void henge_cpu_synchronize_post_init(CPUState *cs)
{
    HvCpu *cpu = henge_cpu_of(cs);
    if (cpu) {
        hv_engine_load_state(cpu, &ARM_CPU(cs)->env);
    }
}

static bool henge_cpu_ops_target_realize(CPUState *cs, Error **errp)
{
    if (object_dynamic_cast(OBJECT(cs), TYPE_ARM_CPU) == NULL) {
        error_setg(errp, "henge accelerator supports aarch64 CPUs only");
        return false;
    }
    return true;
}

/*
 * Copy the calling thread's vCPU interrupt line into the engine.
 *
 * Lives here rather than in henge-accel.c because it needs CPU_INTERRUPT_HARD
 * *and* CPU_INTERRUPT_FIQ, and FIQ is defined in target/arm/cpu.h -- the
 * accelerator's common code may not include a per-target header.  This TU
 * already does, for arm_handle_psci_call().
 *
 * Called from henge_mmio_forward() right after a device access returns.  A
 * GICv2 SGI is an MMIO write, and a CPU that IPIs itself never gets a kick
 * (generic_handle_interrupt() skips qemu_cpu_kick() when is_self, and our kick
 * is the only other place that copies the line), so without this the guest
 * keeps running with a stale line past the point where it should have taken
 * the interrupt.  Measured as a 26 s / 89 s RCU stall under GICv2 + nohz that
 * TCG does not have.
 */
void henge_sync_irq_current(void)
{
    /*
     * Nothing to do, deliberately.
     *
     * This used to copy the line because an MMIO callback runs on the vCPU
     * thread from inside the engine, and a device touched there could raise an
     * interrupt that the engine would otherwise not see until it left.  With
     * read-through that ordering problem does not exist: the device wrote
     * QEMU's state, and QEMU's state is exactly what the engine consults at the
     * next block boundary -- same thread, same instant, nothing to publish.
     *
     * Kept as a symbol because the MMIO path calls it unconditionally and this
     * is the seam's documented no-op, not an oversight.
     */
}

/*
 * The QEMU half of henge_irq's report, for the same reason the seam hook
 * lives in this file: CPU_INTERRUPT_HARD/FIQ are target/arm macros.
 *
 * Deliberately reads the same two bits the seam hook reads, not a
 * re-derivation, so "in sync" means exactly "the last sync had nothing to
 * change" -- the only reading that can be used to blame the copy.
 */
void henge_irq_report(CPUState *cs, int *irq, int *fiq)
{
    if (!cs || !henge_enabled()) {
        *irq = *fiq = -1;
        return;
    }
    /*
     * Report the physical line (env.irq_line_state), the same source
     * the seam hook feeds the engine, so this command compares like with
     * like.  cs->interrupt_request is deliberately NOT used: it is a latch that
     * arm_cpu_exec_interrupt() would consume under TCG but never does here, so
     * it can read 1 long after its interrupt was delivered -- which is exactly
     * the confusion this command exists to resolve.  henge_irq prints it as a
     * separate column instead.
     */
    *irq = !!(ARM_CPU(cs)->env.irq_line_state & CPU_INTERRUPT_HARD);
    *fiq = !!(ARM_CPU(cs)->env.irq_line_state & CPU_INTERRUPT_FIQ);
}

static void henge_accel_ops_class_init(ObjectClass *oc, const void *data)
{
    AccelOpsClass *ops = ACCEL_OPS_CLASS(oc);

    ops->create_vcpu_thread = henge_start_vcpu_thread;
    ops->kick_vcpu_thread = henge_kick_vcpu_thread;
    ops->cpu_thread_is_idle = henge_vcpu_thread_is_idle;
    ops->handle_interrupt = generic_handle_interrupt;

    ops->synchronize_state = henge_cpu_synchronize_state;
    ops->synchronize_post_init = henge_cpu_synchronize_post_init;
    ops->synchronize_post_reset = henge_cpu_synchronize_post_init;

    ops->cpu_target_realize = henge_cpu_ops_target_realize;
}

static const TypeInfo henge_accel_ops_type = {
    .name = ACCEL_OPS_NAME("henge"),
    .parent = TYPE_ACCEL_OPS,
    .class_init = henge_accel_ops_class_init,
    .abstract = true,
};
module_obj(ACCEL_OPS_NAME("henge"));

static void henge_accel_ops_register_types(void)
{
    type_register_static(&henge_accel_ops_type);
}

type_init(henge_accel_ops_register_types);
