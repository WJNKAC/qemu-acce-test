#!/bin/sh
# c2-kernel.sh - C2 廉价回归之一：-kernel + initrd，完全无盘。
#
# 为什么这个格子判别力强：它几乎不产生 DMA（没有 virtio-blk 数据面），
# 所以如果 B_dma/B_count 在这个格子上就挂了，回归点必然在基础路径
# （取指/翻译/MMIO/serial），跟"只在一个后端上验过"的 DMA 重写无关。
# 反过来，如果这个格子过、而磁盘启动死，回归就锁死在 DMA 路径上。
set -eu
H=${H:-/data/data/com.termux/files/home/h}
TAG=${1:-c2k}
BIN=${2:-$H/b-new}

LOG=$H/L-$TAG.log
{ echo "# bin=$(basename $BIN) md5=$(md5sum $BIN | cut -c1-16)"; } > "$LOG"

nohup sh -c "exec timeout -s KILL 180 taskset -c 6,7 $BIN \
  -M virt,gic-version=3 -cpu max -m 2048 -nographic -no-reboot -smp 2 -accel henge \
  -kernel $H/kernel.img -initrd $H/initrd.img \
  -append 'console=ttyAMA0 panic=-1' >> $LOG 2>&1" >/dev/null 2>&1 &
echo "c2-kernel launched -> $LOG"
