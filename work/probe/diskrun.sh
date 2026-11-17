#!/bin/sh
# diskrun.sh - 带盘 run：UEFI + virtio-blk(qcow2) + seed iso，用于触发 P0-a 场景。
#
# 为什么单独一个脚本：13.28 定位到的代际混叠只在 pflash 反复 del+add
# 时发生，而无盘的 UEFI run 几乎不写变量存储，触发概率低。
# 带盘 + UEFI 变量轮询是它的高发场景。
#
# 铁律（13.26 之后的每个 run 都要）：先拿 wakelock，跑完用 sidecar 判 VALID。
#
# 用法: diskrun.sh <tag> <bin> [secs] [net]
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
BIOS=${BIOS:-/data/local/tmp/henge/bios}
TAG=${1:?tag}
BIN=${2:?bin}
SECS=${3:-400}
NET=${4:-slirp}

SER=$H/dk-$TAG.serial.log
ERR=$H/dk-$TAG.stderr.log
SC=$H/dk-$TAG.sidecar.tsv
VARS=$H/dk-$TAG.img
DISK=$H/dk-$TAG.qcow2

[ -x "$BIN" ] || { echo "MISSING $BIN" >&2; exit 3; }
cp -f $H/vars0.img "$VARS" 2>/dev/null
# overlay 让每轮从同一 backing 开始（写全落 overlay）
qemu-img create -f qcow2 -b $H/deb12.qcow2 -F qcow2 "$DISK" >/dev/null 2>&1 || \
    cp -f $H/deb12.qcow2 "$DISK" 2>/dev/null

NETARGS=""
[ "$NET" = slirp ] && NETARGS="-netdev user,id=n0 -device virtio-net-pci,netdev=n0"

rm -f "$SER" "$ERR" "$SC"
# 不用 -nographic：它把串口重定向到 stdio，于是 UEFI 输出全进 stderr，
# $SER 永远 0 行 —— 第一次跑就栽在这里，还差点误判成"guest 没启动"。
nohup sh -c "exec taskset -c 0,1 $BIN \
  -L $BIOS \
  -M virt,gic-version=3 -cpu max -m 2048 -display none -no-reboot -smp 2 -accel henge \
  -drive if=pflash,format=raw,unit=0,file=$BIOS/edk2-aarch64-code.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=$VARS \
  -drive if=none,id=d0,format=qcow2,file=$DISK -device virtio-blk-pci,drive=d0 \
  -serial file:$SER \
  $NETARGS" > "$ERR" 2>&1 &
QP=$!
echo $QP > $H/dk.pid

sh $H/sidecar.sh "$QP" "$SER" "$SC" 10 >/dev/null 2>&1 &
SCP=$!

T0=$(python3 -c 'import time; print(int(time.clock_gettime(time.CLOCK_MONOTONIC)))')
python3 -c "import time; time.sleep($SECS)" 2>/dev/null
T1=$(python3 -c 'import time; print(int(time.clock_gettime(time.CLOCK_MONOTONIC)))')

# 先看有没有 SIGSEGV（这是 P0-a 的直接症状）
ALIVE=$(kill -0 "$QP" 2>/dev/null && echo YES || echo NO)
kill -9 "$QP" 2>/dev/null
sleep 1
kill -9 "$SCP" 2>/dev/null

N=$(grep -av '^#' "$SER" 2>/dev/null | wc -l)
B=$(grep -ac BdsDxe "$SER" 2>/dev/null)
L=$(grep -ac 'Linux version' "$SER" 2>/dev/null)
SEGV=$(grep -ac 'Segmentation\|SIGSEGV' "$ERR" 2>/dev/null)
SUSP=$(awk -F'\t' 'NR>1 && $17+0>m {m=$17+0} END{print m+0}' "$SC" 2>/dev/null)

VALID=YES
[ "${SUSP:-0}" -gt 1000 ] && VALID=NO

printf "tag=%s bin=%s alive=%s segv=%s valid=%s susp=%sms real=%ss serial=%s bds=%s linux=%s\n" \
    "$TAG" "$(basename "$BIN")" "$ALIVE" "${SEGV:-0}" "$VALID" "${SUSP:-0}" "$((T1 - T0))" "$N" "$B" "$L"
[ "${SEGV:-0}" -gt 0 ] && { echo "--- SIGSEGV 现场 ---"; grep -A4 'Segmentation\|SIGSEGV' "$ERR" | head -12; }
