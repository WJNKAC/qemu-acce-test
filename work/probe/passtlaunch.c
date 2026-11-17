/*
 * passtlaunch - 用一个 socketpair 把 passt 和 QEMU 接起来，两边都不 bind
 *
 * 为什么需要它（两次失败的方案，别重复）：
 *
 *   方案 A（-netdev stream + passt --socket <path>）：
 *     adb shell 域 bind 目录 socket 被 SELinux 拒：
 *       Failed to bind UNIX domain socket: Permission denied
 *     连 abstract socket（@name）也被拒 —— 是域策略，不是路径问题。
 *
 *   方案 B（搬到 Termux 域，那边能 bind）：
 *     Termux 域 Seccomp=2（app 域），passt 启动即 SIGSYS，且 --help/--version
 *     都是 0 字节输出就死 —— 死在 bionic 启动序列，不是业务路径。
 *     静态链接也不行（bionic 静态链接受限）。
 *
 *   方案 C（本程序）：
 *     socketpair(AF_UNIX, SOCK_STREAM) 不需要 bind、不碰文件系统，
 *     adb shell 域实测可用（见 work/probe/sptest.c）。
 *     passt 侧用 -F/--fd 「Use FD as pre-opened connected socket」，
 *     QEMU 侧用 -netdev socket,fd=N（monitor/fds.c:499 对纯数字直接当 fd 用）。
 *     两个子进程同域（Seccomp=0），两个障碍同时消失。
 *
 * 用法：
 *   passtlaunch [passt 命令...] -- [qemu 命令...]
 *
 *   两条命令里的 %PFD% 会被替换成 passt 那端的 fd 号，
 *   %QFD% 替换成 QEMU 那端。例如：
 *
 *   passtlaunch \
 *     ./passt -f -q -F %PFD% -- \
 *     ./q-p0a8 -M virt ... -netdev socket,id=n0,fd=%QFD% -device virtio-net-pci,netdev=n0
 *
 * 为什么用固定 fd 号（20/21）而不是 socketpair 直接给的 3/4：
 *   命令行里要写死一个数字，所以必须先 dup2 到确定的位置。
 *   launcher 刚启动时只有 0/1/2 被占，socketpair 给 3/4，20/21 一定是空的。
 *   dup2 出来的 fd 不带 FD_CLOEXEC（dup2 会清掉），exec 后仍然有效。
 *
 * 退出语义：
 *   任一子进程退出 → 杀掉另一个 → 返回退出者的状态。
 *   "passt 先死"和"QEMU 先死"要能分辨，所以打印是谁先退的。
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define PASST_FD 20
#define QEMU_FD  21

static pid_t g_passt = -1;
static pid_t g_qemu = -1;

static void forward_signal(int sig)
{
    if (g_passt > 0)
        kill(g_passt, sig);
    if (g_qemu > 0)
        kill(g_qemu, sig);
}

/* 把 argv 里的 tok 换成 val，返回新分配的 NULL 结尾数组（浅拷贝字符串） */
static char **subst(char **argv, int n, const char *tok, const char *val)
{
    char **out = calloc((size_t)n + 1, sizeof *out);
    int i;

    if (!out)
        return NULL;
    for (i = 0; i < n; i++) {
        if (strstr(argv[i], tok)) {
            /* 只做一次替换，够用；多次出现属于用法错误 */
            const char *p = strstr(argv[i], tok);
            size_t head = (size_t)(p - argv[i]);
            size_t tail = strlen(p + strlen(tok));
            char *s = malloc(head + strlen(val) + tail + 1);
            if (!s) {
                free(out);
                return NULL;
            }
            memcpy(s, argv[i], head);
            memcpy(s + head, val, strlen(val));
            memcpy(s + head + strlen(val), p + strlen(tok), tail + 1);
            out[i] = s;
        } else {
            out[i] = strdup(argv[i]);
        }
    }
    return out;
}

static void free_argv(char **v)
{
    int i;

    if (!v)
        return;
    for (i = 0; v[i]; i++)
        free(v[i]);
    free(v);
}

/* 子进程里：只留需要的那个 socket fd，其余关掉，然后 exec */
static void child_run(char **argv, int keep_fd, int drop_fd)
{
    if (drop_fd >= 0 && drop_fd != keep_fd)
        close(drop_fd);
    /* keep_fd 必须跨 exec 存活。dup2 已经清掉 CLOEXEC，这里再确认一次，
       因为如果它恰好来自 socketpair 的原 fd（不是 dup2 出来的），
       某些 libc 可能带上了 CLOEXEC。 */
    {
        int fl = fcntl(keep_fd, F_GETFD);
        if (fl >= 0)
            fcntl(keep_fd, F_SETFD, fl & ~FD_CLOEXEC);
    }
    execvp(argv[0], argv);
    fprintf(stderr, "passtlaunch: exec %s failed: %s\n", argv[0], strerror(errno));
    _exit(127);
}

int main(int argc, char **argv)
{
    int sv[2];
    int sep = -1;
    int i;
    char pfd_s[16], qfd_s[16];
    char **passt_argv = NULL, **qemu_argv = NULL;
    struct sigaction sa;
    int status = 0;
    pid_t who;

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--")) {
            sep = i;
            break;
        }
    }
    if (sep < 1 || sep == argc - 1) {
        fprintf(stderr,
                "usage: passtlaunch [passt cmd...] -- [qemu cmd...]\n"
                "       %%PFD%% and %%QFD%% are replaced with the fd numbers\n");
        return 2;
    }

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
        fprintf(stderr, "passtlaunch: socketpair: %s\n", strerror(errno));
        return 3;
    }

    /* 两段各持一端，dup2 到固定号，然后释放原始的 3/4 */
    if (dup2(sv[0], PASST_FD) < 0 || dup2(sv[1], QEMU_FD) < 0) {
        fprintf(stderr, "passtlaunch: dup2: %s\n", strerror(errno));
        return 3;
    }
    if (sv[0] != PASST_FD && sv[0] != QEMU_FD)
        close(sv[0]);
    if (sv[1] != PASST_FD && sv[1] != QEMU_FD)
        close(sv[1]);

    snprintf(pfd_s, sizeof pfd_s, "%d", PASST_FD);
    snprintf(qfd_s, sizeof qfd_s, "%d", QEMU_FD);

    passt_argv = subst(argv + 1, sep - 1, "%PFD%", pfd_s);
    qemu_argv = subst(argv + sep + 1, argc - sep - 1, "%QFD%", qfd_s);
    if (!passt_argv || !qemu_argv) {
        fprintf(stderr, "passtlaunch: out of memory\n");
        return 3;
    }

    memset(&sa, 0, sizeof sa);
    sa.sa_handler = forward_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP, &sa, NULL);
    signal(SIGPIPE, SIG_IGN);

    fprintf(stderr, "passtlaunch: passt fd=%d, qemu fd=%d\n", PASST_FD, QEMU_FD);

    g_passt = fork();
    if (g_passt < 0) {
        fprintf(stderr, "passtlaunch: fork passt: %s\n", strerror(errno));
        return 3;
    }
    if (g_passt == 0)
        child_run(passt_argv, PASST_FD, QEMU_FD);

    /* passt 先起：QEMU 连过来时对端必须已经在读，否则 TCP 握手可能丢 */
    usleep(300 * 1000);

    g_qemu = fork();
    if (g_qemu < 0) {
        fprintf(stderr, "passtlaunch: fork qemu: %s\n", strerror(errno));
        kill(g_passt, SIGKILL);
        return 3;
    }
    if (g_qemu == 0)
        child_run(qemu_argv, QEMU_FD, PASST_FD);

    {
        int fl = fcntl(PASST_FD, F_GETFD);
        if (fl >= 0)
            fcntl(PASST_FD, F_SETFD, fl | FD_CLOEXEC);
        fl = fcntl(QEMU_FD, F_GETFD);
        if (fl >= 0)
            fcntl(QEMU_FD, F_SETFD, fl | FD_CLOEXEC);
    }
    /* 父进程也持有两端，必须关掉：否则 QEMU 退出后 passt 读到的不是 EOF，
       会一直等下去，看不出对端已经没了。 */
    close(PASST_FD);
    close(QEMU_FD);

    who = wait(&status);
    if (who == g_passt) {
        fprintf(stderr, "passtlaunch: PASST exited first (status %d)\n", status);
        kill(g_qemu, SIGKILL);
        waitpid(g_qemu, NULL, 0);
    } else if (who == g_qemu) {
        fprintf(stderr, "passtlaunch: QEMU exited first (status %d)\n", status);
        kill(g_passt, SIGKILL);
        waitpid(g_passt, NULL, 0);
    }

    free_argv(passt_argv);
    free_argv(qemu_argv);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 3;
}
