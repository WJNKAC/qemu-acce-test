#!/bin/sh
# wfi2.sh - 抢救 wfi_hist 计数（F0 的第三个读数，两次都没落地）。
#
# hv-wfi 的三条路径：
#   A(line-high) = WFI 时 IRQ 已挂起，wait_for_interrupt 返回 0，引擎继续跑
#                  → 不会产生 code 4，也不会产生任何 exit
#   B(no-tick)   = m->tick 为 NULL，返回 -1 → 交回 QEMU，产生 code 4
#   slept        = 真的在 wake_cv 上睡了（≤10ms）
#
# 这组计数一次裁决异常 1：观测到零次 code 4，到底是
#   (a) WFI 走了 A 路径（IRQ 已 pending，正常），
#   (b) 走了 B 路径但打印点漏了（已排除，打印覆盖所有 r），
#   (c) guest 从未执行 WFI。
#
# 关键点（前两次失败的教训）：
#   - 不用 launch3.sh：它的参数校验和 set -eu 曾让整条命令静默退出
#   - 必须跑够长：上一次只跑到 serial=4 行就收工，那时还早得很
#   - stderr 单独落文件，不与 serial 共用
set -u
H=${H:-/data/data/com.termux/files/home/h}
TAG=${1:-wf}
SECS=${2:-300}
CPUS=${3:-0,1}

BIN=$H/b-old
VARS=$H/g-$TAG.img
SER=$H/run-$TAG.serial.log
ERR=$H/run-$TAG.stderr.log
PIDF=$H/run-$TAG.pid

[ -x "$BIN" ] || { echo "MISSING $BIN" >&2; exit 3; }
[ -e "$VARS" ] || cp $H/vars0.img "$VARS"

rm -f "$SER" "$ERR"
{
    echo "# bin=$(basename $BIN) md5=$(md5sum "$BIN" | cut -c1-16)"
    echo "# mode=anon disk=none net=none cpus=$CPUS secs=$SECS probe=HV_WFI_COUNT"
    echo "# freq: $(for c in 0 6; do printf 'c%s=%s ' $c "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null)"; done)"
} > "$SER"

nohup sh -c "HV_WFI_COUNT=1 exec taskset -c $CPUS $BIN \
  -L /data/local/tmp/henge/bios \
  -M virt,gic-version=3 -cpu max -m 2048 \
  -display none -no-reboot -smp 2 -accel henge \
  -drive if=pflash,format=raw,unit=0,file=/data/local/tmp/henge/bios/edk2-aarch64-code.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=$VARS \
  -serial file:$SER -monitor none" > "$ERR" 2>&1 &
echo $! > "$PIDF"

nohup sh -c "sleep $SECS; kill -9 \$(cat $PIDF) 2>/dev/null" >/dev/null 2>&1 &
sleep 2
echo "launched tag=$TAG pid=$(cat $PIDF) secs=$SECS"
