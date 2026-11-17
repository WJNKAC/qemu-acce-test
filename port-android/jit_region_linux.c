/* Linux/Android 上的可写可执行代码区。
   原版在 iOS 上要靠调试器给 RX 页、再用 vm_remap 做 RW 别名；这里是普通
   Linux，直接 mmap 一份 RWX 就够。若内核或 SELinux 拒绝 RWX（某些机型会），
   退回 memfd + 双映射：同一份物理页，一个 RW 别名、一个 RX 别名，
   就是对 iOS 那个 split 形状的原样再现。 */
#include "jit_region.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/mman.h>
#include <unistd.h>

#ifndef MAP_ANONYMOUS
#define MAP_ANONYMOUS MAP_ANON
#endif

static int open_rwx(HvJitRegion *region, size_t bytes) {
    void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return -1;
    region->base = p;
    region->rw_diff = 0; /* 同一份映射：写和跑是同一个地址 */
    region->capacity = bytes / sizeof(uint32_t);
    region->used = 0;
    region->limit = 0;
    region->owned = 1;
    return 0;
}

static int open_split_memfd(HvJitRegion *region, size_t bytes) {
    int fd = memfd_create("hv-jit", MFD_CLOEXEC);
    if (fd < 0) return -1;
    if (ftruncate(fd, (off_t)bytes) != 0) { close(fd); return -1; }
    void *rx = mmap(NULL, bytes, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0);
    void *rw = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (rx == MAP_FAILED || rw == MAP_FAILED) {
        if (rx != MAP_FAILED) munmap(rx, bytes);
        if (rw != MAP_FAILED) munmap(rw, bytes);
        return -1;
    }
    if (hv_jit_region_attach(region, rx, rw, bytes) != 0) return -1;
    region->owned = 1;
    return 0;
}

int hv_jit_region_open(HvJitRegion *region, size_t bytes) {
    memset(region, 0, sizeof *region);
    if (bytes < 4096) bytes = 4096;
    bytes = (bytes + 4095) & ~(size_t)4095;
    if (getenv("HV_JIT_SPLIT")) return open_split_memfd(region, bytes);
    if (open_rwx(region, bytes) == 0) return 0;
    return open_split_memfd(region, bytes);
}

int hv_jit_region_attach(HvJitRegion *region, void *rx, void *rw, size_t bytes) {
    memset(region, 0, sizeof *region);
    if (!rx || !rw || bytes < 4096) return -1;
    region->base = rx;
    region->rw_diff = (intptr_t)((uint8_t *)rw - (uint8_t *)rx);
    region->capacity = bytes / sizeof(uint32_t);
    return 0;
}

void hv_jit_region_close(HvJitRegion *region) {
    if (region->owned && region->base) {
        size_t bytes = region->capacity * sizeof(uint32_t);
        if (region->rw_diff) munmap((uint8_t *)region->base + region->rw_diff, bytes);
        munmap(region->base, bytes);
    }
    memset(region, 0, sizeof *region);
}

void hv_jit_write(HvJitRegion *region, uint32_t *start, const void *src, size_t bytes) {
    /* 4 字节要原子：另一个 CPU 可能正在执行这条分支，取到半新半旧就是跳进虚空。 */
    if (bytes == 4) {
        uint32_t word;
        memcpy(&word, src, 4);
        __atomic_store_n((uint32_t *)((uint8_t *)start + region->rw_diff), word, __ATOMIC_RELEASE);
        return;
    }
    memcpy((uint8_t *)start + region->rw_diff, src, bytes);
}

/* ---- 宿主没有 SB 时，把 SB 改写成 DSB NSH ----
 *
 * core/sysreg.c 把 ID_AA64ISAR1_EL1 固定成 0x0000001100211001，最低 4 位（SB 字段）
 * 是 1，等于告诉 guest "这台机器有 ARMv8.5 的 SB 指令"。原项目跑在 Apple Silicon
 * （ARMv8.5+，真有 SB）上，所以没问题。
 *
 * Linux 会照这个声明做 alternatives：arch/arm64/include/asm/barrier.h
 *     #define spec_bar() ALTERNATIVE("dsb nsh; isb", SB_BARRIER_INSN"nop", ARM64_HAS_SB)
 * 启动时把 KPTI trampoline（__bp_harden_el1_vectors）里的 dsb nsh 就地补丁成 sb。
 * 这台机器是 Cortex-A76（ARMv8.2），执行 sb 直接 SIGILL —— 实测崩在
 * guest_pc 0xffff800080012c14 之后，宿主指令 0xd50330ff。
 *
 * 改写成 dsb nsh 与 Linux 自己在 HAS_SB 为假时生成的序列完全一致，语义只会更强。
 * 宿主真有 SB 时（getauxval 的 HWCAP_SB）一次都不用改。 */
#define HV_A64_SB      0xd50330ffu  /* sb                (ARMv8.5) */
#define HV_A64_DSB_NSH 0xd503379fu  /* dsb nsh           (ARMv8.0) */
#define HV_HWCAP_SB    (1ul << 29)

static int host_has_sb(void) {
    static int cached = -1;
    if (cached < 0) cached = (getauxval(AT_HWCAP) & HV_HWCAP_SB) != 0;
    return cached;
}

static size_t rewrite_unsupported(uint32_t *rw, size_t words) {
    size_t n = 0;
    for (size_t i = 0; i < words; i++)
        if (rw[i] == HV_A64_SB) rw[i] = HV_A64_DSB_NSH, n++;
    return n;
}

void hv_jit_finish(HvJitRegion *region, uint32_t *start, size_t words) {
    if (!start || !words) return;
    if (!host_has_sb()) rewrite_unsupported((uint32_t *)((uint8_t *)start + region->rw_diff), words);
    /* 写的是别名、跑的是主映射：两边的 VA 都做一次维护，PIPT D-cache 下
       清一次物理行就够，但多做一次只花几十纳秒，不值得去赌。 */
    __builtin___clear_cache((char *)start, (char *)start + words * 4);
    if (region->rw_diff) {
        char *rw = (char *)start + region->rw_diff;
        __builtin___clear_cache(rw, rw + words * 4);
    }
}

uint32_t *hv_jit_reserve(HvJitRegion *region, size_t words) {
    words = (words + 1) & ~(size_t)1;
    size_t at = __atomic_fetch_add(&region->used, words, __ATOMIC_RELAXED);
    size_t cap = region->limit && region->limit < region->capacity ? region->limit : region->capacity;
    if (at + words > cap) return NULL;
    return region->base + at;
}

void hv_jit_reset(HvJitRegion *region) { region->used = 0; }
