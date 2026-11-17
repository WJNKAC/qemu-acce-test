#!/bin/sh
# 由 bootargs 里的 HVB= 决定跑哪一项，配合每次冷启动测量，
# 避开这台设备的 DVFS 热降频（连续跑 30 秒后同一负载会慢 2.4 倍）。
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sys /sys 2>/dev/null

echo "CMDLINE=[$(cat /proc/cmdline)]"
which=$(sed -n "s/.*HVB=\([A-Za-z0-9]*\).*/\1/p" /proc/cmdline)
[ -z "$which" ] && which=all
a=$(cut -d" " -f1 /proc/uptime)
echo "HVB=$which BEGIN=$a"
case "$which" in
  alu|mem|call|branch) /usr/bin/bench3 400000000 $which ;;
  real)                /usr/bin/bench3 200000000 real ;;
  u1|u8|u32)           /usr/bin/loops $which ;;   # 块转移开销：每块 1/8/32 条工作指令
  loops)               /usr/bin/loops ;;
  knee)                K=$(sed -n "s/.*[^A-Za-z]KNEE=\([0-9]*\).*/\1/p" /proc/cmdline)
                       S=$(sed -n "s/.*[^A-Za-z]STRIDE=\([0-9]*\).*/\1/p" /proc/cmdline)
                       /usr/bin/knee $K ${S:-12} ;;   # KNEE=<KiB> 档位, STRIDE=<2 的幂>
  all)                 /usr/bin/bench3 400000000 | sed 's/^/  /' ;;
esac
echo "END=$(cut -d' ' -f1 /proc/uptime)"
sync
poweroff -f
