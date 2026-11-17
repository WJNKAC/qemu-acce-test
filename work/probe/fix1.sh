#!/bin/sh
# fix1.sh - 验证 timer 写侧修复。三条判据同时观测：
#   1) hv-wfi 的 slept 应从 8192 大降   （deadline 算得出来了）
#   2) irq line 转换应从 0 变非零        （timer IRQ 真的投递了）
#   3) serial 应越过 BdsDxe              （guest 真的推进了）
#
# 两个探针都开：
#   HV_WFI_COUNT=1        → 引擎打印 A/B/slept 三条路径计数
#   -accel henge,trace=irq → sync_irq 在 hard 变化时打印 irq line
#
# 注意 trace=irq 会打印每一条 "hv_run returned"，量大，只用于短窗口诊断。
set -u

# ---- 设备 suspend 会让 CLOCK_MONOTONIC 停走，guest 被一起冻住 ----
# 实测：30 秒真实时间里 MONOTONIC 只走 0.98 秒（97% 在 suspend），
# 结果是 guest 的 85 秒 timer deadline 要等约 2550 秒真实时间。
# QEMU 的 get_clock() 用 CLOCK_MONOTONIC，所以设备一睡 guest 就停。
# 每个跑实验的脚本都必须先拿 wakelock，否则测的是"设备睡了多久"。
termux-wake-lock 2>/dev/null || true
H=${H:-/data/data/com.termux/files/home/h}
TAG=${1:-fx}
SECS=${2:-240}
CPUS=${3:-0,1}
BIN=${4:-$H/q-fix}
# TRACE=irq 才开 irq trace。默认关，因为 trace 会打印每条 hv_run returned
# （SYSREG_EXT 一条一条打），既拖慢又让 stderr 无法与只开 WFI_COUNT 的配置对比。
TRACE=${TRACE:-}

VARS=$H/g-$TAG.img
SER=$H/run-$TAG.serial.log
ERR=$H/run-$TAG.stderr.log
PIDF=$H/run-$TAG.pid

[ -x "$BIN" ] || { echo "MISSING $BIN" >&2; exit 3; }
[ -e "$VARS" ] || cp $H/vars0.img "$VARS"

rm -f "$SER" "$ERR"
{
    echo "# bin=$(basename $BIN) md5=$(md5sum "$BIN" | cut -c1-16)"
    echo "# mode=anon disk=none net=none cpus=$CPUS secs=$SECS"
    echo "# probes: HV_WFI_COUNT=1 trace=${TRACE:-none}"
} > "$SER"

nohup sh -c "HV_WFI_COUNT=1 exec taskset -c $CPUS $BIN \
  -L /data/local/tmp/henge/bios \
  -M virt,gic-version=3 -cpu max -m 2048 \
  -display none -no-reboot -smp 2 -accel henge${TRACE:+,trace=$TRACE} \
  -drive if=pflash,format=raw,unit=0,file=/data/local/tmp/henge/bios/edk2-aarch64-code.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=$VARS \
  -serial file:$SER -monitor none" > "$ERR" 2>&1 &
echo $! > "$PIDF"

nohup sh -c "sleep $SECS; kill -9 \$(cat $PIDF) 2>/dev/null" >/dev/null 2>&1 &
sleep 2
echo "launched tag=$TAG pid=$(cat $PIDF) bin=$(basename $BIN) secs=$SECS"
