/* 一级引导 + 自检（PID 1）。
 *
 * 两种运行方式，由内核命令行决定：
 *
 *   rdinit=/myinit root=/dev/nvme0n1p2   →  挂真实根分区、chroot、exec 真正的 init
 *   rdinit=/myinit                       →  不挂盘，跑内置自检（verify.sh / 基准）
 *
 * 为什么让 initramfs 承担"引导器"的角色：内核里的驱动必须是内建的（没有模块），
 * 而嵌入的 initramfs 又总会成为初始根。让它挂上真实根再切过去是标准做法；
 * 这里用 chroot 而不是 pivot_root，因为不需要卸载 initramfs，也不会卡在
 * "删除 initramfs 里的文件"这种细节上。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <errno.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/utsname.h>
#include <sys/wait.h>

static void dump(const char *path, int maxlines) {
    FILE *f = fopen(path, "r");
    if (!f) { printf("  (cannot open %s)\n", path); return; }
    char line[512];
    int n = 0;
    while (fgets(line, sizeof line, f) && n++ < maxlines) {
        line[strcspn(line, "\n")] = 0;
        if (*line) printf("  %s\n", line);
    }
    fclose(f);
}

/* 内核在 exec init 之前就要打开 /dev/console 给 init 当 stdin/stdout。
   initramfs 里没有这个节点时，内核会打印 "Warning: unable to open an initial
   console"，并把 0/1/2 留成无效 fd —— 之后 printf 全部丢弃。 */
static void claim_console(void) {
    mkdir("/dev", 0755);
    if (access("/dev/console", F_OK) != 0)
        mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1));
    int fd = open("/dev/console", O_RDWR);
    if (fd < 0) fd = open("/dev/ttyAMA0", O_RDWR);
    if (fd >= 0) {
        dup2(fd, 0); dup2(fd, 1); dup2(fd, 2);
        if (fd > 2) close(fd);
    }
}

/* base 之下的 proc/sys/dev/run/tmp。chroot 前后各调一次：
   伪文件系统是每个 mount namespace 各一份，chroot 之后原路径就不再可见。 */
static void mount_pseudo(const char *base) {
    char p[256];
    struct { const char *dir; const char *fstype; mode_t mode; } t[] = {
        {"proc", "proc", 0555}, {"sys", "sysfs", 0555}, {"dev", "devtmpfs", 0755},
        {"run", NULL, 0755}, {"tmp", NULL, 01777},
    };
    for (unsigned i = 0; i < sizeof t / sizeof *t; i++) {
        snprintf(p, sizeof p, "%s/%s", base, t[i].dir);
        mkdir(p, t[i].mode);
        if (t[i].fstype) mount(t[i].fstype, p, t[i].fstype, 0, NULL);
    }
}

static double mono(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

/* 纯寄存器/ALU 工作：直通翻译器应接近原生。 */
static double bench_alu(long iters) {
    unsigned long long a = 1, b = 3, c = 5, d = 7;
    double t0 = mono();
    for (long i = 0; i < iters; i++) {
        a = a * 6364136223846793005ull + 1442695040888963407ull;
        b ^= a >> 17; b += i;
        c += a ^ b; c = (c << 7) | (c >> 57);
        d -= c * 3 + b;
        a ^= d >> 11;
    }
    double t1 = mono();
    volatile unsigned long long sink = a ^ b ^ c ^ d;
    (void)sink;
    return (t1 - t0) * 1e9 / (double)iters;
}

/* 访存：软件 MMU 的代价在这里。 */
static double bench_mem(long iters) {
    static unsigned int arr[8192];
    for (int i = 0; i < 8192; i++) arr[i] = (unsigned)i * 2654435761u;
    unsigned long long acc = 0;
    double t0 = mono();
    for (long i = 0; i < iters; i++) {
        unsigned idx = (unsigned)(acc + (unsigned long long)i) & 8191u;
        unsigned v = arr[idx];
        arr[idx] = v + 1u;
        acc += v * 3u + 1u;
        acc ^= acc >> 7;
    }
    double t1 = mono();
    volatile unsigned long long sink = acc;
    (void)sink;
    return (t1 - t0) * 1e9 / (double)iters;
}

/* 从内核命令行取 key=value。 */
static int cmdline_value(const char *key, char *out, size_t n) {
    FILE *f = fopen("/proc/cmdline", "r");
    if (!f) return 0;
    char line[1024];
    int found = 0;
    if (fgets(line, sizeof line, f)) {
        size_t klen = strlen(key);
        line[strcspn(line, "\n")] = 0;   /* 先砍掉行尾换行，否则下面会死在行尾 */
        for (char *p = line; *p; ) {
            while (*p == ' ') p++;
            char *e = p;
            while (*e && *e != ' ') e++;
            if ((size_t)(e - p) > klen && !strncmp(p, key, klen) && p[klen] == '=') {
                size_t vlen = (size_t)(e - p) - klen - 1;
                if (vlen >= n) vlen = n - 1;
                memcpy(out, p + klen + 1, vlen);
                out[vlen] = 0;
                found = 1;
                break;
            }
            p = e;
        }
    }
    fclose(f);
    return found;
}

/* 只做到"根分区挂好、能 chroot"这一步就返回，供 fastboot 计时用。 */
static int boot_real_root_quiet(const char *rootdev, const char *initpath) {
    (void)initpath;
    const char *fstype = "ext4";
    mkdir("/newroot", 0755);
    if (mount(rootdev, "/newroot", fstype, MS_RDONLY, NULL) != 0) return -1;
    if (mount(rootdev, "/newroot", fstype, MS_REMOUNT, NULL) != 0) { }
    mount_pseudo("/newroot");
    if (chroot("/newroot") != 0) return -1;
    if (chdir("/") != 0) { }
    return 0;
}

/* 挂上真实根分区，chroot 进去，起真正的 init。成功则不返回。 */
static int boot_real_root(const char *rootdev, const char *initpath) {
    const char *fstype = getenv("HV_ROOTFS_O") ? getenv("HV_ROOTFS_O") : "ext4";
    dprintf(1, "[myinit] real root: device=%s fstype=%s init=%s\n", rootdev, fstype, initpath);
    dprintf(1, "[myinit] mounting %s ...\n", rootdev);

    mkdir("/newroot", 0755);
    if (mount(rootdev, "/newroot", fstype, MS_RDONLY, NULL) != 0) {
        printf("[myinit] mount %s (%s) failed: %s\n", rootdev, fstype, strerror(errno));
        printf("[myinit] /proc/partitions:\n");
        dump("/proc/partitions", 12);
        return -1;
    }
    /* 先只读挂上确认能读，再重挂读写：镜像有问题时只读更容易看清现场。 */
    if (mount(rootdev, "/newroot", fstype, MS_REMOUNT, NULL) != 0)
        printf("[myinit] remount rw failed (%s), continuing read-only\n", strerror(errno));
    else
        printf("[myinit] mounted rw\n");

    printf("[myinit] root looks like:\n");
    if (system("ls /newroot 2>/dev/null | head -20 | sed 's/^/    /'") != 0) { }
    if (system("cat /newroot/etc/os-release 2>/dev/null | head -3 | sed 's/^/    /'") != 0) { }

    mount_pseudo("/newroot");

    /* 把 initramfs 里准备好的验证脚本和基准程序拷进真实根，便于非交互验证。
       （交互登录也能做，只是从 adb 没法打字。） */
    {
        char cmd[512];
        snprintf(cmd, sizeof cmd,
                 "for f in /hvrun.sh /hvboot.sh; do "
                 "  [ -f $f ] && cp $f /newroot/tmp/$(basename $f) 2>/dev/null; "
                 "done; "
                 "chmod 755 /newroot/tmp/hvrun.sh /newroot/tmp/hvboot.sh 2>/dev/null; "
                 "[ -f /usr/bin/bench3 ] && cp /usr/bin/bench3 /newroot/tmp/bench3 2>/dev/null; "
                 "chmod 755 /newroot/tmp/bench3 2>/dev/null");
        if (system(cmd) != 0) { }
    }

    if (chroot("/newroot") != 0) {
        printf("[myinit] chroot failed: %s\n", strerror(errno));
        return -1;
    }
    if (chdir("/") != 0) { }

    char hvrun[128] = {0};
    /* 先把 hvrun 读出来再判断 —— 上一版把 strcmp 写在 cmdline_value 之前，
       那时 hvrun 还是空串，hvrun=boot 永远走不到开机计时脚本。 */
    int want_run = cmdline_value("hvrun", hvrun, sizeof hvrun);
    char script[64] = "/tmp/hvrun.sh";
    int boot_timing = want_run && !strcmp(hvrun, "boot");
    if (boot_timing) {
        /* 开机计时：systemd 必须真的是 PID 1（否则它起不来），
           所以 fork 一个监测子进程等它 ready 后关机，父进程照常 exec。 */
        printf("[myinit] boot timing: waiting for systemd, then poweroff\n");
        pid_t mon = fork();
        if (mon == 0) {
            /* 子进程：等 systemd 接管，再等它 running/degraded */
            for (int i = 0; i < 6000 && access("/run/systemd/system", F_OK) != 0; i++)
                usleep(10000);
            for (int i = 0; i < 6000; i++) {
                int rc = system("systemctl is-system-running 2>/dev/null | "
                                "grep -qE '^(running|degraded)$'");
                if (rc == 0) break;
                usleep(10000);
            }
            /* 报出客户机自己的 uptime，宿主那边的墙钟可交叉验证 */
            char up[64] = {0};
            FILE *f = fopen("/proc/uptime", "r");
            if (f) { if (fgets(up, sizeof up, f)) up[strcspn(up, " ")] = 0; fclose(f); }
            printf("\nSYSTEM_READY at uptime %s\n", up);
            fflush(stdout);
            sync();
            reboot(RB_POWER_OFF);
            _exit(0);
        }
    }
    printf("[myinit] chrooted, exec %s\n", want_run && !boot_timing ? script : initpath);
    const char *use_init = initpath;
    char *const run_argv[] = {(char *)"/bin/sh", script, NULL};
    if (want_run && !boot_timing) {
        /* hvrun=1：跑 /tmp/hvrun.sh 而不是普通 init（验证用） */
        char *const envp2[] = {
            (char *)"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            (char *)"HOME=/root", (char *)"TERM=linux", NULL,
        };
        execve("/bin/sh", run_argv, envp2);
        printf("[myinit] exec /bin/sh /tmp/hvrun.sh failed: %s\n", strerror(errno));
    }
    char *const argv[] = {(char *)use_init, NULL};
    char *const envp[] = {
        (char *)"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        (char *)"HOME=/root", (char *)"TERM=linux", (char *)"container=lxc", NULL,
    };
    execve(initpath, argv, envp);
    printf("[myinit] exec %s failed: %s\n", initpath, strerror(errno));
    return -1;
}

int main(void) {
    /* 裸 write：stdio 在这条路径上可能还在缓冲，先用最原始的方式确认自己起来了 */
    claim_console();
    setvbuf(stdout, NULL, _IONBF, 0);
    mkdir("/proc", 0555); mkdir("/sys", 0555); mkdir("/dev", 0755);
    mount("proc", "/proc", "proc", 0, NULL);
    mount("sysfs", "/sys", "sysfs", 0, NULL);
    mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);

    char rootdev[128] = {0}, initpath[128] = {0};
    int have_root = cmdline_value("root", rootdev, sizeof rootdev);
    if (!cmdline_value("init", initpath, sizeof initpath))
        snprintf(initpath, sizeof initpath, "/sbin/init");

    /* fastboot=1：只走启动路径，挂完根就关机。用来量"开机时间"，
       不含后面跑脚本的开销。 */
    if (have_root && strcmp(rootdev, "/dev/ram0") != 0) {
        char fb[16] = {0};
        if (cmdline_value("fastboot", fb, sizeof fb)) {
            if (boot_real_root_quiet(rootdev, initpath) == 0) { }
            printf("\n[myinit] FASTBOOT_DONE\n");
            sync();
            reboot(RB_POWER_OFF);
            for (;;) pause();
        }
    }
    if (have_root && strcmp(rootdev, "/dev/ram0") != 0) {
        if (boot_real_root(rootdev, initpath) == 0) { }
        printf("\n[myinit] booting the real root failed; falling back to the built-in self-check\n");
    }

    printf("\n");
    printf("+----------------------------------------------------------+\n");
    printf("|  guest userspace is alive: /myinit on PID 1 (static)     |\n");
    printf("+----------------------------------------------------------+\n");

    struct utsname u;
    if (uname(&u) == 0)
        printf("\nkernel: %s %s %s\nmachine: %s\n", u.sysname, u.release, u.version, u.machine);

    printf("\n/proc/cpuinfo (first 12 lines):\n");
    dump("/proc/cpuinfo", 12);
    printf("\n/proc/meminfo:\n");
    dump("/proc/meminfo", 3);
    printf("\n/proc/interrupts:\n");
    dump("/proc/interrupts", 8);
    printf("\n/proc/partitions:\n");
    dump("/proc/partitions", 10);

    printf("\ndevices bound:\n");
    {
        const char *names[] = {"/dev/ttyAMA0", "/dev/nvme0n1", "/dev/nvme0n1p1", "/dev/nvme0n1p2",
                               "/dev/vda", "/dev/rtc0", "/dev/mem"};
        for (unsigned k = 0; k < sizeof names / sizeof *names; k++)
            printf("  %-16s %s\n", names[k], access(names[k], F_OK) == 0 ? "present" : "-");
    }

    printf("\nbenchmarks (ns per iteration, lower is faster):\n");
    long n = 30000000;
    printf("  alu   (no memory)   %6.2f ns/iter\n", bench_alu(n));
    printf("  mem   (load+store)  %6.2f ns/iter\n", bench_mem(n));

    /* 有 Alpine 环境就交给动态链接的 busybox 跑更细的自检。 */
    if (access("/etc/verify.sh", F_OK) == 0) {
        printf("\nhanding over to /bin/sh (dynamic, musl):\n");
        pid_t p = fork();
        if (p == 0) {
            char *argv[] = {(char *)"sh", (char *)"/etc/verify.sh", NULL};
            char *envp[] = {(char *)"PATH=/sbin:/usr/sbin:/bin:/usr/bin",
                            (char *)"HOME=/", (char *)"TERM=linux", NULL};
            execve("/bin/sh", argv, envp);
            _exit(127);
        } else if (p > 0) {
            int st = 0;
            waitpid(p, &st, 0);
            printf("\n/bin/sh exited, status %d\n", WEXITSTATUS(st));
        }
    }

    printf("\nguest is shutting down via PSCI.\n");
    sync();
    reboot(RB_POWER_OFF);
    for (;;) pause();
    return 0;
}
