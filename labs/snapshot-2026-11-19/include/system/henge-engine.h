/*
 * Contract between the Henge accelerator and the engine
 *
 * The engine (now vendored under accel/henge/engine) was host-agnostic except
 * for "where does guest RAM come from".  Under QEMU that one thing changes
 * owner, so the contract is deliberately small.
 *
 * This header is for QEMU translation units only.  It must not include
 * engine/core/*.h: those define the HvCpu layout (2.2 MB of inline TLB), pull
 * in <pthread.h> and friends, and have no business in QEMU's compile units.
 * accel/henge/henge-engine.c is the one file that sees both worlds, and it
 * _Static_asserts that the prototypes below match the engine's byte for byte
 * (a stale copy of these declarations is otherwise a silent ABI mismatch that
 * shows up as a guest triple fault three thousand instructions in).
 *
 * Two corrections against the first draft of this file, both found while
 * wiring the real engine:
 *
 *   1. The exit codes were wrong.  HV_EXIT_HALT was declared 3 and
 *      "HV_EXIT_MMIO" 4.  In core/cpu.h the enum is
 *      NONE=0 BRANCH=1 SYSREG=2 EXCEPTION=3 WFI=4 UNDEF=5 UNSUPPORTED=6
 *      HALT=7 FLUSH=8, so 3 was EXCEPTION and 4 was WFI.  A vCPU that took an
 *      exception would have been reported to QEMU as "halted".
 *   2. There is no HV_EXIT_MMIO at all.  MMIO never leaves the run loop: the
 *      engine services it inside hv_phys_read/hv_phys_write through an HvMmio
 *      callback.  So the callback below is synchronous, not an exit reason --
 *      which also means it runs with the BQL *dropped* (hv_run is called with
 *      the BQL released, MTTCG style) and must take it itself.
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef SYSTEM_HENGE_ENGINE_H
#define SYSTEM_HENGE_ENGINE_H

#include "qemu/osdep.h"

/* Forward declaration only: the monitor layer needs to name a CPUState here
 * without dragging in hw/core/cpu.h (and through it, target-specific bits). */
typedef struct CPUState CPUState;

/* Opaque handles: the engine's real types live in engine/core/machine.h and
 * engine/core/cpu.h.  HvCpu is ~2.2 MB (four software TLB tables inline) and
 * needs 128-byte alignment for its `aligned(128)` members, so it is always
 * heap-allocated by the engine, never by QEMU. */
typedef struct HvMachine HvMachine;
typedef struct HvCpu HvCpu;

/* ---- engine exit codes (mirror the HvExitReason enum in core/cpu.h) ----
 *
 * Named HENGE_EXIT_*, not HV_EXIT_*: the engine's own names are enum
 * constants, and a macro of the same name would rewrite the enum in core/cpu.h
 * into garbage ("expected identifier before numeric constant") the moment one
 * translation unit sees both headers -- which henge-cpu.c does.  henge-cpu.c
 * _Static_asserts that each value still matches, so the mirror cannot drift
 * silently. */
enum {
    HENGE_EXIT_NONE        = 0,
    HENGE_EXIT_BRANCH      = 1,
    HENGE_EXIT_SYSREG      = 2,
    HENGE_EXIT_EXCEPTION   = 3,
    HENGE_EXIT_WFI         = 4,
    HENGE_EXIT_UNDEF       = 5,
    HENGE_EXIT_UNSUPPORTED = 6,
    HENGE_EXIT_HALT        = 7,
    HENGE_EXIT_FLUSH       = 8,
    HENGE_EXIT_FAULT_LOOP  = 9,  /* fetching the exception vector itself faulted */
    HENGE_EXIT_SYSREG_EXT  = 10, /* an MRS/MSR the engine does not model (see the seam fns) */
    HENGE_EXIT_PSCI_EXT    = 11, /* SMC/HVC handed to the host's PSCI conduit */
};

/* ==== provided by the engine, called straight through ==== */

/* Register a RAM window; called from the MemoryListener.  `host` is QEMU's
 * pointer for guest PA `pa`, and readonly marks ROM (writes are dropped, as on
 * a real ROM).  Must be called before any vCPU runs. */
int hv_machine_add_ram(HvMachine *m, uint64_t pa, uint64_t size,
                       void *host, int readonly);

/* Run until something the dispatcher cannot handle happens.  Returns HV_EXIT_*.
 * The caller must NOT hold the BQL (see the MTTCG lock order in
 * henge-accel-ops.c); the engine runs guest code for as long as it likes. */
int hv_run(HvCpu *cpu);

/* Wake a vCPU out of its run loop (exit_req = 1; sev).  Safe from any thread. */
void hv_cpu_wake(HvCpu *cpu);

/* ==== glue: implemented in accel/henge/henge-engine.c ==== */

/* Allocate the engine machine and its JIT region (but no RAM: QEMU owns it).
 * Returns NULL on failure.  HvMachine's sizeof is private to the engine. */
HvMachine *hv_engine_machine_new(size_t jit_bytes);

/* Allocate + reset a per-vCPU engine state block.  Must use the _index form
 * internally: the plain hv_cpu_reset() hardcodes index 0, which silently makes
 * every vCPU alias m->cpus[0] (that bug cost a day in test_smc_mp: two CPUs
 * shared one whint array and protect_code squashed both). */
HvCpu *hv_engine_cpu_new(HvMachine *m, uint32_t index);

void hv_engine_cpu_set_mpidr(HvCpu *cpu, uint64_t mpidr);

/* Unregister a RAM window.  Must do three things, not one:
 *   1. drop the HvRam entry so later hv_ram_lookup/hv_phys_ptr misses it;
 *   2. flush every CPU's TLB -- stale entries point into memory QEMU is about
 *      to hand to someone else;
 *   3. invalidate translations made from those pages (page_gen++ and clear
 *      code_pages).  Skipping (3) is the silent-SMC variant: stale JIT blocks
 *      keep executing bytes that now belong to another device. */
int hv_machine_del_ram(HvMachine *m, uint64_t pa, uint64_t size);

/* The same, but leaving the invalidation to hv_engine_request_flush().  Use
 * this from a host thread that runs while vCPUs are live (QEMU's
 * MemoryListener): it retires the window so the slow path stops using it, and
 * touches no vCPU state at all. */
int hv_machine_del_ram_flags(HvMachine *m, uint64_t pa, uint64_t size,
                             int defer_flush);

/* Ask for a full invalidation (blocks, JIT, every IJC, return tables and every
 * software TLB entry) at the next moment all vCPUs are parked.  Does not wait:
 * the caller holds the BQL, and a vCPU blocked in MMIO forwarding is waiting
 * for that same BQL, so waiting here would deadlock. */
void hv_engine_request_flush(HvMachine *m);

/* Hook for physical accesses the engine cannot satisfy from its own RAM table
 * or its own HvMmio list -- under QEMU that is every device access, forwarded
 * to address_space_rw so QEMU's device models stay authoritative.
 *
 * The callback runs on a vCPU thread with the BQL dropped and must take it
 * itself.  Return 0 on success, -1 if QEMU could not satisfy the access either
 * (the engine then raises a data abort in the guest, as real hardware would). */
typedef int (*HvMmioForward)(void *opaque, uint64_t pa, void *buf,
                             uint32_t len, int is_write);

void hv_engine_set_mmio_forward(HvMachine *m, HvMmioForward fn, void *opaque);

/* Copy QEMU's CPUARMState (a void* so this header stays independent of
 * target/arm/cpu.h) into an HvCpu, and back.
 *
 * Direction matters.  QEMU is authoritative at reset (arm_load_kernel wrote
 * the entry point into env->pc after arm_cpu_reset_hold), the engine is
 * authoritative afterwards.  Snapshot/migration is not supported: load_state
 * carries the general registers, PC, PSTATE and the VFP file, and nothing
 * else -- refuse -incoming rather than pretend. */
int hv_engine_load_state(HvCpu *cpu, const void *arm_env);
void hv_engine_save_state(const void *arm_env, HvCpu *cpu);

/* ---- seams: what QEMU owns instead of the engine ----
 *
 * These exist because the engine, left alone, *decides* things a hosted build
 * must not decide.  Two examples, both of which would be silent corruption
 * rather than a crash:
 *
 *   an ICC_IAR1_EL1 read     the engine does not model GICv3's CPU interface,
 *                            so it raised UNDEF and the guest concluded its
 *                            GIC was broken.  The registers are not the
 *                            engine's to judge: they live in QEMU's
 *                            cpu->cp_regs, put there by the GIC when it was
 *                            realized.
 *   an HVC for PSCI CPU_ON   the engine ran its own PSCI and reset the target
 *                            HvCpu itself, behind the back of the CPU object
 *                            and vCPU thread that QEMU owns.
 *
 * With both flags set, the engine leaves the block at those points and QEMU
 * answers; see the four resume functions below.  The flags are runtime (not
 * #ifdef) so the standalone build and this one keep sharing code paths.
 */
void hv_engine_set_external(HvMachine *m, int sysreg, int psci);

/* Seconds between the engine's periodic stats dumps, 0 = off.  Several
 * counters are only incremented when this is non-zero, so a zero here does not
 * mean "nothing to report" -- it means "nothing is being counted". */
void hv_engine_set_stats_interval(HvMachine *m, int secs);

/* A pending HENGE_EXIT_SYSREG_EXT: what it is, and where.
 * `reg` is the engine's 16-bit packing of op0:op1:crn:crm:op2; `is_write` is
 * 1 for MSR, and then `value` is what the guest wrote (Rt's contents), so the
 * caller never has to know where the register file lives.  Returns 0 if there
 * is nothing pending. */
int hv_engine_sysreg_pending(const HvCpu *cpu, uint32_t *reg, int *rt,
                             int *is_write, uint64_t *pc, uint64_t *value,
                             int *el);

/* Finish it.  handled != 0 writes `value` into Rt (for an MRS), advances pc by
 * 4 and rechecks interrupts; handled == 0 raises the UNDEF the engine would
 * have raised on its own, so an unanswered register still traps correctly. */
void hv_engine_sysreg_resume(HvCpu *cpu, uint64_t value, int handled);

/* The same pair for HENGE_EXIT_PSCI_EXT.  args[] is x0..x3 as the caller left
 * them; the conduit's return value goes back in x0. */
int hv_engine_psci_pending(const HvCpu *cpu, uint64_t *pc, uint64_t args[4],
                           int *is_smc);
void hv_engine_psci_resume(HvCpu *cpu, uint64_t ret, int handled);

/* Drop everything derived that a system_reset invalidates: translated blocks,
 * every CPU's software TLB, and the per-page code/whint/gen bookkeeping.
 *
 * Without this a second boot reuses translations of the *previous* image: a
 * block is keyed by {va, pa, flags, gen}, and a reboot changes none of them
 * while changing every byte behind them.  A vCPU-level reset cannot do this
 * (it sees one CPU) and code invalidation cannot either (it sees one page). */
void hv_engine_machine_reset(HvMachine *m);

/* ---- the time base ----
 *
 * CNTFRQ is the host's, not a constant: hardcoding it is how a guest ends up
 * calibrating against a frequency the deadlines are not measured in.
 *
 * hv_engine_timer_ticks() is the engine's counter expressed in the *guest's*
 * tick domain but with no epoch yet -- the caller subtracts nothing and instead
 * computes epoch = that value - the host's virtual-clock ticks, so that from
 * then on (engine ticks - epoch) equals the host's clock.  Call
 * set_timer_epoch() again after every resume: the host's virtual clock freezes
 * while the VM is stopped and the host's counter does not, so a single
 * calibration made at boot drifts by exactly the time spent paused.
 */
void hv_engine_set_timer_freq(HvMachine *m, uint64_t freq);
uint64_t hv_engine_timer_freq(const HvMachine *m);
uint64_t hv_engine_timer_ticks(HvMachine *m);
void hv_engine_set_timer_epoch(HvMachine *m, uint64_t epoch);



/* ---- interrupt lines ----
 *
 * Level copy from the host's interrupt controller into the CPU's two input
 * lines.  The engine then applies its own PSTATE mask; do not pre-mask here.
 */
void hv_engine_set_irq(HvCpu *cpu, int irq, int fiq);

/* Read back what the engine currently believes the two input lines are.
 *
 * Exists for one diagnosis: when a vCPU spins at full host speed without the
 * guest making progress, the question is whether the level the engine holds
 * still matches CPUState.interrupt_request.  hv_engine_set_irq() is the only
 * writer, and there is no path that lowers the line on its own, so a guest that
 * stops acking leaves the engine looking at a level nobody refreshes.  A plain
 * read is enough to tell "the driver really is asserting" from "the copy is
 * stale" -- which decides whether the fix belongs in the GIC or in the sync. */
int hv_engine_get_irq(HvCpu *cpu, int fiq);

/* Live engine-side CPU state, for diagnosing a spinning vCPU.
 *
 * QEMU's ARM_CPU(cs)->env is only refreshed by hv_engine_save_state(), which
 * runs when hv_run() returns -- so while a guest is stuck *inside* the run loop
 * the monitor shows a snapshot that may be arbitrarily old.  These are the
 * values the engine is actually deciding on right now: the PSTATE mask it
 * applies in hv_check_interrupts(), and the pc it is about to execute.
 */
void hv_engine_get_cpu_state(HvCpu *cpu, uint64_t *pc, uint64_t *daif,
                             uint64_t *el);

/* How many interrupts this CPU has injected into the guest so far.
 *
 * This is the only sound moment to drop QEMU's CPU_INTERRUPT_HARD latch: the
 * bit is set by the GIC and, under TCG, cleared by arm_cpu_exec_interrupt()
 * once the interrupt has been delivered.  henge delivers inside the engine, so
 * that clear never runs and the bit outlives its interrupt -- after which
 * henge_sync_irq() keeps handing the engine a level of 1, WFI completes
 * instantly forever, and the vCPU spins at full host speed instead of
 * parking.  Comparing this counter against the previous value tells the
 * accelerator exactly when the latch has served its purpose. */
uint64_t hv_engine_get_irq_injections(HvCpu *cpu);

/* The QEMU side of the same join, resolved on the accelerator's behalf.
 *
 * The HARD/FIQ request bits are target/arm-specific macros and neither ui/ nor
 * the monitor layer may include cpu.h to reach them, so the pairing happens in
 * accel/henge/henge-accel-ops.c, which already owns henge_sync_irq() and knows
 * exactly which bits it copies.  Both ints are 0/1, or -1 when the vCPU has no
 * engine state yet.
 */
void henge_irq_report(CPUState *cs, int *irq, int *fiq);

/*
 * Publish the CPUState behind an engine vCPU (implemented in
 * henge-accel-ops.c, which can see CPUState).
 *
 * Call once per vCPU, before its thread starts, together with
 * hv_engine_set_irq_hook -- after which every interrupt decision the engine
 * makes reads cs->interrupt_request instead of its own copied level.  See
 * machine.h irq_line_get for why that single-owner rule is what makes ARM's
 * level semantics hold across this seam.
 */
void henge_engine_register_cpu(HvMachine *m, HvCpu *cpu, CPUState *cs);

/*
 * Install the read-through interrupt hook.  `fn` is called at every block
 * boundary with the engine's cpu index; returning 1 means the line is asserted.
 * Passing NULL restores the engine's own level bytes, which is what a
 * standalone (no-QEMU) build uses.
 */
void hv_engine_set_irq_hook(HvMachine *m,
                            int (*fn)(void *ctx, unsigned cpu_index, int fiq),
                            void *ctx);

/*
 * Spike counters, for telling the three failure shapes apart from the monitor
 * instead of from an strace of stderr.  They live in the engine's
 * core/dispatch.c and core/machine.c and are plain relaxed counters: reading
 * them from the monitor while a vCPU runs can only skew individual values,
 * which is why the diagnosis uses the *difference* between park_enter and
 * park_leave rather than either number alone.
 *
 *   park_enter - park_leave grows steadily   -> idle, healthy
 *   park_enter - park_leave frozen at 1      -> asleep forever ("0% CPU" hang)
 *   park_enter frozen, host CPU at 100%      -> never parked; spinning livelock
 */
extern uint64_t hv_spike_park_enter[/*HV_MAX_CPUS*/ 8];
extern uint64_t hv_spike_park_leave[/*HV_MAX_CPUS*/ 8];
extern uint64_t hv_spike_wake[/*HV_MAX_CPUS*/ 8];

/* A write to guest RAM that did not come from the CPU (device DMA, a monitor
 * poke, migration).  Invalidates any translation of the pages it touched; pages
 * that never held code cost one lookup. */
void hv_engine_dma_written(HvMachine *m, uint64_t pa, uint64_t len);

/*
 * Install the generic-timer tick source.
 *
 * Until this is called, m->tick is NULL, and wait_for_interrupt() therefore has
 * exactly two behaviours: return immediately (line already high) or give up and
 * unwind the whole run ("nothing could ever wake us").  The latter is what a
 * two-vCPU boot actually does, measured: 512 times per CPU, versus 4 / 2 for
 * the former.  So the engine could never sleep to a deadline; it could only be
 * kicked from outside, one host round trip per timer event.
 *
 * `fn` returns how many 24 MHz host ticks remain until this vCPU's next timer
 * expiry, or 0 when nothing is armed.  A relative delta, not an absolute
 * deadline, because the guest's CNTFRQ domain and the engine's 24 MHz counter
 * domain are related only through an epoch that QEMU recalibrates on every
 * stop/cont -- a difference cancels it, an absolute value would have to
 * reconstruct it and would drift after a pause.
 *
 * `index` is the vCPU index, not a CPUState: this header is for QEMU
 * translation units but the tick lives on the engine side, and HvCpu stays
 * opaque here.  Pass NULL to uninstall.
 */
void hv_engine_set_tick(HvMachine *m, uint64_t (*fn)(void *opaque,
                                                     uint32_t index),
                        void *opaque);

/*
 * Make hv_run() come back, and undo it.
 *
 * The engine returns for its own reasons (WFI, an unmodelled sysreg, an
 * unencodable instruction) and none of them is "the host asked".  QEMU's
 * qemu_cpu_kick() only sets cs->exit_request plus a kick, and the engine's
 * exit_req is consumed inside run_loop() as "let another CPU run", not as
 * "return".  A vCPU with nothing of its own to report therefore never leaves,
 * pause_all_vcpus() waits for it forever, and the process cannot shut down --
 * observed as "reboot: Power down" followed by a QEMU that outlives every
 * SIGTERM.
 *
 * halted is the one exit the host can pull: run_loop() tests it at the top of
 * every iteration, so setting it turns the next block boundary into
 * HV_EXIT_HALT.  Call clear_stop() before re-entering after a resume, or the
 * vCPU will return HALT forever without executing anything.
 */
void hv_engine_cpu_request_stop(HvCpu *cpu);
void hv_engine_cpu_clear_stop(HvCpu *cpu);

/*
 * Tell the translator whether the guest is being told it has ARMv8.1 atomics.
 *
 * The translator implements LSE unconditionally, so without this a guest on a
 * CPU whose ID_AA64ISAR0.ATOMIC reads zero -- which is every v8.0 model,
 * including the cortex-a57 baseline this tree's `-cpu max` uses -- gets
 * execution where the architecture says UNDEF.  TCG traps; henge did not.
 *
 * The engine cannot derive this itself under a host that owns the system
 * registers: the ID group is forwarded, so its own constants are not what the
 * guest sees.
 *
 * Default is 1 (on), set by hv_machine_init(); standalone builds never call
 * this and keep their existing behaviour.
 */
void hv_engine_set_lse(HvMachine *m, int on);

/* Forget every RAM window (no TLB flush, no block invalidation: this is the
 * re-mirror half of a reset, used right after hv_engine_machine_reset(), which
 * has done both).  Without it a region that disappeared across the reset would
 * stay in the table, pointing at memory QEMU has released. */
void hv_engine_ram_clear(HvMachine *m);

/* Guest PC of the access currently being emulated by the slow path, or 0 if
 * the engine is not in one.  The engine keeps this for its own diagnostics;
 * the accelerator reads it so that an MMIO trace line names the instruction
 * responsible instead of only the address.  Without it, "the guest wrote
 * 0xE8 here nineteen thousand times" cannot be told apart from "the engine
 * replayed one store nineteen thousand times" -- the two need opposite
 * fixes. */
uint64_t hv_engine_access_pc(const HvMachine *m);

#endif /* SYSTEM_HENGE_ENGINE_H */
