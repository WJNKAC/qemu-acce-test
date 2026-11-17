/*
 * tcpprobe - 在 Android 宿主侧测 TCP 三态（ok / refused / timeout）
 *
 * 为什么需要：宿主的 toybox nc 没有 -z，也没有 python3，
 * 所以"这个地址通不通"在宿主侧没法直接问。这个静态二进制补上这一格。
 *
 * 输出一行：<ip>:<port> <state> <耗时ms>
 *   ok       三次握手完成
 *   refused  收到 RST（包到了，端口没服务）—— 按 STATES.md 这是"通"
 *   timeout  无应答 —— 唯一可疑信号
 *
 * 用法：tcpprobe <ip> <port> [timeout_s] [次数]
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <time.h>
#include <unistd.h>

static long long ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

int main(int argc, char **argv)
{
    struct sockaddr_in sa;
    int tmo = 3, n = 1, i;

    if (argc < 3) {
        fprintf(stderr, "usage: %s <ip> <port> [timeout_s] [count]\n", argv[0]);
        return 2;
    }
    if (argc > 3) tmo = atoi(argv[3]);
    if (argc > 4) n = atoi(argv[4]);

    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    sa.sin_port = htons((unsigned short)atoi(argv[2]));
    if (inet_pton(AF_INET, argv[1], &sa.sin_addr) != 1) {
        fprintf(stderr, "bad ip: %s\n", argv[1]);
        return 2;
    }

    for (i = 0; i < n; i++) {
        int fd;
        long long t0, dt;
        const char *st;
        struct timeval tv = { tmo, 0 };

        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) { perror("socket"); return 3; }
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);

        t0 = ms();
        if (connect(fd, (struct sockaddr *)&sa, sizeof sa) == 0) {
            st = "ok";
        } else if (errno == ECONNREFUSED) {
            st = "refused";
        } else if (errno == ETIMEDOUT || errno == EINPROGRESS || errno == EAGAIN) {
            st = "timeout";
        } else if (errno == ENETUNREACH || errno == EHOSTUNREACH) {
            st = "unreachable";
        } else {
            st = strerror(errno);
        }
        dt = ms() - t0;
        close(fd);
        printf("%s:%s %s %lldms\n", argv[1], argv[2], st, dt);
        fflush(stdout);
    }
    return 0;
}
