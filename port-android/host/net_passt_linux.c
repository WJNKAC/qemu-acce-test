/* passt 后端：把 virtio-net 的帧交给 passt 进程，而不是用户态的 libslirp。
 *
 * 为什么这样做值得：
 *   - libslirp 是一整套用户态 TCP/IP 栈，每个连接要过三遍协议栈
 *     （guest → slirp → host），还要自己做 NAT。
 *   - passt 只做「二层帧 ↔ 宿主内核的原生 socket」的翻译，TCP 用的是内核的
 *     真实 socket，没有第二套协议栈。
 *
 * 接口：passt 用 --fd 接管一个已连接的 UNIX socket，帧格式是
 *   [4 字节 大端长度][以太网帧]
 * 正好和 QEMU 的 `-netdev stream` 一样（passt 就是为那个设计的）。
 *
 * 线程模型（和 slirp 后端一致，因为 hv_virtio_net_receive 必须在 vCPU 线程上）：
 *   passt 进程 ←→ socket ←→ 读线程 → to_guest 队列 → hv_net_poll（tick 里）→ guest
 *   guest → transmit 回调 → to_host 队列 → 写线程 → socket → passt
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>

#include "net_passt_linux.h"
#include "virtio_net.h"

#define QUEUE 4096   /* 原来是 256：passt 突发发送时会溢出，丢帧引发 TCP 重传 */

typedef struct { uint8_t *data; uint32_t len; } Frame;

typedef struct {
    Frame f[QUEUE];
    unsigned head, tail;
    pthread_mutex_t mu;
} Queue;

static Queue to_guest, to_host;
static int sock = -1;            /* 与 passt 之间的 socket，CPU 线程读写 */
static pid_t passt_pid = -1;
static HvVirtioNet *virtio_net;
static atomic_int passt_stop;
static pthread_t rx_tid, tx_tid;
static int threads_started;

static int trace_on = -1;
static atomic_ullong n_rx, n_tx, n_tx_done, n_drop, n_norbuf;

/* HV_NET_TRACE=1：每个帧一行。排查"到底卡在哪个方向"时最有用。 */
static void trace(const char *dir, const uint8_t *f, uint32_t len) {
    if (trace_on < 0) trace_on = getenv("HV_NET_TRACE") != NULL;
    if (!trace_on || len < 14) return;
    fprintf(stderr, "[net] %s len=%u type=%02x%02x %02x:%02x:%02x:%02x:%02x:%02x -> %02x:%02x:%02x:%02x:%02x:%02x\n",
            dir, len, f[12], f[13],
            f[6],f[7],f[8],f[9],f[10],f[11],
            f[0],f[1],f[2],f[3],f[4],f[5]);
}

static int push(Queue *q, const void *data, uint32_t len) {
    int ok = 0;
    pthread_mutex_lock(&q->mu);
    if (q->tail - q->head < QUEUE) {
        uint8_t *p = malloc(len);
        if (p) {
            memcpy(p, data, len);
            q->f[q->tail % QUEUE] = (Frame){p, len};
            q->tail++;
            ok = 1;
        }
    }
    pthread_mutex_unlock(&q->mu);
    return ok;
}

/* ---- 一个完整帧：4 字节大端长度 + 帧体。STREAM socket 会短读，必须循环。 ---- */
static int read_exact(int fd, void *buf, size_t n) {
    uint8_t *p = buf;
    while (n) {
        ssize_t r = read(fd, p, n);
        if (r <= 0) return -1;
        p += r;
        n -= (size_t)r;
    }
    return 0;
}

static int write_exact(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n) {
        ssize_t r = write(fd, p, n);
        if (r <= 0) return -1;
        p += r;
        n -= (size_t)r;
    }
    return 0;
}

/* passt → 我们：读线程把帧收进 to_guest 队列。 */
static void *rx_thread(void *unused) {
    (void)unused;
    uint8_t buf[65536];
    while (!atomic_load(&passt_stop)) {
        struct pollfd p = {sock, POLLIN, 0};
        int r = poll(&p, 1, 200);
        if (r <= 0) continue;
        uint32_t be;
        if (read_exact(sock, &be, 4) != 0) break;
        uint32_t len = (uint32_t)((be >> 24) | ((be >> 8) & 0xff00) | ((be << 8) & 0xff0000) | (be << 24));
        if (len == 0 || len > sizeof buf) break;
        if (read_exact(sock, buf, len) != 0) break;
        atomic_fetch_add(&n_rx, 1);
        trace("passt->guest", buf, len);
        if (!push(&to_guest, buf, len)) atomic_fetch_add(&n_drop, 1);
    }
    return NULL;
}

/* 我们 → passt：写线程从 to_host 队列取帧发出去。 */
static void *tx_thread(void *unused) {
    (void)unused;
    while (!atomic_load(&passt_stop)) {
        Frame f = {NULL, 0};
        pthread_mutex_lock(&to_host.mu);
        if (to_host.head != to_host.tail) f = to_host.f[to_host.head++ % QUEUE];
        pthread_mutex_unlock(&to_host.mu);
        if (!f.data) { usleep(200); continue; }
        uint32_t be = ((uint32_t)f.len >> 24) | (((uint32_t)f.len >> 8) & 0xff00) |
                      (((uint32_t)f.len << 8) & 0xff0000) | ((uint32_t)f.len << 24);
        if (write_exact(sock, &be, 4) != 0 || write_exact(sock, f.data, f.len) != 0) {
            fprintf(stderr, "[net] tx failed (len=%u): %s — tx thread stops here\n",
                    f.len, strerror(errno));
            /* passt 很可能死了：问一下它怎么死的，别让它静默消失 */
            int st = 0;
            pid_t r = waitpid(passt_pid, &st, WNOHANG);
            if (r == passt_pid) {
                if (WIFSIGNALED(st))
                    fprintf(stderr, "[net] passt was killed by signal %d (%s)\n",
                            WTERMSIG(st), strsignal(WTERMSIG(st)));
                else
                    fprintf(stderr, "[net] passt exited with status %d\n", WEXITSTATUS(st));
                passt_pid = -1;
            } else {
                fprintf(stderr, "[net] passt still running (pid %d)?\n", (int)passt_pid);
            }
            free(f.data);
            break;
        }
        atomic_fetch_add(&n_tx_done, 1);
        free(f.data);
    }
    return NULL;
}

/* vCPU 线程：guest 发了一个帧。只入队，真正的写交给 tx 线程——
   在 vCPU 线程里阻塞写会让整个客户机卡住。 */
static void transmit(void *opaque, const uint8_t *frame, uint32_t len) {
    (void)opaque;
    atomic_fetch_add(&n_tx, 1);
    trace("guest->passt", frame, len);
    if (!push(&to_host, frame, len)) { /* 队列满：丢帧 */ }
}

/* tick 里调用（vCPU 线程）：把排队的帧喂给 guest。 */
void hv_net_poll(void) {
    if (!virtio_net) return;
    for (;;) {
        Frame f = {NULL, 0};
        pthread_mutex_lock(&to_guest.mu);
        if (to_guest.head != to_guest.tail) f = to_guest.f[to_guest.head % QUEUE];
        pthread_mutex_unlock(&to_guest.mu);
        if (!f.data) return;
        if (!hv_virtio_net_receive(virtio_net, f.data, f.len)) {
            atomic_fetch_add(&n_norbuf, 1);
            return; /* guest 还没贴接收缓冲：留着，下次再试 */
        }
        pthread_mutex_lock(&to_guest.mu);
        to_guest.head++;
        pthread_mutex_unlock(&to_guest.mu);
        free(f.data);
    }
}

/* 从宿主接口推一个 guest 地址和网关。
 *
 * 为什么需要：passt 的默认行为是"从上游接口取一个地址当模板"，但在 Android
 * 的 shell 域里它读不到 /sys/class/net 的完整信息，会打印
 *   "IPv4: no external interface as template, use local mode"
 * 然后退化成 169.254.2.1/8 的 link-local 配置 —— guest 和网关 192.168.1.1
 * 不在同一网段，DHCP 能成但包出不去。
 *
 * 所以这里自己看一遍接口，挑第一个非 lo 的 IPv4，给 guest 挑一个同网段的
 * 空闲地址（host 的地址 +1 的最后一个字节，避开常见 DHCP 池），网关用 host
 * 的网关候选（同网段的 .1）。
 */
static int pick_guest_addr(char *addr, size_t na, char *mask, size_t nm, char *gw, size_t ng) {
    struct ifaddrs *ifs = NULL;
    int found = 0;
    if (getifaddrs(&ifs) != 0) return -1;
    for (struct ifaddrs *i = ifs; i && !found; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET) continue;
        if (i->ifa_flags & IFF_LOOPBACK) continue;
        if (!(i->ifa_flags & IFF_UP)) continue;
        struct sockaddr_in *sin = (struct sockaddr_in *)i->ifa_addr;
        struct sockaddr_in *msk = (struct sockaddr_in *)i->ifa_netmask;
        uint32_t host = ntohl(sin->sin_addr.s_addr);
        uint32_t m = msk ? ntohl(msk->sin_addr.s_addr) : 0xffffff00u;
        int bits = 0;
        for (uint32_t t = m; t & 0x80000000u; t <<= 1) bits++;
        if (bits < 8 || bits > 30) continue;
        /* guest: 同网段，最后一个字节取 host+100（避开 DHCP 池和常见静态分配） */
        uint32_t g = (host & m) | (((host & 0xff) + 100) & 0xff);
        if (((host & m) | 0xff) == g) g = (host & m) | 0xfe;   /* 别撞广播 */
        struct in_addr a = { htonl(g) }, mnet = { htonl(m) };
        /* 网关：网段的 .1（家用路由的默认约定） */
        uint32_t gwm = (host & m) | 1;
        struct in_addr gwa = { htonl(gwm) };
        snprintf(addr, na, "%s", inet_ntoa(a));
        snprintf(mask, nm, "%d", bits);
        snprintf(gw, ng, "%s", inet_ntoa(gwa));
        fprintf(stderr, "hv-linux: passt guest addr %s/%d, gw %s (host is %s on %s)\n",
                addr, bits, gw, inet_ntoa(sin->sin_addr), i->ifa_name);
        (void)mnet;
        found = 1;
    }
    freeifaddrs(ifs);
    return found ? 0 : -1;
}

/* 统计线程：丢帧和无缓冲等待是 TCP 吞吐低的两大常见原因，定期报出来。 */
static void *stats_thread(void *unused) {
    (void)unused;
    while (!atomic_load(&passt_stop)) {
        sleep(2);
        fprintf(stderr, "[net] rx=%llu tx=%llu sent=%llu DROP=%llu nobuf=%llu\n",
                (unsigned long long)atomic_load(&n_rx), (unsigned long long)atomic_load(&n_tx),
                (unsigned long long)atomic_load(&n_tx_done), (unsigned long long)atomic_load(&n_drop),
                (unsigned long long)atomic_load(&n_norbuf));
    }
    return NULL;
}

int hv_net_attach(HvMachine *m, HvVirtioNet *n) {
    (void)m;
    const char *bin = getenv("HV_PASST");
    if (!bin || !*bin) bin = "/data/local/tmp/passt";
    if (access(bin, X_OK) != 0) {
        fprintf(stderr, "hv-linux: passt not found at %s (set HV_PASST)\n", bin);
        return -1;
    }

    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
        perror("hv-linux: socketpair");
        return -1;
    }
    virtio_net = n;

    passt_pid = fork();
    if (passt_pid < 0) { perror("hv-linux: fork passt"); return -1; }
    if (passt_pid == 0) {
        /* 子进程：把 sv[1] 挪到固定 fd 交给 passt */
        dup2(sv[1], 3);
        if (sv[1] != 3) close(sv[1]);
        close(sv[0]);
        /* 这台设备没有 CONFIG_USER_NS、也不给非 root 做 unshare：
           passt 的那两层隔离在这儿建不起来，但它本来就在 SELinux 的
           shell 域里跑，跳过不影响功能。 */
        setenv("HV_PASST_NO_USERNS", "1", 1);
        setenv("HV_PASST_NO_SANDBOX", "1", 1);
        setenv("HV_PASST_NO_SECCOMP", "1", 1);
        /* 优先用自己探测到的地址；探测不到就让 passt 走它自己的默认逻辑。 */
        char a[32] = "169.254.2.1", mask[8] = "16", gw[32] = "169.254.2.2";
        int have = pick_guest_addr(a, sizeof a, mask, sizeof mask, gw, sizeof gw);
        /* DNS：Android 没有 /etc/resolv.conf（由 netd 管），passt 因此
           "Couldn't get any nameserver address"，DHCP 也就不下发 DNS，
           guest 会一直用旧 lease 里的地址。显式给一个。 */
        const char *dns = getenv("HV_PASST_DNS");
        if (!dns || !*dns) dns = "223.5.5.5";
        int dbg = getenv("HV_PASST_DEBUG") != NULL;
        if (have == 0) {
            if (dbg) execl(bin, "passt", "-f", "--trace", "--fd", "3", "-a", a, "-n", mask, "-g", gw, "-D", dns, (char *)NULL);
            else execl(bin, "passt", "-f", "-q", "--fd", "3", "-a", a, "-n", mask, "-g", gw, "-D", dns, (char *)NULL);
        } else {
            if (dbg) execl(bin, "passt", "-f", "-d", "--fd", "3", "-D", dns, (char *)NULL);
            else execl(bin, "passt", "-f", "-q", "--fd", "3", "-D", dns, (char *)NULL);
        }
        _exit(127);
    }
    close(sv[1]);
    sock = sv[0];

    /* passt 自己会发初始 ARP/NDP，等它把 socket 建好 */
    usleep(150 * 1000);
    if (waitpid(passt_pid, NULL, WNOHANG) == passt_pid) {
        fprintf(stderr, "hv-linux: passt exited immediately (check HV_PASST)\n");
        return -1;
    }

    n->transmit = transmit;
    n->opaque = NULL;

    pthread_mutex_init(&to_guest.mu, NULL);
    pthread_mutex_init(&to_host.mu, NULL);
    if (pthread_create(&rx_tid, NULL, rx_thread, NULL) == 0 &&
        pthread_create(&tx_tid, NULL, tx_thread, NULL) == 0) {
        pthread_detach(rx_tid);
        pthread_detach(tx_tid);
        threads_started = 1;
    } else {
        fprintf(stderr, "hv-linux: cannot start the passt I/O threads\n");
        return -1;
    }
    fprintf(stderr, "hv-linux: passt DNS = %s\n", getenv("HV_PASST_DNS") ? getenv("HV_PASST_DNS") : "223.5.5.5");
    if (getenv("HV_NET_STATS")) {
        static pthread_t st;
        if (pthread_create(&st, NULL, stats_thread, NULL) == 0) pthread_detach(st);
    }
    fprintf(stderr, "[net] counters after attach: rx=%llu tx_queued=%llu tx_sent=%llu\n",
            (unsigned long long)n_rx, (unsigned long long)n_tx, (unsigned long long)n_tx_done);
    fprintf(stderr, "hv-linux: passt attached (pid %d) — kernel sockets, no userland TCP stack\n",
            (int)passt_pid);
    return 0;
}

void hv_net_shutdown(void) {
    atomic_store(&passt_stop, 1);
    if (sock >= 0) { shutdown(sock, SHUT_RDWR); close(sock); sock = -1; }
    if (passt_pid > 0) {
        kill(passt_pid, SIGTERM);
        for (int i = 0; i < 20; i++) {
            if (waitpid(passt_pid, NULL, WNOHANG) == passt_pid) { passt_pid = -1; break; }
            usleep(20 * 1000);
        }
        if (passt_pid > 0) { kill(passt_pid, SIGKILL); waitpid(passt_pid, NULL, 0); passt_pid = -1; }
    }
    (void)threads_started;
}

void hv_net_add_hostfwd(int host_port, int guest_port) {
    (void)host_port; (void)guest_port;
}

void hv_net_set_share_socket(const char *path) { (void)path; }
