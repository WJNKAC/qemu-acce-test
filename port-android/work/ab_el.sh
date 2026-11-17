#!/bin/bash
# 启动 A/B：base vs EL 分流版。交错 + pkill + 冷却（教训见 MEASURE.md 第七轮）。
set -u
D=/data/local/tmp
N=${1:-5}
C=${CPUS:-2}
run() {
    adb shell "su -c 'pkill -x hv-el2; pkill -x hv-el; pkill -x hv-base; pkill -x hv-bank; pkill -x hv-linux'" >/dev/null 2>&1
    sleep 2
    adb shell "HV_BOOTARGS='console=ttyAMA0 rdinit=/myinit root=/dev/nvme0n1p2 rw loglevel=2 hvrun=boot' taskset 80 $D/$1 --kernel $D/Image --disk $D/debian.raw --ram 2048 --cpus $C" 2>&1 \
        | grep -o 'uptime [0-9.]*' | awk '{print $2}'
}
for i in $(seq 1 "$N"); do
    b=$(run hv-base); e=$(run hv-el2)
    echo "$i base=$b el=$e"
done
