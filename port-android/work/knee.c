/* Working-set knee 曲线：软件 TLB 的有效覆盖半径在哪。
 *
 * 设计要点（决定了这条曲线能不能用来判断 TLB）：
 *   - **每 4 KB 页只放一个节点**，随机环遍历。于是每次访问必然落在不同页，
 *     cache 命中率几乎恒定（只有一个节点的 64 B），**测到的差异就是 TLB**。
 *   - 用 Fisher-Yates 造一个包含全部页的随机环（固定种子，可复现），
 *     沿着环走 N 步 —— 保证每页都被均匀访问，不是"热点页"。
 *   - 步数固定（默认 2^24 = 1677 万步），所以 ns/access 可直接横向比。
 *   - 工作集从 64 KB 扫到 256 MB，覆盖 16 页到 65536 页。
 *
 * 输出一行一台机器可解析：
 *     knee <working_set_KiB> <ns_per_access>
 *
 * 编译：aarch64-linux-gnu-gcc -O2 -static -o knee knee.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <stdint.h>
#include <time.h>

#define PAGE 4096
#define MAX_BYTES (2048u << 20)   /* 上限：2 GB 工作集（目标 8 GB 客机，测试到 2 GB） */
#define STEPS (16u << 20)     /* 每次测量的访问次数 */

static double mono(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

/* 在 pages 个页里造一个随机环：next[i] = 环上的下一个页号。
   用 xorshift 而非 rand()，保证 native 与 guest 走同一条路径。 */
static void build_cycle(uint32_t *next, uint32_t pages, uint64_t seed) {
    for (uint32_t i = 0; i < pages; i++) next[i] = i;
    uint64_t x = seed;
    for (uint32_t i = pages - 1; i > 0; i--) {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17;
        uint32_t j = (uint32_t)(x % (i + 1));
        uint32_t t = next[i]; next[i] = next[j]; next[j] = t;
    }
    /* 把置换变成环：next[perm[i]] = perm[i+1] */
    uint32_t *perm = malloc(pages * sizeof *perm);
    memcpy(perm, next, pages * sizeof *perm);
    for (uint32_t i = 0; i < pages; i++) next[perm[i]] = perm[(i + 1) % pages];
    free(perm);
}

/* 读客户机自己的 AnonHugePages（THP 覆盖率自检）。
   这是测 2 MB 大页 bank 的**前置条件**：如果这块缓冲还是 4 KB 页，
   量到的就是 4 KB 路径，会误判 bank 无效。 */
static void huge_report(const char *tag) {
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return;
    char line[256];
    unsigned long anon = 0, total = 0, free_ = 0;
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "AnonHugePages: %lu kB", &anon) == 1) continue;
        if (sscanf(line, "MemTotal: %lu kB", &total) == 1) continue;
        if (sscanf(line, "MemFree: %lu kB", &free_) == 1) continue;
    }
    fclose(f);
    f = fopen("/sys/kernel/mm/transparent_hugepage/enabled", "r");
    char mode[64] = "?";
    if (f) { if (fgets(mode, sizeof mode, f)) mode[strcspn(mode, "\n")] = 0; fclose(f); }
    fprintf(stderr, "[thp] %-9s AnonHugePages=%lu kB (%.1f MB)  MemTotal=%lu MB  MemFree=%lu MB\n",
            tag, anon, anon / 1024.0, total / 1024, free_ / 1024);
    fprintf(stderr, "[thp] enabled = %s\n", mode);
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    /* argv[1] 给了就当"只跑这一档"（单位 KiB），否则全扫 */
    uint64_t steps = STEPS;
    unsigned argv_only = argc > 1 ? (unsigned)strtoul(argv[1], NULL, 0) : 0;
    /* argv[2]=2 → "稀疏"模式：节点间隔 2 MB 而不是 4 KB。
       工作集不变，但只触碰 working_set/2MB 个 4 KB 页。
       用来判定瓶颈到底是"工作集大小"还是"4 KB 页数"：
       若稀疏模式下引擎回到 ~70 ns，说明 4 KB 页数（miss 率）才是墙，
       而大页粒度的快路径能直接拿到这个收益。 */
    unsigned stride_shift = argc > 2 ? (unsigned)strtoul(argv[2], NULL, 0) : 12;
    /* argv[2]=2 → "稀疏"模式：节点间隔 2 MB 而不是 4 KB。
       工作集不变，但只触碰 working_set/2MB 个 4 KB 页。
       用来判定瓶颈到底是"工作集大小"还是"4 KB 页数"：
       若稀疏模式下引擎回到 ~70 ns，说明 4 KB 页数（miss 率）才是墙，
       而大页粒度的快路径能直接拿到这个收益。 */

    /* 必须 2 MB 对齐 + MADV_HUGEPAGE，否则拿不到 THP：
       aligned_alloc(PAGE,...) 只有 4 KB 对齐，fault 时内核不会给大页。 */
    size_t need = MAX_BYTES + (2u << 20);
    char *raw = mmap(NULL, need, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (raw == MAP_FAILED) { fprintf(stderr, "mmap %u MB failed\n", MAX_BYTES >> 20); return 1; }
    char *mem = (char *)(((uintptr_t)raw + (2u << 20) - 1) & ~(uintptr_t)((2u << 20) - 1));
    if (madvise(mem, MAX_BYTES, MADV_HUGEPAGE) != 0)
        fprintf(stderr, "[thp] MADV_HUGEPAGE failed: %m\n");

    huge_report("before");
    memset(mem, 1, MAX_BYTES);      /* 全部落实：fault 时就地分配大页 */
    huge_report("after");

    uint64_t stride = 1ull << stride_shift;
    uint32_t *next = malloc((MAX_BYTES / PAGE) * sizeof *next);
    if (!next) return 1;

    static const unsigned kib[] = {
        1024, 2048, 4096, 8192, 16384, 32768, 65536,
        131072, 262144, 524288, 1048576, 2097152,
    };
    unsigned only_k = argv_only;
    if (!only_k) printf("%-12s %-12s %-10s %-8s\n", "workingset", "nodes", "ns/access", "stride");
    for (unsigned k = 0; k < sizeof kib / sizeof *kib; k++) {
        if (only_k && kib[k] != only_k) continue;
        uint32_t pages = (uint32_t)(((uint64_t)kib[k] * 1024u) / stride);
        build_cycle(next, pages, 0x9e3779b97f4a7c15ull + pages);

        /* 预热：把环走一遍，让 TLB/分支都进稳态 */
        volatile uint32_t *v = (volatile uint32_t *)mem;
        uint32_t cur = 0;
        for (uint32_t i = 0; i < pages; i++) { v[(size_t)cur * (stride / 4)]; cur = next[cur]; }

        uint64_t acc = 0;
        double t0 = mono();
        for (uint64_t i = 0; i < steps; i++) {
            /* 一次访问 = 换一个页：v[cur * 1024] 是 volatile 读，编译器不能消掉 */
            acc += v[(size_t)cur * (stride / sizeof(uint32_t))];
            cur = next[cur];
        }
        double t1 = mono();
        if (acc == 0xdeadbeefu) printf("impossible %llu\n", (unsigned long long)acc);
        printf("knee %-7u %-12u %.3f   1<<%u\n", kib[k], pages, (t1 - t0) * 1e9 / (double)steps, stride_shift);
    }
    free(next);
    munmap(raw, need);
    return 0;
}
