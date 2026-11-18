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
cnt() { n=$(grep -ac "$1" "$LOG" 2>/dev/null); echo "${n:-0}"; }

# ---- 累计计数：滚动时把被丢弃那段的计数搬进 ACC_* ----
# 原来汇总用"TSV 各列取 max"，那是**错的**：max 只是"某一瞬间的最大值"。
# 计数器是窗口局部的（roll 之后从 0 重数），所以 max ≈ 首次滚动前的量。
# 实测 night1：round 峰值 131，max(round) 却记成 66、max(curl200) 也停在 66 ——
# 看起来像"第 66 轮之后 curl 全坏了"，其实什么都没坏。
ACC_BEGIN=0; ACC_OK=0; ACC_REF=0; ACC_TO=0; ACC_C2=0; ACC_C0=0; ACC_ERR=0

_cc() { _n=$(grep -ac "$2" "$1" 2>/dev/null); echo "${_n:-0}"; }

roll_log() {
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "$sz" -le "$MAXLOG" ] && return
    # ⚠ 不能按字节切：`head -c/CUT` 可能切在行中间，那行判据在 head 里是
    # "NETPROBE-BEG"（不匹配）、在 tail 里是 "IN round=..."（也不匹配）——
    # **两边都不算，静默少一条**。改成按行切，边界天然对齐。
    tot=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    keep=$((tot / 2))
    [ "$keep" -lt 1 ] && return
    cut=$((tot - keep))          # cut = 要丢弃的行数
    head -n "$cut" "$LOG" > "$LOG.head" 2>/dev/null || return
    tail -n "$keep" "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
    ACC_BEGIN=$((ACC_BEGIN + $(_cc "$LOG.head" 'NETPROBE-BEGIN')))
    ACC_OK=$((ACC_OK    + $(_cc "$LOG.head" 'state=ok')))
    ACC_REF=$((ACC_REF  + $(_cc "$LOG.head" 'state=refused')))
    ACC_TO=$((ACC_TO    + $(_cc "$LOG.head" 'state=timeout')))
    ACC_C2=$((ACC_C2    + $(_cc "$LOG.head" 'code=200')))
    ACC_C0=$((ACC_C0    + $(_cc "$LOG.head" 'code=000')))
    ACC_ERR=$((ACC_ERR  + $(_cc "$LOG.head" 'state=err:')))
    rm -f "$LOG.head"
    # 自检：滚动后累计量必须只增不减
    _chk=$((ACC_BEGIN + $(_cc "$LOG" 'NETPROBE-BEGIN')))
    echo "## ROLLED at ${sz}B 累计BEGIN=$_chk" >> "$LOG"
}

# ---- 自检：滚动前后累计量必须守恒（SOAK_SELFTEST=1）----
# 放在这里是为了**在起 QEMU 之前**就能验，且验的是下面这段真代码，
# 不是另抄一份。没有这一步，"累加器"和"计数器"的口径不一致会静默存在。
if [ "${SOAK_SELFTEST:-0}" = "1" ]; then
    T=$(mktemp -d); LOG=$T/log; MAXLOG=1000
    : > "$LOG"
    # 行长刻意不一（用 i 控制填充长度），让"按字节切"必然切在行中间。
    i=0
    while [ $i -lt 40 ]; do
        pad=$(printf '%*s' $((i % 7 * 23)) '')
        echo "NETPROBE-BEGIN round=$i $pad" >> "$LOG"
        echo "NETPROBE-TCP-GW22 state=ok $pad" >> "$LOG"
        echo "NETPROBE-TCP-EXT state=ok" >> "$LOG"
        i=$((i+1))
    done
    B0=$(wc -c < "$LOG")
    roll_log; roll_log; roll_log
    B1=$(wc -c < "$LOG")
    CB=$((ACC_BEGIN + $(cnt 'NETPROBE-BEGIN')))
    CO=$((ACC_OK    + $(cnt 'state=ok')))
    echo "selftest: 写入 40 轮，日志 $B0 -> $B1 B（MAXLOG=$MAXLOG）"
    echo "selftest: ACC_BEGIN=$ACC_BEGIN 窗口=$(cnt 'NETPROBE-BEGIN') => 累计 $CB"
    echo "selftest: ACC_OK=$ACC_OK 窗口=$(cnt 'state=ok') => 累计 $CO"
    if [ "$CB" = 40 ] && [ "$CO" = 80 ]; then echo "selftest: PASS"; rc=0
    else echo "selftest: FAIL（应为 BEGIN=40 ok=80）"; rc=1; fi
    rm -rf "$T"; exit $rc
fi

for f in "$BIN" "$H/vclk" "$SEED" "$H/deb12-clean.qcow2"; do
    [ -e "$f" ] || { echo "MISSING $f"; exit 3; }
done

# VARS_SRC 见 seedtest.sh 同名变量说明。
VARS_SRC=${VARS_SRC:-$H/vars0.img}
cp -f "$VARS_SRC" "$VARS" 2>/dev/null; chmod 644 "$VARS" 2>/dev/null
cp -f $H/deb12-clean.qcow2 "$DISK" 2>/dev/null; chmod 644 "$DISK" 2>/dev/null
rm -f "$LOG" "$ERR" "$SC"
: > "$SC"
# 列序是契约，后面所有分析脚本按列号取值，只能往后加，不能插在中间。
# 1 t_s  2 round  3 rss_kb  4 dsusp_cum  5 ok  6 refused  7 timeout
# 8 curl200  9 curl000  10 err  11 lines  12 df_avail_kb
# 13 rss_smaps_kb  14 anon_kb  15 threads
#
# 为什么 3 和 13 读的是同一个进程却不一样：第 3 列走 /proc/pid/statm
# （内核 per-mm 的 rss 计数器，会漂），第 13 列走 /proc/pid/smaps_rollup
# （走页表重算，是地面真值）。实测同一瞬间 1235 MB vs 987 MB，差 250 MB。
# 两列并排存档，以后再遇到"RSS 涨了"就不用重跑，直接看是哪一列在涨。
echo "t_s round rss_kb dsusp_cum state_ok state_refused state_timeout curl200 curl000 probe_err lines df_avail_kb rss_smaps_kb anon_kb threads" >> "$SC"

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

# 启动抽成函数：停顿恢复要能"杀掉重来"。台面参数只有 vars 会换
# （UEFI 引导项累积/菜单卡死的现场，换一份干净 varstore 就绕开了）。
launch_vm() {
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
}
launch_vm
sleep 1

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


# monitor 命令。必须用 \r 结束：HMP 在无 PTY 的连接里按字符回显，
# 用 \n 会得到 "unknown command"（实测）。
mon() { printf '%s\r' "$1" | timeout 6 nc 127.0.0.1 "$MPORT" 2>/dev/null; }

# 停顿判定阈值（秒）。默认 900 = OnBootSec(60) 的 15 倍。
STALL_SEC=${STALL_SEC:-900}
RECOVER=0        # 1=回车救回；>1=重启救回（累加）
NRESTART=0
MAXRESTART=${MAXRESTART:-3}   # 连重启都救不回来，说明不是"掉菜单"这种形态，退出

set -- $($H/vclk); M0=$1; B0=$2
SUSP=0
LAST=0
STALL=0
CRASH=0
DEVRB=0

while [ "$(date +%s)" -lt "$END" ]; do
    RN=$((ACC_BEGIN + $(cnt 'NETPROBE-BEGIN')))
    set -- $($H/vclk $QP); M=$1; B=$2; R=$3
    DM=$((M - M0)); DB=$((B - B0))
    D=$((DB - DM - SUSP)); [ $D -gt 0 ] && SUSP=$((SUSP + D))
    DF=$(df /data 2>/dev/null | tail -1 | awk '{print $4}')
    N=$(grep -acv '^#' "$LOG" 2>/dev/null); N=${N:-0}
    # 最后一列是 err:<Type>，不是 'PROBE-ERR' —— 探针从来没打过那个串，
    # 数它等于永远 0（13.53 在 seedtest.sh 里改过一次，这里漏了，第五次同类）。
    SM=$(awk '/^Rss:/{print $2}' /proc/$QP/smaps_rollup 2>/dev/null)
    AN=$(awk '/^Anonymous:/{print $2}' /proc/$QP/smaps_rollup 2>/dev/null)
    TH=$(awk '/Threads/{print $2}' /proc/$QP/status 2>/dev/null)
    echo "$((DM/1000)) $RN ${R:--1} $SUSP $(cnt 'state=ok') $(cnt 'state=refused') $(cnt 'state=timeout') $(cnt 'code=200') $(cnt 'code=000') $(cnt 'state=err:') $N ${DF:-0} ${SM:-0} ${AN:-0} ${TH:-0}" >> "$SC"

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
    # 断链：连续 STALL_SEC 秒无新轮次
    if [ "$RN" -eq "$LAST" ]; then
        STALL=$((STALL + 10))
        if [ "$STALL" -ge "$STALL_SEC" ]; then
            {
                echo "!! STALL ${STALL}s at round=$RN"
                echo "--- 现场：monitor 状态 ---"
                mon "info status"
                echo "--- 现场：serial 最后 20 行 ---"
                tail -20 "$LOG" 2>/dev/null
            } >> $H/soak-$TAG.summary 2>/dev/null

            # 两级恢复。**顺序不能反，也不能只想第一级**：
            #
            #   1 级  sendkey ret：便宜，若停在"有可引导项的菜单"上就够。
            #   2 级  换干净 varstore 重启 QEMU：这一级才是兜底。
            #
            # 为什么必须有 2 级：13.59 我写"只要一个回车就能继续"，那是**假设**。
            # 那个菜单里的 5 个引导项本身就是坏的（每轮 `start failed`），
            # 回车很可能只是把坏项再试一遍 —— 所以 1 级失败不等于"救不了"，
            # 只是说明这条路对这个故障形态无效。
            # 换 varstore 重启是被对照实验 B 验证过的（干净 vars + 同一块盘 =
            # 正常启动），所以它能救。
            for _try in 1 2 3; do
                mon "sendkey ret" >/dev/null 2>&1
                sleep 20
                _new=$((ACC_BEGIN + $(cnt 'NETPROBE-BEGIN')))
                if [ "$_new" -gt "$RN" ]; then RECOVER=1; break; fi
                kill -0 $QP 2>/dev/null || break
            done
            if [ "$RECOVER" = 1 ]; then
                echo "## RECOVERED by sendkey ret (round $RN -> $_new)" >> $H/soak-$TAG.summary
                LAST=$_new; STALL=0
            elif [ "$NRESTART" -lt "$MAXRESTART" ]; then
                NRESTART=$((NRESTART + 1))
                {
                    echo "## RESTART #$NRESTART at round=$RN（回车无效，换干净 varstore 重启）"
                } >> $H/soak-$TAG.summary
                killtree "$QP"
                cp -f "$VARS_SRC" "$VARS" 2>/dev/null; chmod 644 "$VARS" 2>/dev/null
                launch_vm
                _w=0
                while [ "$_w" -lt 180 ]; do
                    sleep 10; _w=$((_w + 10))
                    _new=$((ACC_BEGIN + $(cnt 'NETPROBE-BEGIN')))
                    [ "$_new" -gt "$RN" ] && break
                    kill -0 $QP 2>/dev/null || break
                done
                if [ "$_new" -gt "$RN" ]; then
                    RECOVER=$((RECOVER + 1))
                    echo "## RECOVERED by restart (round $RN -> $_new)" >> $H/soak-$TAG.summary
                    LAST=$_new; STALL=0
                else
                    echo "!! 重启后仍无新轮次（${_w}s）—— 记录现场后退出" >> $H/soak-$TAG.summary
                    break
                fi
            else
                echo "!! 恢复失败：回车无效且已重启 $NRESTART 次 —— 退出" >> $H/soak-$TAG.summary
                break
            fi
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
# 累计量 = 滚动累加器 + 当前窗口。**不用 TSV 取 max** —— 那只是某一瞬间的值，
# night1 上它把 131 轮记成了 66 轮，读起来像"第 66 轮后 curl 全坏"。
BEG=$((ACC_BEGIN + $(cnt 'NETPROBE-BEGIN')))
ENDN=$(cnt 'NETPROBE-END')
OK=$((ACC_OK  + $(cnt 'state=ok')))
REF=$((ACC_REF + $(cnt 'state=refused')))
TO=$((ACC_TO  + $(cnt 'state=timeout')))
C2=$((ACC_C2  + $(cnt 'code=200')))
C0=$((ACC_C0  + $(cnt 'code=000')))
PE=$((ACC_ERR + $(cnt 'state=err:')))
{
echo "=== soak $TAG 汇总 ==="
echo "轮次: 累计 BEGIN=$BEG (滚动累加 $ACC_BEGIN + 当前窗口 $(cnt 'NETPROBE-BEGIN'))"
echo "探针: ok=$OK refused=$REF timeout=$TO  curl: 200=$C2 000=$C0  异常=$PE"
echo "dsusp_cum_ms=$SUSP  $( [ $SUSP -lt 1000 ] && echo VALID || echo INVALID )"
echo "crash=$CRASH devreboot=$DEVRB recovered=$RECOVER restarts=$NRESTART"
echo "bin_md5=$BINMD5  boot_id=$BID0"
echo "--- 三态判读（按 STATES.md）---"
echo "refused=$REF 是「网络通」的阳性证据（RST 需完整栈）；timeout=$TO 才是可疑信号。"
[ "$TO" -gt 0 ] && echo "⚠ 出现 timeout —— 需按 round 分布定性：前段(warm-up)/分散(竞态)/后段(累积)"
} | tee -a $H/soak-$TAG.summary
