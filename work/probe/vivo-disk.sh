#!/system/bin/sh
# vdisk.sh - vivo 上跑带盘 boot，测到 "Linux version" 与到 login 的时间。
set -u
TAG=${1:-vd}; BIN=${2:-/data/local/tmp/q-p0a}; MAXS=${3:-300}
H=/data/local/tmp; BIOS=$H/henge/bios
LOG=$H/$TAG.log; VARS=$H/$TAG.img; DISK=$H/$TAG.qcow2
cp -f $H/vars0.img "$VARS"
# overlay：每轮从同一 backing 起（写不污染）
qemu-img create -f qcow2 -b $H/deb12.qcow2 -F qcow2 "$DISK" >/dev/null 2>&1 || cp -f $H/deb12.qcow2 "$DISK"
rm -f "$LOG"
now_ms() { awk '{printf "%d", $1*1000}' /proc/uptime; }
T0=$(now_ms)
$BIN -L "$BIOS" -M virt,gic-version=3 -cpu max -m 2048 \
    -display none -no-reboot -smp 2 -accel henge \
    -drive if=pflash,format=raw,unit=0,file=$BIOS/edk2-aarch64-code.fd,readonly=on \
    -drive if=pflash,format=raw,unit=1,file=$VARS \
    -drive if=none,id=d0,format=qcow2,file=$DISK -device virtio-blk-pci,drive=d0 \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -serial file:$LOG -monitor none >/dev/null 2>&1 &
QP=$!
K=0; L=0
while kill -0 $QP 2>/dev/null; do
    [ $K = 0 ] && grep -aq 'Linux version' "$LOG" 2>/dev/null && { K=$(now_ms); }
    [ $L = 0 ] && grep -aqE 'login:|systemd\[1\]' "$LOG" 2>/dev/null && { L=$(now_ms); }
    NOW=$(now_ms); [ $((NOW-T0)) -gt $((MAXS*1000)) ] && break
    sleep 0.2
done
T1=$(now_ms); kill -9 $QP 2>/dev/null; sleep 1
fmt() { [ "$1" -gt 0 ] && echo "$(( ($1-T0)/1000 )).$(( ($1-T0)%1000/100 ))s" || echo "-"; }
echo "kernel@$(fmt ${K:-0})  userspace@$(fmt ${L:-0})  lines=$(grep -av '^#' "$LOG"|wc -l) bds=$(grep -ac BdsDxe "$LOG") linux=$(grep -ac 'Linux version' "$LOG")"
