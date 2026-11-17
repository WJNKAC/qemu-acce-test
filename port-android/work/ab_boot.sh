#!/bin/bash
# 启动 A/B：5 个交错样本，每轮之间冷却是关键。
# 教训：第 1 次 bank 跑出 90.96s（vs 31-32s），当时 loadavg=25、上一轮 knee 的 2GB 页还没回收。
# 所以跑之前必须 pkill 残留 + sync 让 page cache 落盘 + 短冷却。
set -u
D=/data/local/tmp
N=${1:-5}
run() {
    adb shell "su -c 'pkill -x hv-bank; pkill -x hv-base; pkill -x hv-linux'" >/dev/null 2>&1
    sleep 2
    adb shell "HV_BOOTARGS='console=ttyAMA0 rdinit=/myinit root=/dev/nvme0n1p2 rw loglevel=2 hvrun=boot' taskset 80 $D/$1 --kernel $D/Image --disk $D/debian.raw --ram 2048 --cpus ${CPUS:-2}" 2>&1 \
        | grep -o 'uptime [0-9.]*' | awk '{print $2}'
}
for i in $(seq 1 "$N"); do
    b=$(run hv-base)
    k=$(run hv-bank)
    echo "$i base=$b bank=$k"
done
