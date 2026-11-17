/*
 * Is a memset(0x80) flush safe against a concurrent reader of the same
 * HvTlbEntry?  This reproduces the engine's exact access sequence, with the
 * engine's exact struct layout, and counts how often a reader that saw a valid
 * tag then picked up a garbage addend.
 *
 * The reader's sequence is copied from two places in the engine:
 *
 *   memop.c (slow path):
 *       tag = load(t->read_tag);
 *       if (tag != HV_TLB_INVALID && tag + HV_TLB_ADJ == page) {
 *           hp = va + t->addend;            <- second, independent load
 *
 *   translate.c (hot path, emitted code):
 *       load tag, compare, branch; load addend from tlb+24; access [addr, addend]
 *
 * Neither rechecks, so the question is purely whether the two loads can
 * straddle the flush.  The writer is hv_tlb_flush()'s memset, which the engine
 * relies on being "what memset(0x80) leaves" (cpu.h:30).
 *
 * Build: gcc -O2 -pthread -o tlb_race tlb_race.c
 */
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define HV_TLB_ADJ     15
#define HV_TLB_INVALID 0x8080808080808080ull

/* Layout copied verbatim from engine/core/cpu.h.  If this assert ever fails,
 * the test is measuring a different structure than the engine uses. */
typedef struct {
    uint64_t read_tag;
    uint64_t write_tag;
    uint64_t exec_tag;
    int64_t  addend;
} HvTlbEntry;

_Static_assert(sizeof(HvTlbEntry) == 32, "engine entry is 32 bytes");

/* A window of real host memory the reader is allowed to touch: the test's
 * equivalent of "the region is still mapped".  Reading outside it is the
 * crash the engine would take. */
static unsigned char backing[1 << 20];
static uintptr_t      backing_lo, backing_hi;

static HvTlbEntry entry;
static atomic_int  stop_flag;

/* Counters are per-thread and summed at the end: atomics here would perturb
 * the very timing being measured. */
static uint64_t reader_iters, saw_valid, saw_garbage;
static uint64_t flushes;

/* A plausible guest VA whose page the entry describes. */
static const uint64_t page_va = 0x40080000ull;

static void *reader(void *arg)
{
    (void)arg;
    /* The addend that makes this entry "valid": host address of page_va. */
    const int64_t good_addend =
        (int64_t)((uintptr_t)backing - page_va);

    while (!atomic_load_explicit(&stop_flag, memory_order_relaxed)) {
        HvTlbEntry *t = &entry;

        /* --- exactly the engine's slow-path sequence --- */
        uint64_t tag = __atomic_load_n(&t->read_tag, __ATOMIC_RELAXED);
        if (tag != HV_TLB_INVALID && tag + HV_TLB_ADJ == page_va) {
            int64_t addend = __atomic_load_n(&t->addend, __ATOMIC_RELAXED);

            /* The tag said "this entry maps page_va".  If the addend is the
             * flush pattern, the reader has straddled the memset and would
             * now dereference 0x8080808080808080 + va. */
            if (addend == (int64_t)HV_TLB_INVALID) {
                saw_garbage++;
            } else {
                uintptr_t hp = (uintptr_t)(page_va + (uint64_t)addend);
                if (hp < backing_lo || hp + HV_TLB_ADJ >= backing_hi) {
                    saw_garbage++;
                }
            }
            saw_valid++;
            /* Keep the compiler from hoisting the loads out of the loop. */
            __asm__ volatile("" ::: "memory");
            (void)good_addend;
        }
        reader_iters++;
    }
    return NULL;
}

static void *writer(void *arg)
{
    (void)arg;
    const int64_t good_addend = (int64_t)((uintptr_t)backing - page_va);

    while (!atomic_load_explicit(&stop_flag, memory_order_relaxed)) {
        /* Re-arm, then flush: the engine's del/add cycle (romd) in miniature. */
        entry.read_tag  = page_va - HV_TLB_ADJ;
        entry.write_tag = page_va - HV_TLB_ADJ;
        entry.exec_tag  = page_va;
        entry.addend    = good_addend;
        __asm__ volatile("" ::: "memory");

        memset(&entry, 0x80, sizeof entry);   /* hv_tlb_flush()'s exact op */
        flushes++;
    }
    return NULL;
}

int main(int argc, char **argv)
{
    double seconds = argc > 1 ? atof(argv[1]) : 5.0;
    int nwriters = argc > 2 ? atoi(argv[2]) : 1;
    pthread_t rd, wr[8];
    struct timespec t0, t1;

    backing_lo = (uintptr_t)backing;
    backing_hi = backing_lo + sizeof backing;

    /* Arm the entry so the reader's fast path is taken from the start. */
    entry.read_tag = entry.write_tag = page_va - HV_TLB_ADJ;
    entry.exec_tag = page_va;
    entry.addend = (int64_t)((uintptr_t)backing - page_va);

    atomic_init(&stop_flag, 0);
    clock_gettime(CLOCK_MONOTONIC, &t0);
    pthread_create(&rd, NULL, reader, NULL);
    for (int i = 0; i < nwriters && i < 8; i++) {
        pthread_create(&wr[i], NULL, writer, NULL);
    }

    struct timespec dur = {(time_t)seconds, (long)((seconds - (time_t)seconds) * 1e9)};
    nanosleep(&dur, NULL);
    atomic_store(&stop_flag, 1);

    pthread_join(rd, NULL);
    for (int i = 0; i < nwriters && i < 8; i++) {
        pthread_join(wr[i], NULL);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);

    double el = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("seconds      %.2f\n", el);
    printf("writers      %d\n", nwriters);
    printf("flushes      %llu\n", (unsigned long long)flushes);
    printf("reads        %llu\n", (unsigned long long)reader_iters);
    printf("tag hit      %llu\n", (unsigned long long)saw_valid);
    printf("straddled    %llu\n", (unsigned long long)saw_garbage);
    printf("\n%s\n", saw_garbage
           ? "WINDOW IS REAL: a reader saw a valid tag with a flushed addend."
           : "no straddle observed (window exists but is timing-dependent; "
             "absence here is not proof of safety)");
    return saw_garbage ? 1 : 0;
}
