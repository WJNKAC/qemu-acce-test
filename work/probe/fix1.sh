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

# ---- 时钟连续性：用内核 suspend blocker，不用 termux-wake-lock ----
# 13.30 实测：termux-wake-lock 拿的是 Android PowerManager 层的
# PARTIAL_WAKE_LOCK，Doze 会越过它 —— 10 秒采样间隔里设备睡了 141.9 秒，
# 而 QEMU 的 get_clock() 就是 CLOCK_MONOTONIC，deviceidle 白名单也挡不住
# 系统 suspend（它只免 app 的后台限制）。
# /sys/power/wake_lock 是内核 blocker，Doze 绕不过：实测 dsusp=0.00s。
sh ${H:-/data/data/com.termux/files/home/h}/powerhold.sh hold >/dev/null 2>&1 || \
    echo "警告: 无法持有 suspend blocker，本轮数据可能被 doze 污染" >&2
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
