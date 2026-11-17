/* Linux aarch64 客户机的宿主入口（Android / Linux 宿主）。
 *
 * 对应原项目里的 host/main_mac.m + host/winvm.c，但把那两层里所有
 * Darwin 专有的东西（Cocoa、CoreFoundation、Metal 图层、os_unfair_lock、
 * CoreAudio、Jetsam ledger）全部去掉，只留"起 CPU、跑、收尸"这条主干。
 *
 * 用法：
 *   hv-linux --kernel Image [--ram 2048] [--cpus 4] [--disk root.img] [--stats]
 */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <ucontext.h>
#include <dlfcn.h>
#include <dlfcn.h>
#include <time.h>
#include <unistd.h>

#include "disk.h"
#include "dispatch.h"
#include "linuxvirt.h"
#include "net_passt_linux.h"
#include "net_slirp_linux.h"
#include "machine.h"

static HvMachine m;
static HvCpu cpus[HV_MAX_CPUS];
static HvWinVirt board;
static HvDisk disk0 = {.fd = -1};
static pthread_t sec_threads[HV_MAX_CPUS];
static int ncpus = 1;
static _Atomic int stop_requested;
static int net_on;
static int net_is_passt;   /* 1: passt（宿主内核 socket），0: slirp（用户态栈） */

/* 每个 tick 收一次网：两个后端的收帧都靠这个轮询推进。 */
static void board_poll(void) {
    if (!net_on) return;
    if (net_is_passt) hv_net_poll(); else slirp_hv_net_poll();
}

static void prepare_cpu_thread(void) {
    /* 大栈：翻译器在栈上有 Emit 这种几十 KB 的结构，而 hv_run 是深递归的入口 */
    static __thread int done;
    if (done) return;
    done = 1;
    sigset_t set;
    sigfillset(&set);
    sigdelset(&set, SIGSEGV);
    sigdelset(&set, SIGBUS);
    sigdelset(&set, SIGILL);
    sigdelset(&set, SIGTRAP);
    sigdelset(&set, SIGFPE);
    /* 别把终止信号也屏蔽掉：否则 `timeout`/Ctrl-C 都杀不掉这个进程，
       只能去设备上 pkill -9。 */
    sigdelset(&set, SIGTERM);
    sigdelset(&set, SIGINT);
    sigdelset(&set, SIGHUP);
    pthread_sigmask(SIG_BLOCK, &set, NULL);
}

static uint8_t *read_file(const char *path, size_t *out_size) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0) { close(fd); return NULL; }
    size_t n = (size_t)st.st_size;
    uint8_t *p = malloc(n);
    if (!p) { close(fd); return NULL; }
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, p + got, n - got);
        if (r <= 0) break;
        got += (size_t)r;
    }
    close(fd);
    *out_size = got;
    return p;
}

/* 收到 SIGTERM/SIGINT：让 hv_run 尽快退出。CPU 线程在主循环里被 kick 醒。 */
static void on_stop(int sig) {
    (void)sig;
    atomic_store(&stop_requested, 1);
    for (int i = 0; i < ncpus; i++) cpus[i].halted = 3;
    hv_machine_kick_all(&m);
}

/* 宿主收到致命信号时，说清楚"是翻译出来的代码炸了，还是引擎自己的 C 代码炸了"：
   host_pc 落在 JIT 区里就是前者，此时 guest_pc/sctlr 才是要看的。 */
static void on_fatal(int sig, siginfo_t *info, void *ctx) {
    ucontext_t *uc = ctx;
#if defined(__aarch64__)
    uint64_t hpc = uc->uc_mcontext.pc;
#else
    uint64_t hpc = 0;
#endif
    uint64_t rx = (uint64_t)(uintptr_t)m.jit.base;
    uint64_t size = (uint64_t)m.jit.capacity * 4;
    int in_jit = hpc >= rx && hpc < rx + size;
    fprintf(stderr, "\nhv-linux: fatal signal %d (%s) addr=%p host_pc=%#llx%s\n",
            sig, sig == SIGSEGV ? "SIGSEGV" : sig == SIGBUS ? "SIGBUS" : "SIGILL",
            info->si_addr, (unsigned long long)hpc, in_jit ? " [inside JIT]" : " [host C code]");
    {
        Dl_info di;
        if (!in_jit && dladdr((void *)(uintptr_t)hpc, &di) && di.dli_sname)
            fprintf(stderr, "  host symbol %s + %#llx (module base %p)\n", di.dli_sname,
                    (unsigned long long)(hpc - (uint64_t)(uintptr_t)di.dli_saddr), di.dli_fbase);
    }
    {
        Dl_info di;
        if (!in_jit && dladdr((void *)(uintptr_t)hpc, &di) && di.dli_sname)
            fprintf(stderr, "  host symbol %s + %#llx (module base %p)\n", di.dli_sname,
                    (unsigned long long)(hpc - (uint64_t)(uintptr_t)di.dli_saddr), di.dli_fbase);
    }
    {
        /* 故障指令前后 48 字节的机器码。有了它就能反汇编出"引擎到底生成了什么"，
           不用再从块号猜（块转储只有顺序，没有宿主地址）。 */
        uint64_t lo = (hpc - 48) & ~3ull, hi = (hpc + 16) & ~3ull;
        if (in_jit) {
            fprintf(stderr, "  jit words around fault:");
            for (uint64_t a = lo; a < hi; a += 4) {
                uint32_t w = *(const uint32_t *)(uintptr_t)a;
                fprintf(stderr, " %08x%s", w, a == (hpc & ~3ull) ? "<--" : "");
            }
            fprintf(stderr, "\n");
            FILE *fp = fopen("/data/local/tmp/jitfault.bin", "wb");
            if (fp) { fwrite((const void *)(uintptr_t)lo, 1, hi - lo, fp); fclose(fp); }
            fprintf(stderr, "  (saved %llu bytes at offset %#llx into /data/local/tmp/jitfault.bin)\n",
                    (unsigned long long)(hi - lo), (unsigned long long)(lo - rx));
        }
    }
#if defined(__aarch64__)
    /* 故障那一刻的真实寄存值。翻译出来的访存是 va + addend：
       x6 = guest VA，x15 = 该页的 addend，两者相加就是它要碰的宿主地址。 */
    fprintf(stderr, "  regs: x6(va)=%#llx x15(addend)=%#llx sum=%#llx | x25=%#llx x26=%#llx x28(cpu)=%#llx\n",
            (unsigned long long)uc->uc_mcontext.regs[6],
            (unsigned long long)uc->uc_mcontext.regs[15],
            (unsigned long long)(uc->uc_mcontext.regs[6] + uc->uc_mcontext.regs[15]),
            (unsigned long long)uc->uc_mcontext.regs[25],
            (unsigned long long)uc->uc_mcontext.regs[26],
            (unsigned long long)uc->uc_mcontext.regs[28]);
#endif
    {
        /* 把故障地址对应的 TLB 表项直接打出来：命中了哪张表、tag、addend。 */
        HvCpu *c = &cpus[0];
        uint64_t va = c->x[25] + 0x980;
        fprintf(stderr, "  x25=%#llx x0=%#llx -> probe va=%#llx\n",
                (unsigned long long)c->x[25], (unsigned long long)c->x[0], (unsigned long long)va);
        uint32_t idx = (uint32_t)((va >> 12) & (HV_TLB_SIZE - 1));
        for (int t = 0; t < 4; t++) {
            HvTlbEntry *e = &c->tlb[(size_t)t * HV_TLB_SIZE + idx];
            fprintf(stderr, "    table %d: tag=%#llx addend=%#llx -> host=%#llx %s\n", t,
                    (unsigned long long)e->read_tag, (unsigned long long)e->addend,
                    (unsigned long long)(va + e->addend),
                    ((va - e->read_tag) >> HV_TLB_PAGE_BITS) == 0 ? "HIT" : "");
        }
    }
    for (int i = 0; i < ncpus; i++)
        fprintf(stderr, "  cpu %d: guest_pc=%#llx el=%u sctlr=%#llx far=%#llx ttbr0=%#llx\n",
                i, (unsigned long long)cpus[i].pc, cpus[i].el,
                (unsigned long long)cpus[i].sctlr_el1, (unsigned long long)cpus[i].far_el1,
                (unsigned long long)cpus[i].ttbr0_el1);
    fflush(stderr);
    _exit(128 + sig);
}

/* TLB 不变式审计。
   tlb_fill 是唯一写 addend 的地方，它对"真在 RAM 里的页"算出的值不可能为 0；
   所以一旦看到"tag 有效、addend 为 0"或"算出的宿主地址不落在任何一块客机 RAM
   里"，就说明表项被某条路径弄坏了。这正是 0.183 s 崩溃的表象。
   不开 HV_TLB_AUDIT 时不编译进去。 */
static int tlb_entry_live(const HvTlbEntry *e) {
    return e->read_tag != HV_TLB_INVALID || e->write_tag != HV_TLB_INVALID || e->exec_tag != HV_TLB_INVALID;
}

static void audit_tlb(HvCpu *c) {
    static int warned;
    int bad = 0;
    for (int t = 0; t < 4 && bad < 4; t++)
        for (uint32_t slot = 0; slot < HV_TLB_SIZE && bad < 4; slot++) {
            const HvTlbEntry *e = &c->tlb[(size_t)t * HV_TLB_SIZE + slot];
            if (!tlb_entry_live(e)) continue;
            uint64_t tag = e->read_tag != HV_TLB_INVALID ? e->read_tag + HV_TLB_ADJ
                         : e->write_tag != HV_TLB_INVALID ? e->write_tag + HV_TLB_ADJ : 0;
            if (!tag) continue; /* only an exec tag: its key hides the VA, skip */
            int ok = 0;
            uint64_t host = tag + (uint64_t)e->addend;
            for (int r = 0; r < c->m->nram; r++) {
                uint64_t base = (uint64_t)(uintptr_t)c->m->ram[r].host;
                if (host - base < c->m->ram[r].size) ok = 1;
            }
            if (ok) continue;
            if (!warned) {
                warned = 1;
                fprintf(stderr, "\n[audit] BAD TLB ENTRY: table %d slot %u\n"
                                "        read_tag=%#llx write_tag=%#llx exec_tag=%#llx\n"
                                "        addend=%#llx  page_va=%#llx  -> host %#llx  (not in any guest RAM)\n",
                        t, slot, (unsigned long long)e->read_tag, (unsigned long long)e->write_tag,
                        (unsigned long long)e->exec_tag, (unsigned long long)e->addend,
                        (unsigned long long)tag, (unsigned long long)host);
            }
            bad++;
        }
    (void)bad;
}

/* 1 ms kicker：对应原项目 host/winvm.c:215 的 kicker_thread。
   为什么必须有它：dispatch.c 的 tick 调用条件是
       kicked || (N 个块之后 && next_due && now >= next_due)
   而 next_due 是上一次 tick 返回的下一个截止时间——guest 把定时器关掉的那一刻
   它返回 0，此后 "next_due &&" 恒假，**再也不会调用 tick**。
   Linux 的 clockevent 在启动期会反复 arm/disarm（从 dummy 切到 arch_timer），
   于是定时器中断就此断流，jiffies 冻结，内核在 lib/raid6/algos.c:177 的
   `while ((j1 = jiffies) == j0) cpu_relax();` 上永远自旋。
   实测 jiffies 停在 0xfffedb10 = 启动后 56 个 tick（250 Hz）≈ 0.224 s，
   和串口日志停下的位置完全吻合。
   有 kicker 之后每次 kick 都会走一遍 tick，定时器重新被看见。 */
static void *kicker_thread(void *unused) {
    (void)unused;
    while (!atomic_load_explicit(&stop_requested, memory_order_relaxed)) {
        usleep(1000);
        hv_machine_kick_all(&m);
    }
    return NULL;
}

/* 看门狗：每秒打一次 CPU0 的 guest PC。内核静默卡住时，看 PC 是在同一个
   地址上空转还是缓慢前进，比看串口有没有输出有用得多。 */
static void *watchdog_thread(void *unused) {
    (void)unused;
    const char *on = getenv("HV_WATCHDOG");
    if (!on || !*on || *on == '0') return NULL;
    uint64_t last = 0;
    for (;;) {
        struct timespec ts = {1, 0};
        nanosleep(&ts, NULL);
        if (atomic_load(&stop_requested)) return NULL;
        uint64_t pc = cpus[0].pc;
        fprintf(stderr, "[watchdog] pc=%#llx el=%u ttbr0=%#llx ttbr1=%#llx %s\n",
                (unsigned long long)pc, cpus[0].el,
                (unsigned long long)cpus[0].ttbr0_el1, (unsigned long long)cpus[0].ttbr1_el1,
                pc == last ? "(same)" : "");
        if (getenv("HV_TLB_AUDIT")) audit_tlb(&cpus[0]);
        last = pc;
    }
}

/* 每个 vCPU 都要一个大栈。
   原因有两条，都是这台机器上量出来的：
     1. translate.c 的 Emit 是 static __thread，约 0.36 MB（hot/cold 各 128 KB、
        rel 96 KB、pool 40 KB、ool 56 KB、site 48 KB）。bionic 把 TLS 放在
        栈区下方，于是这部分直接从栈里扣。
     2. hv_run 是递归入口，helper 路径还叠在它上面。
   Android 默认 pthread 栈约 1 MB，扣掉 TLS 只剩 0.6 MB —— 表现为随机位置
   的 SIGSEGV、PC 落在 JIT 里、崩得早晚随 HV_SLOW_MEM 这类开关变。
   原项目 winvm.c 里两处都显式 setstacksize(8 MB)，移植时漏了。 */
#define HV_VCPU_STACK (16u << 20)

static pthread_attr_t cpu_attr(void) {
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setstacksize(&a, HV_VCPU_STACK);
    return a;
}

/* 副 vCPU 的线程体：PSCI CPU_ON 把 off 清掉后它就从 entry 开始跑。 */
static void *secondary_thread_entry(void *arg) {
    HvCpu *c = arg;
    prepare_cpu_thread();
    hv_run(c);
    return NULL;
}

static void usage(const char *argv0) {
    fprintf(stderr,
            "usage: %s --kernel <Image> [options]\n"
            "  --kernel PATH   aarch64 Linux Image (uncompressed)\n"
            "  --ram MB        guest RAM in MB (default 2048)\n"
            "  --cpus N        vCPUs (default 1, max %d)\n"
            "  --disk PATH     raw image for the NVMe controller\n"
            "  --jit MB        translation cache size (default 256)\n"
            "  --stats         print engine statistics periodically\n"
#ifdef HV_LINMAP
            "  --linmap GB,LEN,PA  on-demand linear-map window (up to 2).\n"
            "                  Asserts guest VA [GB, GB+LEN) == host+pa(PA).\n"
            "                  e.g. Linux arm64: --linmap 0xffff000000000000,0x80000000,0\n"
            "                  Only EL1 data reads use it; omit it and nothing changes.\n"
#endif
            ,
            argv0, HV_MAX_CPUS);
}

/* CPU0 也跑在自己的线程上：main 线程的栈大小不由我们决定（Android 上通常
   1 MB 左右），而 hv_run 需要大栈——见 HV_VCPU_STACK 的说明。 */
static void *cpu0_thread(void *unused) {
    (void)unused;
    prepare_cpu_thread();
    for (;;) {
        hv_run(&cpus[0]);
        if (cpus[0].halted == 2) { /* PSCI SYSTEM_RESET */
            fprintf(stderr, "hv-linux: guest asked for PSCI SYSTEM_RESET\n");
            break;
        }
        if (cpus[0].halted) break;
        if (atomic_load(&stop_requested)) break;
    }
    atomic_store(&stop_requested, 1);
    return NULL;
}

int main(int argc, char **argv) {
    const char *kernel_path = NULL, *disk_path = NULL;
    int want_stats = 0;   /* hv_machine_init 会 memset 整个 m，所以先记住意图 */
#ifdef HV_LINMAP
    /* 同样要记住意图：memset 会把 HvMachine 里的 linmap 清掉 */
    struct { uint64_t base, len, pa; } linmap[2];
    int linmap_n = 0;
#endif
    uint64_t ram_mb = 2048;
    size_t jit_mb = 256;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--kernel") && i + 1 < argc) kernel_path = argv[++i];
        else if (!strcmp(argv[i], "--ram") && i + 1 < argc) ram_mb = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--cpus") && i + 1 < argc) ncpus = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--disk") && i + 1 < argc) disk_path = argv[++i];
        else if (!strcmp(argv[i], "--jit") && i + 1 < argc) jit_mb = (size_t)strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--stats")) want_stats = 1;
#ifdef HV_LINMAP
#ifdef HV_LINMAP
        else if (!strcmp(argv[i], "--linmap") && i + 1 < argc) {
            /* --linmap <guest_base>,<len>,<pa_base>   （都可用 0x 十六进制）
               按需开启的 linear-map 通道：告诉引擎"这段 guest VA 恒等于 host+delta"。
               引擎不猜、不探、不学 —— 不给这个参数就一条指令都不多发。
               责任在配置者：[base, base+len) 内必须全部已映射且满足 host = va + delta。 */
            if (linmap_n < 2) {
                char *s = argv[++i];
                char *e1 = strchr(s, ',');
                char *e2 = e1 ? strchr(e1 + 1, ',') : NULL;
                if (!e1 || !e2) { usage(argv[0]); return 1; }
                linmap[linmap_n].base = strtoull(s, NULL, 0);
                linmap[linmap_n].len = strtoull(e1 + 1, NULL, 0);
                /* 第三段是 guest 物理地址（不是 delta）：delta 取决于运行时分配的
                   宿主 RAM 指针，命令行给不出来。引擎自己算：
                     host(pa_base) - guest_base  ==  ram->host + (pa_base - ram->pa) - guest_base */
                linmap[linmap_n].pa = strtoull(e2 + 1, NULL, 0);
                if (linmap[linmap_n].len) linmap_n++;
            }
        }
#endif
#endif
        else { usage(argv[0]); return 1; }
    }
    if (!kernel_path) { usage(argv[0]); return 1; }
    if (ncpus < 1) ncpus = 1;
    if (ncpus > HV_MAX_CPUS) ncpus = HV_MAX_CPUS;

    signal(SIGPIPE, SIG_IGN);
    {
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_sigaction = on_fatal;
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigaction(SIGSEGV, &sa, NULL);
        sigaction(SIGBUS, &sa, NULL);
        sigaction(SIGILL, &sa, NULL);
    }
    signal(SIGTERM, on_stop);
    signal(SIGINT, on_stop);
    signal(SIGHUP, on_stop);
    setvbuf(stderr, NULL, _IOLBF, 0);

    size_t ksize = 0;
    uint8_t *kernel = read_file(kernel_path, &ksize);
    if (!kernel) {
        fprintf(stderr, "hv-linux: cannot read kernel %s: %s\n", kernel_path, strerror(errno));
        return 1;
    }
    /* arm64 裸 Image 的前 4 字节是一条跳转指令（不是 0x7f ELF）；若给的是 ELF 就报清楚 */
    if (ksize > 4 && kernel[0] == 0x7f && kernel[1] == 'E') {
        fprintf(stderr, "hv-linux: %s looks like an ELF, not a raw arm64 Image "
                        "(use arch/arm64/boot/Image)\n", kernel_path);
        return 1;
    }
    /* arm64 Image 头：offset 8 是 text_offset，加载器应当honoring它；
       现代内核一般写 0（表示"2MB 对齐、RAM 前 512MB 内任意位置"），
       老内核写 0x80000。这里按 QEMU 的做法取它，越界就退回 0x80000。 */
    uint64_t text_offset = 0;
    if (ksize >= 64) {
        memcpy(&text_offset, kernel + 8, 8);
        text_offset = __builtin_bswap64(text_offset); /* 头是大端 */
        if (text_offset > (ram_mb << 20) / 2) text_offset = 0; /* 不合理就丢弃 */
    }
    fprintf(stderr, "hv-linux: kernel %s, %zu bytes, text_offset %#llx\n",
            kernel_path, ksize, (unsigned long long)text_offset);

    HvDisk *d = NULL;
    if (disk_path) {
        if (hv_disk_open(&disk0, disk_path, 0, 0) != 0) {
            fprintf(stderr, "hv-linux: cannot open disk %s\n", disk_path);
            return 1;
        }
        d = &disk0;
    }

    int r = hv_machine_init(&m, jit_mb << 20);
    if (r != 0) {
        fprintf(stderr, "hv-linux: cannot create JIT region (%zu MB)\n", jit_mb);
        return 1;
    }
    m.log = getenv("HV_LOG") ? atoi(getenv("HV_LOG")) : 0;
    /* 必须放在 hv_machine_init 之后：那里 memset(m, 0, sizeof *m) 会把早先设的
       stats_interval 清掉，导致 --stats 完全没效果（也是我之前看不到启动统计的原因）。

       HV_SUM 也要开：分类计数器（slow_why/kind_insns/bank_fills/bank_inv_*）全都挂在
       `if (m->stats_interval)` 上，所以只给 HV_SUM 不带 --stats 会拿到一排 0 ——
       我已经被这个坑过一次（knee 跑出 fills=0）。这里给一个极大的间隔，
       等于"只计数不打印"。 */
    if (want_stats) m.stats_interval = 1;
    else if (getenv("HV_SUM")) m.stats_interval = 999999;

    static const uint8_t mac[6] = {0x02, 0x48, 0x56, 0x4c, 0x4e, 0x01};
    if (hv_linuxvirt_create(&board, &m, cpus, ncpus, ram_mb << 20, kernel, ksize, text_offset, d, mac) != 0) {
        fprintf(stderr, "hv-linux: board creation failed\n");
        return 1;
    }
    free(kernel);

#ifdef HV_LINMAP
    /* 把 --linmap 的 (guest_base, len, pa_base) 换成引擎要的 delta。
       delta = host(pa_base) - guest_base，而 host(pa_base) 只有 RAM 建好才知道。
       找不到覆盖 pa_base 的 RAM 就拒绝配置（宁可不加速，不要加速错）。 */
    for (int i = 0; i < linmap_n; i++) {
        HvRam *r = hv_ram_lookup(&m, linmap[i].pa);
        if (!r || linmap[i].pa < r->pa || linmap[i].pa - r->pa >= r->size) {
            fprintf(stderr, "hv-linux: --linmap #%d: pa_base 0x%llx 不在任何 RAM 里，忽略\n",
                    i, (unsigned long long)linmap[i].pa);
            continue;
        }
        if (linmap[i].len > r->size - (linmap[i].pa - r->pa)) {
            fprintf(stderr, "hv-linux: --linmap #%d: len 0x%llx 超出 RAM 尾部，截断\n",
                    i, (unsigned long long)linmap[i].len);
            linmap[i].len = r->size - (linmap[i].pa - r->pa);
        }
        m.linmap[m.nlinmap].base = linmap[i].base;
        m.linmap[m.nlinmap].len = linmap[i].len;
        m.linmap[m.nlinmap].delta = (int64_t)((uintptr_t)(r->host + (linmap[i].pa - r->pa)) - linmap[i].base);
        fprintf(stderr, "hv-linux: linmap #%d: va [0x%llx, +0x%llx) -> pa 0x%llx, delta %+lld\n",
                m.nlinmap, (unsigned long long)linmap[i].base, (unsigned long long)linmap[i].len,
                (unsigned long long)linmap[i].pa, (long long)m.linmap[m.nlinmap].delta);
        m.nlinmap++;
    }
#endif

    /* 接上用户态 NAT（libslirp）。没有这一步 virtio-net 只是个空壳：
       链路状态是 up，但没有任何东西在网线另一头。 */
    if (board.net) {
        /* 默认 slirp：它是当前唯一吞吐正常的后端（10.6 MB/s，apt 装 gcc 成功）。
           HV_NET=passt 显式启用 passt——它用宿主内核的原生 socket、少一层协议栈，
           已经能完成 DHCP/DNS/HTTP，但传输收尾会卡住（见 FINDINGS.md 第八节），
           所以在修好之前不放默认。 */
        const char *pick = getenv("HV_NET");
        int want_passt = pick && !strcmp(pick, "passt");
        if (want_passt && hv_net_attach(&m, board.net) == 0) {
            net_on = 1; net_is_passt = 1;
        } else if (slirp_hv_net_attach(&m, board.net) == 0) {
            if (want_passt) fprintf(stderr, "hv-linux: passt unavailable, fell back to slirp\n");
            net_on = 1; net_is_passt = 0;
        } else {
            fprintf(stderr, "hv-linux: no network backend available\n");
        }
    }
    board.poll = board_poll;   /* tick 里会调它，网络靠这个推进 */
    hv_linuxvirt_reset_cpu(&board, LINUXVIRT_RAM_PA + text_offset);

    fprintf(stderr, "hv-linux: base=%#llx\n", (unsigned long long)(uintptr_t)&main);
    fprintf(stderr, "hv-linux: %d vCPU, %llu MB RAM, jit %zu MB, entering kernel at %#llx, dtb %#llx\n",
            ncpus, (unsigned long long)ram_mb, jit_mb,
            (unsigned long long)(LINUXVIRT_RAM_PA + text_offset),
            (unsigned long long)(LINUXVIRT_RAM_PA + 0x08000000ULL));

    pthread_attr_t attr = cpu_attr();
    for (int i = 1; i < ncpus; i++) pthread_create(&sec_threads[i], &attr, secondary_thread_entry, &cpus[i]);
    for (int i = 1; i < ncpus; i++) pthread_detach(sec_threads[i]);

    { pthread_t wd; if (pthread_create(&wd, NULL, watchdog_thread, NULL) == 0) pthread_detach(wd); }
    { pthread_t kt; if (pthread_create(&kt, NULL, kicker_thread, NULL) == 0) pthread_detach(kt); }

    pthread_t c0;
    if (pthread_create(&c0, &attr, cpu0_thread, NULL) != 0) {
        fprintf(stderr, "hv-linux: cannot start the vCPU thread\n");
        return 1;
    }
    pthread_attr_destroy(&attr);
    pthread_join(c0, NULL); /* 等它自己停：halted 或 stop_requested */

    for (int i = 0; i < ncpus; i++) cpus[i].halted = 3;
    hv_machine_kick_all(&m);
    if (net_on) { /* slirp 随进程退出清理即可 */ }

    if (disk0.fd >= 0) hv_disk_sync(&disk0);

    /* 退出时把关键计数器打出来。
       要回答"启动时到底执行了多少代码、放大成多少宿主指令"，
       这两个数就够了：translated_insns 是跑过的客机指令数，
       translated_words 是为它们生成的宿主指令数（比值即"翻译放大比"）。 */
    if (getenv("HV_SUM")) {
        HvStats *st = &m.stats;
        double amp = st->translated_insns ? (double)st->translated_words / (double)st->translated_insns : 0;
        fprintf(stderr,
                "\n[sum] guest_insns=%llu  host_words=%llu  amplification=%.2fx\n"
                "[sum] blocks_dispatched=%llu  translations=%llu  avg_block_insns=%.1f\n"
                "[sum] inline_words=%llu ool_words=%llu pool_words=%llu\n"
                "[sum] tlb_refills=%llu  slow_accesses=%llu  fetch_walks=%llu\n"
                "[sum] chained=%llu  ijc_fills=%llu  dispatcher_entries=%llu\n"
                "[sum] why[cache-fill,kick,exc,irq,cached-target,miss]=%llu,%llu,%llu,%llu,%llu,%llu\n"
#ifdef HV_PMD_SIZE
                "[sum] pmd: lookups=%llu hits=%llu fills=%llu  (large_fills=%llu)\n"
#endif
#ifdef HV_BANK_SIZE
                "[sum] bank: fills=%llu  refills=%llu   (三桶用差值法, 见 MEASURE.md)\n"
                "[sum] bank inv: on_switch=%llu  switch_user_calls=%llu\n"
                "[sum] fill by EL: el0=%llu el1=%llu el1pan=%llu   bank fills: el0=%llu el1=%llu el1pan=%llu\n"
                "[sum] fill by EL: el0=%llu el1=%llu el1pan=%llu   bank fills: el0=%llu el1=%llu el1pan=%llu\n"
#endif
                "[sum] translate_time=%.2fs\n",
                (unsigned long long)st->translated_insns, (unsigned long long)st->translated_words, amp,
                (unsigned long long)st->blocks, (unsigned long long)st->translations,
                st->translations ? (double)st->translated_insns / (double)st->translations : 0,
                (unsigned long long)st->words_inline, (unsigned long long)st->words_ool,
                (unsigned long long)st->words_pool,
                (unsigned long long)st->refills,
                (unsigned long long)(st->slow_why[0]+st->slow_why[1]+st->slow_why[2]+st->slow_why[3]+st->slow_why[4]+st->slow_why[5]),
                (unsigned long long)st->fetch_walks,
                (unsigned long long)st->chained, (unsigned long long)st->ijc_fills,
                (unsigned long long)st->blocks,
                (unsigned long long)st->why[0], (unsigned long long)st->why[1],
                (unsigned long long)st->why[2], (unsigned long long)st->why[3],
                (unsigned long long)st->why[4], (unsigned long long)st->why[5],
#ifdef HV_PMD_SIZE
                (unsigned long long)st->pmd_lookups, (unsigned long long)st->pmd_hits,
                (unsigned long long)st->pmd_fills, (unsigned long long)st->large_fills,
#endif
#ifdef HV_BANK_SIZE
                (unsigned long long)st->bank_fills, (unsigned long long)st->refills,
                (unsigned long long)st->bank_inv_switch, (unsigned long long)st->switch_user,
                (unsigned long long)st->fill_el[0], (unsigned long long)st->fill_el[1],
                (unsigned long long)st->fill_el[2],
                (unsigned long long)st->bank_fill_el[0], (unsigned long long)st->bank_fill_el[1],
                (unsigned long long)st->bank_fill_el[2],
                (unsigned long long)st->fill_el[0], (unsigned long long)st->fill_el[1],
                (unsigned long long)st->fill_el[2],
                (unsigned long long)st->bank_fill_el[0], (unsigned long long)st->bank_fill_el[1],
                (unsigned long long)st->bank_fill_el[2],
#endif
                (double)st->translate_ticks / 24e6);
#ifdef HV_PROF
        if (st->prof_n) {
            double n = (double)st->prof_n;
            const char *nm[7] = {"A walk", "D1 fill-pre", "C entry-write", "B1 write_guard/whint",
                                 "B2 write_guard/fence", "D3 bloom+ret", "call overhead"};
            uint64_t tot = 0;
            for (int i = 0; i < 7; i++) tot += st->prof_sum[i];
            double base = (double)st->prof_sum[7] / n;   /* mrs 读取延迟基线 */
            fprintf(stderr, "[prof] refills=%llu  ticks/refill=%.2f  (1 tick=77ns)"
                            "  baseline-per-sample=%.2f tick (=%.1f ns, 已从各段扣除)\n",
                    (unsigned long long)st->prof_n, (double)tot / n, base, base * 76.923);
            for (int i = 0; i < 7; i++) {
                double t = (double)st->prof_sum[i] / n - base;
                if (t < 0) t = 0;
                fprintf(stderr, "[prof]   %-22s %7.2f tick  %6.1f ns  %5.1f%%\n", nm[i],
                        t, t * 76.923, tot ? 100.0 * t / ((double)tot / n - 7 * base) : 0.0);
            }
        }
#endif
    }
    fprintf(stderr, "hv-linux: stopped, guest pc=%#llx el=%u halted=%u\n",
            (unsigned long long)cpus[0].pc, cpus[0].el, cpus[0].halted);
    return 0;
}
