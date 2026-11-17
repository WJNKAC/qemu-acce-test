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
# 13.55：Android 没有 /etc/resolv.conf，libslirp 的 get_dns_addr() 恒失败。
# 打过 0002 的二进制（q-p0a9+）读这个变量补上上游 DNS。老二进制不 getenv 它。
SLIRP_DNS_SERVER=${SLIRP_DNS_SERVER-223.5.5.5}
[ -n "$SLIRP_DNS_SERVER" ] && export SLIRP_DNS_SERVER
MAXLOG=${MAXLOG:-8000000}       # serial 滚动阈值（保最近 ~40 轮）
# ⚠ POSIX 的 $(( )) 只做整数算术：HOURS=0.06 会直接报
#   `0.06: unexpected '.'` 然后整个脚本不干活（而且不留 serial 日志，
#   现场看起来像"刚启动就退了"）。要支持小数，得先算成整数秒。
HOURS_SEC=$(awk -v h="$HOURS" 'BEGIN { printf "%d", h * 3600 }' 2>/dev/null)
case "$HOURS_SEC" in
    ''|*[!0-9]*) echo "soak: HOURS=$HOURS 不是正数"; exit 2 ;;
esac
[ "$HOURS_SEC" -gt 0 ] || { echo "soak: HOURS=$HOURS 折算成 $HOURS_SEC 秒，太短"; exit 2; }
END=$(( $(date +%s) + HOURS_SEC ))

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

# host 侧 10080 监听。soak 原来完全没有这一段 —— 于是 curl-GW 每轮都是 000，
# 一整列计数器等于不存在（"计数器数不到它，等于没有它"，13.54 同款）。
# 与 seedtest.sh 同一套：printf 算十六进制、查 tcp/tcp6 的 LISTEN、父进程写 pidfile。
LHEX=$(printf '%04X' 10080)
LPFILE=$H/soak-$TAG.listen.pid
if awk 'NR>1 && $4=="0A" {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -qi ":${LHEX}$"; then
    echo "!! 10080(0x$LHEX) 已被占用 —— 沿用现有监听者，curl-GW 读数不由本脚本担保"
else
    ( while true; do
        printf 'HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK' \
          | timeout 30 nc -l -p 10080 -q1 >/dev/null 2>&1
        sleep 1
      done ) >/dev/null 2>&1 &
    LPID=$!
    echo "$LPID" > "$LPFILE"
    sleep 1
fi

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

killtree() {
    for _k in $(pgrep -P "$1" 2>/dev/null); do killtree "$_k"; done
    kill -9 "$1" 2>/dev/null
}

cleanup() {
    killtree "$QP"
    [ -n "${LPID:-}" ] && killtree "$LPID"
    if [ -f "${LPFILE:-/nonexistent}" ]; then
        _lp=$(cat "$LPFILE" 2>/dev/null)
        if [ -n "$_lp" ] && [ "$_lp" != "$$" ] && [ "$_lp" != "1" ]; then killtree "$_lp"; fi
        rm -f "$LPFILE"
    fi
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
    # 最后一列是 err:<Type>，不是 'PROBE-ERR' —— 探针从来没打过那个串，
    # 数它等于永远 0（13.53 在 seedtest.sh 里改过一次，这里漏了，第五次同类）。
    echo "$((DM/1000)) $RN ${R:--1} $SUSP $(cnt 'state=ok') $(cnt 'state=refused') $(cnt 'state=timeout') $(cnt 'code=200') $(cnt 'code=000') $(cnt 'state=err:') $N ${DF:-0}" >> "$SC"

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

cleanup
sleep 1
trap - EXIT HUP INT TERM

# ---- 汇总 ----
# ⚠ roll_log 会把日志前半截掉，`cnt` 是从当前日志现数的 —— 滚动后数会**倒退**，
# 于是"整夜跑了多少轮"会被读成最后一屏的量。所以汇总取 TSV 各列的 **max**
# （每 10 s 采一次快照，滚动前后的峰值即累计量；它仍是下界，不是精确值）。
# 列序（见文件头）：1 t_s  2 round  3 rss_kb  4 dsusp  5 ok  6 refused  7 timeout
#                   8 curl200  9 curl000  10 err  11 lines  12 df
# 只取 2/5/6/7/8/9/10 —— 3、4 不能取 max（rss 会回落，dsusp 本来就是累计量）。
# 不用 heredoc：它的终止符必须顶格独占一行，而这里原先写成
# `$(awk ... )EOF` —— 判定为未闭合，脚本静默走完却没产出汇总。
# set -u 抓不到这种错（不是未定义变量），直接 set -- 最稳。
set -- $(awk 'NR>1 {
    if ($2+0 > r) r = $2+0
    if ($5+0 > m5) m5 = $5+0; if ($6+0 > m6) m6 = $6+0; if ($7+0 > m7) m7 = $7+0
    if ($8+0 > m8) m8 = $8+0; if ($9+0 > m9) m9 = $9+0; if ($10+0 > m10) m10 = $10+0
} END { printf "%d %d %d %d %d %d %d", r, m5, m6, m7, m8, m9, m10 }' "$SC" 2>/dev/null)
RMAX=${1:-0}; OK=${2:-0}; REF=${3:-0}; TO=${4:-0}; C2=${5:-0}; C0=${6:-0}; PE=${7:-0}
# BEGIN/END 直接数日志只是"当前窗口内"的量（滚动后必然小于 RMAX），留作参照。
BEG=$(cnt 'NETPROBE-BEGIN'); ENDN=$(cnt 'NETPROBE-END')
{
echo "=== soak $TAG 汇总 ==="
echo "轮次: 累计(TSV max)=$RMAX   当前日志窗口内 BEGIN=$BEG END=$ENDN"
echo "探针: ok=$OK refused=$REF timeout=$TO  curl: 200=$C2 000=$C0  异常=$PE   ← 均为累计下界"
echo "dsusp_cum_ms=$SUSP  $( [ $SUSP -lt 1000 ] && echo VALID || echo INVALID )"
echo "crash=$CRASH devreboot=$DEVRB"
echo "bin_md5=$BINMD5  boot_id=$BID0"
echo "--- 三态判读（按 STATES.md）---"
echo "refused=$REF 是「网络通」的阳性证据（RST 需完整栈）；timeout=$TO 才是可疑信号。"
[ "$TO" -gt 0 ] && echo "⚠ 出现 timeout —— 需按 round 分布定性：前段(warm-up)/分散(竞态)/后段(累积)"
} | tee -a $H/soak-$TAG.summary
