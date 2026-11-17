#!/bin/sh
# launch3.sh - 启动器 v3。相对 v2 的四处结构修正：
#
#   1. **pidfile，永不模式匹配杀进程**。
#      `case "$c" in *b-old*) kill` 会匹配执行者自身（argv 含 b-old），
#      这是结构病不是笔误：任何"按名字找"都会误伤。清理只读 $DIR/pid。
#
#   2. **-serial file:$DIR/serial.log**，与 stderr 分离。
#      `-nographic` 把串口接到 stdio，经管道时被缓冲，timeout 杀掉后
#      看不到内容 —— 整类"日志为空"的假象由此消失。
#
#   3. **日志头五列**：md5 + 完整 argv + affinity + 频率快照 + 温度快照。
#      本轮所有误判的共同根因是日志不带身份，跨二进制/跨核比数据。
#
#   4. **affinity 参数化**。之前写死 6,7，而 6,7 会热降频到 63.7%，
#      于是"环境漂移"和"引擎 bug"分不开。
#
# 用法: launch3.sh <tag> <binary> <ram> <disk> <net> <cpus> <secs> [extra_qemu_args]
#   ACCELTRACE=irq,mmio  附加到 -accel henge 后面（探针，见 b-old 源码）
#   HV_DBG_FLUSH=1       启用 stw/flush 楔死探针
#   ram : anon | memfd
#   disk: cp | overlay | none
#   net : slirp | none
#   cpus: 例如 0,1 或 6,7
set -eu
H=${H:-/data/data/com.termux/files/home/h}
TAG=${1:?tag}; BIN=${2:?binary}; RAM=${3:?anon|memfd}; DISK=${4:?cp|overlay|none}
NET=${5:?slirp|none}; CPUS=${6:?cpus}; SECS=${7:-600}; EXTRA=${8:-}
ACCELTRACE=${ACCELTRACE:-}
ACCELARG="henge"
[ -n "$ACCELTRACE" ] && ACCELARG="henge,trace=$ACCELTRACE"

D=$H/run-$TAG
SERIAL=$D.serial.log
STDERR=$D.stderr.log
SIDECAR=$D.sidecar.tsv

case "$RAM" in
  anon)  MEMARGS="-m 2048"; MACH="virt,gic-version=3" ;;
  memfd) MEMARGS="-m 2048 -object memory-backend-memfd,id=mem,size=2048M,share=on"
         MACH="virt,gic-version=3,memory-backend=mem" ;;
  *) echo "bad ram" >&2; exit 2 ;;
esac

case "$DISK" in
  cp)      DISKARGS="-drive if=none,id=d0,format=qcow2,file=$H/g-$TAG.qcow2 -device virtio-blk-pci,drive=d0" ;;
  overlay) DISKARGS="-drive if=none,id=d0,format=qcow2,file=$H/r-$TAG.qcow2 -device virtio-blk-pci,drive=d0" ;;
  none)    DISKARGS="" ;;
  *) echo "bad disk" >&2; exit 2 ;;
esac

case "$NET" in
  slirp) NETARGS="-netdev user,id=n0 -device virtio-net-pci,netdev=n0" ;;
  none)  NETARGS="" ;;
  *) echo "bad net" >&2; exit 2 ;;
esac

# 前置检查
[ -x "$BIN" ] || { echo "MISSING: $BIN" >&2; exit 3; }
[ -e /data/local/tmp/henge/bios/edk2-aarch64-code.fd ] || { echo "MISSING bios" >&2; exit 3; }
[ -e "$H/g-$TAG.img" ] || { echo "MISSING vars: $H/g-$TAG.img" >&2; exit 3; }

MD5=$(md5sum "$BIN" | cut -c1-16)
F0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo na)
F6=$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq 2>/dev/null || echo na)
TM=$(for z in /sys/class/thermal/thermal_zone*/temp; do [ -r "$z" ] && cat "$z" 2>/dev/null; done | sort -rn | head -1)
TM=${TM:-na}

rm -f "$SERIAL" "$STDERR" "$SIDECAR"
{
    echo "# run=$TAG bin=$(basename "$BIN") md5=$MD5 size=$(stat -c %s "$BIN")"
    echo "# argv: ram=$RAM disk=$DISK net=$NET cpus=$CPUS secs=$SECS"
    echo "# freq_at_start: cpu0=$F0 cpu6=$F6 temp=$TM"
    echo "# started: $(date '+%F %T')"
} > "$SERIAL"

nohup sh -c "exec env ${HVDBG:-} taskset -c $CPUS $BIN -L /data/local/tmp/henge/bios \
  -M $MACH -cpu max $MEMARGS -display none -no-reboot -smp 2 -accel $ACCELARG \
  -drive if=pflash,format=raw,unit=0,file=/data/local/tmp/henge/bios/edk2-aarch64-code.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=$H/g-$TAG.img \
  $DISKARGS $NETARGS \
  -serial file:$SERIAL -monitor none $EXTRA" \
  > "$STDERR" 2>&1 &
QPID=$!
echo "$QPID" > "$D.pid"

nohup "$H/sidecar.sh" "$QPID" "$SERIAL" "$SIDECAR" 10 >/dev/null 2>&1 &
nohup sh -c "sleep $SECS; kill -9 $QPID 2>/dev/null" >/dev/null 2>&1 &

sleep 1
echo "launched $TAG"
echo "  bin=$MD5 cpus=$CPUS ram=$RAM disk=$DISK net=$NET secs=$SECS accel=$ACCELARG ${HVDBG:-}"
echo "  qemu_pid=$QPID  freq: cpu0=$F0 cpu6=$F6 temp=$TM"
echo "  serial=$SERIAL"
echo "  sidecar=$SIDECAR"
