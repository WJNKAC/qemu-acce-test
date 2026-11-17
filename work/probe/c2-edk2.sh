#!/bin/sh
# c2-edk2.sh - C2 廉价回归：edk2 → Shell，完全无盘。
#
# 为什么这是最高性价比的诊断格：
#   - 不挂 virtio-blk，所以没有任何数据面 DMA
#   - 不挂网络，所以没有 MMIO doorbell 风暴
#   - 只剩 pflash 读 + 串口 + GIC + 取指翻译
# 如果这一格都过不了，问题在基础路径（引擎/环境），与磁盘/memfd/DMA 全无关，
# 今天所有"overlay/memfd 有罪"的推断都可以直接作废。
#
# 用固定参数：pflash code 只读 + vars 可写，无任何 -drive if=none。
set -eu
H=${H:-/data/data/com.termux/files/home/h}
TAG=${1:-c2e}
BIN=${2:?binary}
SECS=${3:-120}

LOG=$H/L-$TAG.log
{ echo "# bin=$(basename $BIN) md5=$(md5sum "$BIN" | cut -c1-16)"; \
  echo "# argv: $TAG ram=anon disk=none net=none secs=$SECS"; } > "$LOG"

nohup sh -c "exec timeout -s KILL $SECS taskset -c 6,7 $BIN \
  -L /data/local/tmp/henge/bios \
  -M virt,gic-version=3 -cpu max -m 1024 -nographic -no-reboot -smp 2 -accel henge \
  -drive if=pflash,format=raw,unit=0,file=/data/local/tmp/henge/bios/edk2-aarch64-code.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=$H/e-vars.img \
  >> $LOG 2>&1" >/dev/null 2>&1 &
echo "c2-edk2 launched -> $LOG"
