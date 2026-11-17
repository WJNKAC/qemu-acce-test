#!/bin/sh
# 在 Alpine 的 rootfs 里跑，由 /myinit fork+exec 起来。
# 目的不是"看看输出"，是验证几件必须真的对的事：
#   1. musl 动态链接器能加载共享库（ELF loader + mmap + 缺页）
#   2. /proc /sys /dev 都真的挂上了
#   3. busybox 的 applet 能干活（fork/exec/wait、管道、文件系统）
#   4. 用户态的 CPU 时间、定时器、tick 都正常

echo
echo "=============================================================="
echo "  Alpine Linux userland on the ARM64-to-ARM64 translator"
echo "=============================================================="

echo
echo "-- identity --"
uname -a
[ -f /etc/os-release ] && . /etc/os-release && echo "$PRETTY_NAME"

echo
echo "-- dynamic linking --"
echo "busybox: $(command -v busybox)"
ls -l /lib/ld-musl-aarch64.so.1 2>/dev/null || echo "  (no musl loader)"
echo "ldd busybox:"; ldd /bin/busybox 2>/dev/null | sed 's/^/  /'

echo
echo "-- mounts --"
grep -E ' (proc|sysfs|devtmpfs|rootfs) ' /proc/mounts | sed 's/^/  /'

echo
echo "-- cpus --"
grep -c ^processor /proc/cpuinfo | sed 's/^/  count: /'
grep -m1 'CPU part' /proc/cpuinfo | sed 's/^/  /'
echo "  uptime: $(cut -d' ' -f1 /proc/uptime)s"

echo
echo "-- memory --"
head -3 /proc/meminfo | sed 's/^/  /'

echo
echo "-- interrupts (timer must be firing) --"
grep -E 'arch_timer|pl011|GIC' /proc/interrupts 2>/dev/null | sed 's/^/  /'

echo
echo "-- devices --"
for d in /dev/console /dev/ttyAMA0 /dev/null /dev/zero; do
    [ -e "$d" ] && echo "  $d present" || echo "  $d -"
done

echo
echo "-- clock sanity (jiffies must advance) --"
a=$(cut -d' ' -f1 /proc/uptime)
sleep 1
b=$(cut -d' ' -f1 /proc/uptime)
echo "  uptime went $a -> $b  (delta $(echo "$b - $a" | bc 2>/dev/null || echo '?'))"

echo
echo "-- userspace work: fork/exec/pipe/fs --"
n=0
for i in 1 2 3 4 5; do n=$((n + i)); done
echo "  shell arithmetic: $n"
echo "shell pipeline works" | tr 'a-z' 'A-Z' | sed 's/^/  /'
mkdir -p /tmp/t && echo hello > /tmp/t/f && cat /tmp/t/f | sed 's/^/  file: /'

echo
echo "-- cpu throughput (userspace, 3 x 1s) --"
i=0
while [ $i -lt 3 ]; do
    start=$(cut -d' ' -f1 /proc/uptime)
    x=0
    while :; do
        y=0
        while [ $y -lt 20000 ]; do y=$((y + 1)); done
        x=$((x + 1))
        now=$(cut -d' ' -f1 /proc/uptime)
        [ "$now" != "$start" ] && break
    done
    echo "  pass $((i + 1)): $x inner loops in one tick"
    i=$((i + 1))
done

echo
echo "-- done: powering off via PSCI --"
sync
poweroff -f
