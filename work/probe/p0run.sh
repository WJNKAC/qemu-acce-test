#!/system/bin/sh
# p0run.sh - vivo 带盘 boot + 探针出口全开
#
# 与 vdisk.sh 的三个差别，每一条都是 13.34 那轮栽过的坑：
#
# 1) QEMU 的 stderr 不再进 /dev/null。vdisk.sh 写的是 `>/dev/null 2>&1`，
#    而 henge-p0a 的计数器全部打到 stderr —— 探针再对也读不到。
# 2) HV_STATS=n 打开 engine 的周期统计。移植层从来没设过 stats_interval，
#    于是 print_stats 从未运行，一半的计数器根本不被递增。
# 3) 每 5 秒采一次 mono/boot/rss（vclk），dsusp = ΔBOOT - ΔMONO，
#    >1s 即判本轮数据作废。vivo 没有 root，拿不到 /sys/power/wake_lock，
#    所以这里不假设"设备不会睡"，而是每轮都实测。
#
# 用法: p0run.sh <tag> <bin> [secs]
set -u
TAG=${1:?tag}
BIN=${2:?bin}
MAXS=${3:-150}
H=/data/local/tmp
BIOS=$H/henge/bios
LOG=$H/$TAG.log
ERR=$H/$TAG.err
SC=$H/$TAG.tsv
VARS=$H/$TAG.img
DISK=$H/$TAG.qcow2

[ -x "$BIN" ] || { echo "MISSING $BIN"; exit 3; }
[ -x "$H/vclk" ] || { echo "MISSING vclk"; exit 3; }

cp -f $H/vars0.img "$VARS" 2>/dev/null
qemu-img create -f qcow2 -b $H/deb12.qcow2 -F qcow2 "$DISK" >/dev/null 2>&1 || \
    cp -f $H/deb12.qcow2 "$DISK"
rm -f "$LOG" "$ERR" "$SC"

HV_STATS=${HV_STATS:-5}
export HV_STATS

$BIN -L "$BIOS" -M virt,gic-version=3 -cpu max -m 2048 \
    -display none -no-reboot -smp 2 -accel henge \
    -drive if=pflash,format=raw,unit=0,file=$BIOS/edk2-aarch64-code.fd,readonly=on \
    -drive if=pflash,format=raw,unit=1,file=$VARS \
    -drive if=none,id=d0,format=qcow2,file=$DISK -device virtio-blk-pci,drive=d0 \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -serial file:$LOG -monitor none >/dev/null 2>"$ERR" &
QP=$!

cleanup() { kill -9 $QP 2>/dev/null; }
trap cleanup EXIT HUP INT TERM

set -- $($H/vclk)
M0=$1; B0=$2
: > "$SC"
echo "t_s mono_d boot_d dsusp_cum rss_kb lines" >> "$SC"
SUSP=0
T0=$M0
FIRST=1

while kill -0 $QP 2>/dev/null; do
    set -- $($H/vclk $QP)
    M=$1; B=$2; R=$3
    DM=$((M - M0)); DB=$((B - B0))
    D=$((DB - DM - SUSP))
    [ $D -gt 0 ] && SUSP=$((SUSP + D))
    N=0
    [ -f "$LOG" ] && N=$(wc -l < "$LOG" 2>/dev/null)
    # 第一拍在 exec 之前，RSS 还是 shell 的 ~1MB，记为 0 以免污染 rss_start
    [ $FIRST = 1 ] && { R=0; FIRST=0; }
    echo "$((DM / 1000)) $DM $DB $SUSP $R $N" >> "$SC"
    [ $DM -ge $((MAXS * 1000)) ] && break
    sleep 5
done

kill -9 $QP 2>/dev/null
sleep 1
trap - EXIT HUP INT TERM

LINES=$(grep -av '^#' "$LOG" 2>/dev/null | wc -l)
BDS=$(grep -ac BdsDxe "$LOG" 2>/dev/null)
LNX=$(grep -ac 'Linux version' "$LOG" 2>/dev/null)
SYS=$(grep -ac 'systemd\[1\]' "$LOG" 2>/dev/null)
STALE=$(grep -ac 'henge-p0a: STALE' "$ERR" 2>/dev/null)
DELS=$(grep -ac 'henge-p0a: del#' "$ERR" 2>/dev/null)
LASTDEL=$(grep -a 'henge-p0a: del#' "$ERR" 2>/dev/null | tail -1)
RSS_END=$(tail -1 "$SC" | awk '{print $5}')
RSS_MAX=$(awk 'NR>1{if($5>m)m=$5}END{print m}' "$SC")

echo "TAG=$TAG BIN=$(basename $BIN) MAXS=$MAXS"
echo "lines=$LINES bds=$BDS linux=$LNX systemd=$SYS"
echo "dsusp_cum_ms=$SUSP   verdict=$( [ $SUSP -lt 1000 ] && echo VALID || echo INVALID )"
echo "rss_first=$(awk 'NR>1 && $5>0 {print $5; exit}' "$SC") rss_max=$RSS_MAX rss_end=$RSS_END"
echo "STALE_hits=$STALE del_probe_lines=$DELS"
echo "last: $LASTDEL"
