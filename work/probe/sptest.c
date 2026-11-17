/*
 * sptest - 验证 adb shell 域能否 socketpair(AF_UNIX, SOCK_STREAM)
 *
 * 为什么需要：passt 必须有一个已连接的 UNIX socket 才能工作。
 * adb shell 域 bind 一个路径 socket 被 SELinux 拒（实测），
 * 但 socketpair() 不 bind、不碰文件系统 —— 如果它被允许，
 * 就能用 `passt -F <fd>` + `qemu -netdev socket,fd=<fd>` 接起来，
 * 完全绕开 bind。
 *
 * 输出一行 OK/FAIL + errno，供脚本判读。
 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <sys/socket.h>
#include <unistd.h>

int main(void)
{
    int sv[2];

    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
        printf("FAIL socketpair errno=%d (%s)\n", errno, strerror(errno));
        return 1;
    }
    printf("OK socketpair fd=%d,%d\n", sv[0], sv[1]);

    /* 再验一次能不能收发（socketpair 只建 fd，不证明数据面通） */
    if (write(sv[1], "ping", 4) != 4) {
        printf("FAIL write errno=%d\n", errno);
        return 1;
    }
    {
        char buf[8] = {0};
        ssize_t n = read(sv[0], buf, sizeof buf);
        printf("%s data n=%zd buf=%s\n", n == 4 ? "OK" : "FAIL", n, buf);
    }
    return 0;
}
