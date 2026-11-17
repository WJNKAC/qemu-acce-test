/* test_smc_mp —— 跨 vCPU 的自修改代码（SMC）作废测试。
 *
 * 为什么需要它：
 *   只读 bank 解决了"单核写代码页绕过 whint"的洞（test_exc 的 p_smc_nomaint）。
 *   但那是 **单核**：写和读在同一个 CPU 的 TLB/bank 里，失效一定看得见。
 *   多核的场景不一样 —— 核 0 写代码页，核 1 执行它，核 1 自己没有任何写动作，
 *   它的 bank **永远不会因为这次写而失效**（bank 只挂在 flush/switch_user 上）。
 *
 *   理论上这是安全的，理由是结构性的，不是"碰巧"：
 *     · bank 只缓存 VA→PA 的 addend，**不缓存代码内容**；
 *     · mmu.c 里 bank 出现 0 次 —— 取指路径（exec_tag / 块查找）完全不经过 bank；
 *     · 翻译作废走 hv_invalidate_code → page_gen[pg]++，而 page_gen 是 **RAM 全局**的
 *       （不是 per-CPU），所以核 1 下次查块时 gen 不匹配就重翻。
 *   但这个结论必须被测试钉住，而不是靠读代码推断。本文件就是那根钉子。
 *
 * 测法（不用线程：两个 HvCpu 交替跑，写由"另一个 CPU 上下文"发出）：
 *   1. cpu0 从 code 页跑一条指令 → 块被翻译并缓存，x0 = 1；
 *   2. 顺便让 cpu0 **数据读**一次代码页，把它的 bank 填上（模拟"核1 已经缓存了这个块"）；
 *   3. cpu1 执行一条 str，把 code 页第 0 条指令改成 mov x0, #2 → 触发全局作废；
 *   4. cpu0 **不 reset**，再跑同一页 → 必须是 2。若作废没传播过来，会拿旧块返回 1。
 *
 * 第 4 步"不 reset"是关键：hv_cpu_reset 会清 TLB/bank/块缓存，那样测的就不是传播了。
 */

#include "harness.h"

#include <stdlib.h>
#include <string.h>

#include "cpu.h"
#include "dispatch.h"
#include "machine.h"
#include "mmu.h"

/* 可写代码页：4 KB 对齐，内容由测试改写。 */
static uint32_t code_page[1024] __attribute__((aligned(4096)));

/* 一条指令的编码（A64）。 */
#define INSN_MOV_X0_1 0xd2800020u /* mov x0, #1 */
#define INSN_MOV_X0_2 0xd2800040u /* mov x0, #2 */

/* 跑"从 pc 开始、到 stop 结束"的一段，**不** reset CPU。 */
static int run_at(HvMachine *m, HvCpu *cpu, const void *start, const void *stop) {
    cpu->pc = (uint64_t)(uintptr_t)start;
    m->stop_pc = (uint64_t)(uintptr_t)stop;
    m->stop_pc2 = 0;
    int r = hv_run(cpu);
    if (r != HV_EXIT_HALT) {
        fprintf(stderr, "  smc_mp: dispatcher returned %d at pc %llx\n", r, (unsigned long long)cpu->pc);
        return 1;
    }
    return 0;
}

/* 让 cpu 执行一条 str，把 [target] 写成 w1（走真实的 memop 写路径，不走 bank）。 */
static int do_remote_write(HvMachine *m, HvCpu *writer, uint32_t *target, uint32_t insn) {
    /* str w1, [x0]; 后面紧跟一个不可达的 halt 边界。 */
    static uint32_t stub[2] __attribute__((aligned(16)));
    stub[0] = 0xb9000001u; /* str w1, [x0] */
    stub[1] = 0xd503201fu; /* nop（跑到这里就停） */

    /* stub 也在 RAM 里，需要先登记，否则取指会失败。 */
    writer->x[0] = (uint64_t)(uintptr_t)target;
    writer->x[1] = insn;
    return run_at(m, writer, stub, stub + 1);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    static HvMachine m;
    if (hv_machine_init(&m, 8 << 20) != 0) return 1;

    /* code_page 与 stub 都要作为 RAM 登记（可写）。stub 是 do_remote_write 里的静态数组，
       所以这里用一个固定地址：把两者放进同一块。为简单起见，用 mmap 一段连续内存。 */
    size_t sz = 64 << 10;
    uint8_t *mem = aligned_alloc(16384, sz);
    memset(mem, 0, sz);
    if (hv_machine_add_ram(&m, (uint64_t)(uintptr_t)mem, sz, mem, 0) != 0) {
        fprintf(stderr, "add_ram failed\n");
        return 1;
    }
    uint32_t *code = (uint32_t *)(void *)mem;              /* 偏移 0：被测代码页 */
    uint32_t *wstub = (uint32_t *)(void *)(mem + 4096);    /* 偏移 4K：写桩 */
    uint32_t *rstub = (uint32_t *)(void *)(mem + 8192);    /* 偏移 8K：读桩 */
    code[0] = INSN_MOV_X0_1;
    code[1] = 0xd503201fu;
    wstub[0] = 0xb9000001u; /* str w1, [x0] */
    wstub[1] = 0xd503201fu;
    rstub[0] = 0xb9400002u; /* ldr w2, [x0] —— 走 JIT 的 bank 探测，命中才会填 bank */
    rstub[1] = 0xd503201fu;

    static HvCpu c0, c1;
    /* 必须用 hv_cpu_reset_index 并给不同 index：hv_cpu_reset 内部固定传 0，
       两个 CPU 会都被注册成 m->cpus[0]，后者覆盖前者 —— 于是 protect 只遍历到一个 CPU，
       whint 也共用同一份（它按 cpu->index 索引）。这个坑让本测试的第一版假失败。 */
    hv_cpu_reset_index(&c0, &m, 0);
    hv_cpu_reset_index(&c1, &m, 1);

    int failures = 0;

    /* ---- 1. cpu0 翻译并执行 code[0]，应得 x0 = 1 ---- */
    c0.x[0] = 0;
    if (run_at(&m, &c0, code, code + 1)) return 1;
    int first = (int)c0.x[0];
    printf("cpu0 first run          : x0 = %d (want 1)\n", first);
    failures += first != 1;

    /* ---- 2. cpu0 执行一条真正的 guest ldr 读代码页，把 bank 填上 ----
       不能用 hv_vmem_xfer：那是慢路径（memop），不经过 JIT 的 bank 探测，
       bank 是在 tlb_fill 里填的。只有 guest 真的 ldr 一次，才等价于
       "核 1 已经把这个块缓存进 bank 了" —— 也就是我们要设防的那个状态。 */
    c0.x[0] = (uint64_t)(uintptr_t)code;
    c0.x[2] = 0;
    if (run_at(&m, &c0, rstub, rstub + 1)) return 1;
#ifdef HV_BANK_SIZE
    printf("cpu0 data-read done     : x2 = %08x, bank_n = %u\n", (unsigned)c0.x[2], (unsigned)c0.bank_n);
#else
    printf("cpu0 data-read done     : x2 = %08x (BANK=0)\n", (unsigned)c0.x[2]);
#endif

    /* ---- 3. cpu1 写 code[0] = mov x0, #2（另一个 CPU 上下文的写） ---- */
    c1.x[0] = (uint64_t)(uintptr_t)code;
    c1.x[1] = INSN_MOV_X0_2;
    if (run_at(&m, &c1, wstub, wstub + 1)) return 1;
    printf("cpu1 wrote code[0]      : now %08x (want %08x)\n", code[0], INSN_MOV_X0_2);
    failures += code[0] != INSN_MOV_X0_2;

    /* ---- 4. cpu0 不 reset，再跑同一页：必须看到新指令 ---- */
    c0.x[0] = 0;
    if (run_at(&m, &c0, code, code + 1)) return 1;
    int second = (int)c0.x[0];
    printf("cpu0 second run (no rst): x0 = %d (want 2)\n", second);
    if (second != 2) {
        printf("  !! cross-CPU SMC not propagated: cpu0 reused a stale block\n");
        failures++;
    }

    /* ---- 5. 同一件事反过来：cpu1 自己执行，也要看到新代码 ---- */
    uint32_t new_insn = 0xd2800060u; /* mov x0, #3 */
    c0.x[0] = (uint64_t)(uintptr_t)code;
    c0.x[1] = new_insn;
    if (run_at(&m, &c0, wstub, wstub + 1)) return 1;
    {
        /* 写代码页必须留下痕迹：code_pages 被清、page_gen 递增、flush_smc 计数。
           这三条任何一条不成立，就说明写走了 JIT 快路径（绕过了 hv_phys_write），
           那 SMC 就会静默失效 —— 单核的 p_smc_nomaint 只覆盖了"同核写"这一种。 */
        HvRam *r = hv_ram_lookup(&m, (uint64_t)(uintptr_t)code);
        uint64_t pg = r ? ((uint64_t)(uintptr_t)code - r->pa) >> HV_TLB_PAGE_BITS : 0;
        unsigned cp = r ? r->code_pages[pg] : 0;
        printf("invariants after write  : code[0]=%08x code_pages=%u(0) page_gen=%u(>=2) smc=%llu\n",
               code[0], cp, r ? r->page_gen[pg] : 0, (unsigned long long)m.stats.flush_smc);
        failures += cp != 0;   /* 还留着 1 = 没作废 */
    }
    c1.x[0] = 0;
    if (run_at(&m, &c1, code, code + 1)) return 1;
    printf("cpu1 after cpu0's write : x0 = %d (want 3)\n", (int)c1.x[0]);
    failures += (int)c1.x[0] != 3;

#ifdef HV_BANK_SIZE
    printf("smc_mp: %d failures  (cpu0 bank_n=%u, cpu1 bank_n=%u)\n",
           failures, (unsigned)c0.bank_n, (unsigned)c1.bank_n);
#else
    printf("smc_mp: %d failures  (BANK=0 control)\n", failures);
#endif
    return failures != 0;
}
