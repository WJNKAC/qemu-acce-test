/*
 * vclk - 一次调用打印一行：mono_ms boot_ms rss_kb
 *
 * 为什么需要它：设备侧（adb shell / Termux）都没有 python3 时，
 * MONOTONIC 读不出来。/proc/uptime 是 BOOTTIME（含 suspend），
 * `date +%s.%N` 是 REALTIME（会被 NTP 跳）。判 suspend 污染要的是
 *   dsusp = ΔBOOTTIME - ΔMONOTONIC
 * 两个钟都得是真钟，所以只能靠一个静态二进制。
 *
 * 用法：
 *   vclk                 -> "mono_ms boot_ms 0"
 *   vclk <pid>           -> 第三列是该 pid 的 RSS（/proc/pid/statm 第 2 页数）
 *
 * 静态链接，arm64，adb push 即可跑。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static long long ms(clockid_t id)
{
    struct timespec ts;
    if (clock_gettime(id, &ts) != 0) return -1;
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static long long rss_kb(const char *pid)
{
    char path[64], buf[256];
    FILE *f;
    long long size = 0, resident = 0;

    if (!pid || !*pid) return 0;
    snprintf(path, sizeof path, "/proc/%s/statm", pid);
    f = fopen(path, "r");
    if (!f) return -1;
    if (!fgets(buf, sizeof buf, f)) { fclose(f); return -1; }
    fclose(f);
    if (sscanf(buf, "%lld %lld", &size, &resident) != 2) return -1;
    return resident * (sysconf(_SC_PAGESIZE) / 1024);
}

int main(int argc, char **argv)
{
    long long mono = ms(CLOCK_MONOTONIC);
    long long boot = ms(CLOCK_BOOTTIME);

    printf("%lld %lld %lld\n", mono, boot, rss_kb(argc > 1 ? argv[1] : NULL));
    return 0;
}
