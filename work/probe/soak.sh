#!/system/bin/sh
# soak.sh - 整夜 reboot 循环，采 freq / RSS / dsusp 三列，并在进程消失时留现场
#
# 与 seedtest.sh 的区别：不是"跑 N 轮就停"，而是"跑到时间到"。
# soak 的价值不在"轮数多"，在**过夜长窗口独有的尾部行为**：
#   泄漏累积、竞态累积、进程崩溃。
#
# 三类仪器故障的防护都已预埋：
#   1. 整机重启 vs QEMU crash —— boot_id 哨兵（二者现象相同、结论相反）
#   2. 存储静默失败 —— 日志滚动 + 每轮 df 检查
#   3. doze 污染 —— dsusp 列，>1s 的区间不计入
#
# 用法: soak.sh <tag> <bin> <hours> [smp] [seed.iso]
set -u
TAG=${1:?tag}
BIN=${2:?bin}
HOURS=${3:-8}
SMP=${4:-2}
SEED=${5:-/data/local/tmp/seed-v2.iso}
H=/data/local/tmp
BIOS=$H/henge/bios
LOG=$H/soak-$TAG.serial.log
ERR=$H/soak-$TAG.err
SC=$H/soak-$TAG.tsv
VARS=$H/soak-$TAG.img
DISK=$H/soak-$TAG.qcow2
MPORT=${MPORT:-4470}
MAXLOG=${MAXLOG:-8000000}       # serial 滚动阈值（保最近 ~40 轮）
END=$(( $(date +%s) + HOURS * 3600 ))

for f in "$BIN" "$H/vclk" "$SEED" "$H/deb12-clean.qcow2"; do
    [ -e "$f" ] || { echo "MISSING $f"; exit 3; }
done

cp -f $H/vars0.img "$VARS" 2>/dev/null; chmod 644 "$VARS" 2>/dev/null
cp -f $H/deb12-clean.qcow2 "$DISK" 2>/dev/null; chmod 644 "$DISK" 2>/dev/null
rm -f "$LOG" "$ERR" "$SC"
: > "$SC"
echo "t_s round rss_kb dsusp_cum state_ok state_refused state_timeout curl200 curl000 probe_err lines df_avail_kb" >> "$SC"

BID0=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
BINMD5=$(md5sum "$BIN" 2>/dev/null | awk '{print $1}')

HV_STATS=${HV_STATS:-3600}
export HV_STATS

$BIN -L "$BIOS" -M virt,gic-version=3 -cpu max -m 2048 \
    -display none -smp "$SMP" -accel henge \
    -drive if=pflash,format=raw,unit=0,file=$BIOS/edk2-aarch64-code.fd,readonly=on \
    -drive if=pflash,format=raw,unit=1,file=$VARS \
    -drive if=none,id=d0,format=qcow2,file=$DISK -device virtio-blk-pci,drive=d0 \
    -drive if=none,id=sd,format=raw,file=$SEED -device virtio-blk-pci,drive=sd \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -serial file:$LOG -monitor tcp:127.0.0.1:$MPORT,server,nowait \
    >/dev/null 2>"$ERR" &
QP=$!

cleanup() {
    kill -9 $QP 2>/dev/null
    # 留现场：进程怎么死的，比"死没死"重要
    echo "=== soak $TAG 结束 ($(date -u +%FT%TZ)) ===" >> $H/soak-$TAG.summary
}
trap cleanup EXIT HUP INT TERM

cnt() { n=$(grep -ac "$1" "$LOG" 2>/dev/null); echo "${n:-0}"; }
roll_log() {
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "$sz" -le "$MAXLOG" ] && return
    cut=$((sz - MAXLOG / 2))
    tail -c +$cut "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
}

set -- $($H/vclk); M0=$1; B0=$2
SUSP=0
LAST=0
STALL=0
CRASH=0
DEVRB=0

while [ "$(date +%s)" -lt "$END" ]; do
    RN=$(cnt 'NETPROBE-BEGIN')
    set -- $($H/vclk $QP); M=$1; B=$2; R=$3
    DM=$((M - M0)); DB=$((B - B0))
    D=$((DB - DM - SUSP)); [ $D -gt 0 ] && SUSP=$((SUSP + D))
    DF=$(df /data 2>/dev/null | tail -1 | awk '{print $4}')
    N=$(grep -acv '^#' "$LOG" 2>/dev/null); N=${N:-0}
    echo "$((DM/1000)) $RN ${R:--1} $SUSP $(cnt 'state=ok') $(cnt 'state=refused') $(cnt 'state=timeout') $(cnt 'code=200') $(cnt 'code=000') $(cnt 'PROBE-ERR') $N ${DF:-0}" >> "$SC"

    # --- 三类仪器故障 ---
    BIDN=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    if [ -n "$BIDN" ] && [ "$BIDN" != "$BID0" ]; then
        echo "!! DEVICE-REBOOTED boot_id $BID0 -> $BIDN at t=$((DM/1000))s round=$RN" | tee -a $H/soak-$TAG.summary
        tail -20 "$LOG" >> $H/soak-$TAG.summary 2>/dev/null
        DEVRB=1; break
    fi
    if ! kill -0 $QP 2>/dev/null; then
        CRASH=1
        {
            echo "!! QEMU-EXITED at t=$((DM/1000))s round=$RN (boot_id 未变 => 进程侧)"
            echo "--- err 尾 30 行 ---"; tail -30 "$ERR" 2>/dev/null
            echo "--- serial 尾 60 行 ---"; tail -60 "$LOG" 2>/dev/null
            echo "--- 是否有 fatal/signal ---"; grep -aE "signal|fatal|abort|Assertion|segmentation" "$ERR" "$LOG" 2>/dev/null | tail -10
        } >> $H/soak-$TAG.summary
        break
    fi
    # 断链：15 分钟无新轮次（OnBootSec=60 的 15 倍）
    if [ "$RN" -eq "$LAST" ]; then
        STALL=$((STALL + 10))
        if [ "$STALL" -ge 900 ]; then
            echo "!! STALL ${STALL}s at round=$RN" | tee -a $H/soak-$TAG.summary
            tail -20 "$LOG" >> $H/soak-$TAG.summary 2>/dev/null
            break
        fi
    else
        LAST=$RN; STALL=0
    fi
    roll_log
    sleep 10
done

kill -9 $QP 2>/dev/null
sleep 1
trap - EXIT HUP INT TERM

# ---- 汇总 ----
BEG=$(cnt 'NETPROBE-BEGIN'); ENDN=$(cnt 'NETPROBE-END')
OK=$(cnt 'state=ok'); REF=$(cnt 'state=refused'); TO=$(cnt 'state=timeout')
C2=$(cnt 'code=200'); C0=$(cnt 'code=000'); PE=$(cnt 'PROBE-ERR')
{
echo "=== soak $TAG 汇总 ==="
echo "轮次: BEGIN=$BEG END=$ENDN  探针: ok=$OK refused=$REF timeout=$TO  curl: 200=$C2 000=$C0  异常=$PE"
echo "dsusp_cum_ms=$SUSP  $( [ $SUSP -lt 1000 ] && echo VALID || echo INVALID )"
echo "crash=$CRASH devreboot=$DEVRB"
echo "bin_md5=$BINMD5  boot_id=$BID0"
echo "--- 三态判读（按 STATES.md）---"
echo "refused=$REF 是「网络通」的阳性证据（RST 需完整栈）；timeout=$TO 才是可疑信号。"
[ "$TO" -gt 0 ] && echo "⚠ 出现 timeout —— 需按 round 分布定性：前段(warm-up)/分散(竞态)/后段(累积)"
} | tee -a $H/soak-$TAG.summary
