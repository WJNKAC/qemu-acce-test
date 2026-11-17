#!/system/bin/sh
# seedtest.sh - seed v2 的 reboot 循环：host 侧守株待兔
#
# 与 nrun2.sh 的根本区别：**reset 由 guest 自己发起**（netprobe 里 systemctl reboot
# → PSCI SYSTEM_RESET），host 侧只起一次进程、只读 serial。
#
# 这才是"guest 内 reboot"形态 —— system_reset 是 QEMU 侧硬复位，设备被拉到
# 冷态、驱动从头初始化，与 guest 内 reboot 走的 warm reset 路径不是一回事。
#
# 判据（全部在 serial 上，不需要登录）：
#   NETPROBE-BEGIN/END round=N   每轮探针完成（缺 END = 半途死）
#   NETPROBE-ADDR                地址拿到没有
#   NETPROBE-TCP-GW53/GW22       guest→slirp 数据面（TCP，不用 ping）
#   NETPROBE-CURL                full path（host 侧要起 10080 监听）
#   ci-info 网卡表               cloud-init 侧旁证（13.40）
#
# 断链检测：连续 3×OnBootSec(60s)=180s 没有新的 NETPROBE-BEGIN 就报警。
#
# 用法: seedtest.sh <tag> <bin> <max_rounds> [timeout_s] [smp] [seed.iso]
set -u
TAG=${1:?tag}
BIN=${2:?bin}
MAXR=${3:-4}
TMO=${4:-360}
SMP=${5:-2}
SEED=${6:-/data/local/tmp/seed-v2.iso}
H=/data/local/tmp
BIOS=$H/henge/bios
LOG=$H/st-$TAG.serial.log
ERR=$H/st-$TAG.err
VARS=$H/st-$TAG.img
DISK=$H/st-$TAG.qcow2
MPORT=${MPORT:-4460}

[ -x "$BIN" ] || { echo "MISSING $BIN"; exit 3; }
[ -f "$SEED" ] || { echo "MISSING $SEED"; exit 3; }
[ -x "$H/vclk" ] || { echo "MISSING vclk"; exit 3; }

cp -f $H/vars0.img "$VARS" 2>/dev/null; chmod 644 "$VARS" 2>/dev/null
# 磁盘必须用副本。直接挂 deb12.qcow2 会把 netprobe 三件套写进基线 ——
# 第一次试跑就是这么污染的：之后所有基于它的 overlay 都会自动 reboot。
# 基线 deb12-clean.qcow2 是 444，副本显式放开写权限（toybox 的 cp -f 保留源权限）。
cp -f ${DISK_SRC:-$H/deb12-clean.qcow2} "$DISK" 2>/dev/null; chmod 644 "$DISK" 2>/dev/null
rm -f "$LOG" "$ERR"

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
cleanup() { kill -9 $QP 2>/dev/null; }
trap cleanup EXIT HUP INT TERM

mon() { printf '%s\n' "$1" | timeout 3 nc 127.0.0.1 $MPORT 2>/dev/null; }

# 日志滚动。soak 一夜几百轮 × ~200KB 会写满 /data/local/tmp；
# 而 Android 的配额失败是静默的（df 显示有空间也可能已达媒体配额）。
# 策略：超过 MAXLOG 字节就把前半截掉，只留最近一轮的完整记录。
MAXLOG=${MAXLOG:-4000000}
roll_log() {
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "$sz" -le "$MAXLOG" ] && return
    cut=$((sz - MAXLOG / 2))
    tail -c +$cut "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
    echo "## LOG-ROLLED at ${sz}B (kept last $((sz - cut))B)" >> "$LOG"
}
cnt() { n=$(grep -ac "$1" "$LOG" 2>/dev/null); echo "${n:-0}"; }
# 去 ANSI 后的日志副本：systemd 的 [  OK  ] 行带颜色码，
# "Reached target ^[[0;1;39mmulti-user.target" 里 pattern 会被颜色码切断。
NOANSI=$LOG.noansi
strip_ansi() { sed -E 's/\x1b\[[0-9;]*m//g' "$LOG" > "$NOANSI" 2>/dev/null; }

# ---- boot_id 哨兵 ----
# 唯一能区分"QEMU 崩了"和"整机被重启/关机"的手段。
# 两者的现象完全一样（进程消失、serial 停止），但结论完全相反。
# ColorOS 有定时开关机（com.android.BBKCrontab），shell 权限禁不掉
# （pm disable-user 报 no root permission），所以不靠"关掉它"，靠"认出它"。
BID0=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
say_bid() { echo "$BID0"; }

set -- $($H/vclk); M0=$1; B0=$2
SUSP=0
say() { echo "$@"; }

say "=== seedtest tag=$TAG smp=$SMP max_rounds=$MAXR timeout=${TMO}s ==="
say "（reset 由 guest 内 systemctl reboot 发起，host 只读 serial）"

ELAPSED=0
LAST_ROUND=0
STALL=0
while [ $ELAPSED -lt $TMO ]; do
    RN=$(cnt 'NETPROBE-BEGIN')
    if [ "$RN" -gt "$LAST_ROUND" ]; then
        LAST_ROUND=$RN
        STALL=0
        say "--- round $RN (t=${ELAPSED}s) ---"
        # 取该轮 BEGIN 到 END 之间的段落。
        # 第一版用 `grep 'NETPROBE-.*round=N'`，只有 BEGIN/END 两行带 round=N，
        # 所以摘要只打出两行 BEGIN —— 判据全丢。改成 awk 按轮次切段。
        awk -v r="$RN" '
            /NETPROBE-BEGIN round=/ { if (match($0, /round=[0-9]+/)) cur = substr($0, RSTART+6, RLENGTH-6) }
            cur == r { if (match($0, /NETPROBE-[A-Z0-9-]+.*/)) print "  " substr($0, RSTART, RLENGTH) }
            /NETPROBE-END round=/ && cur == r { exit }
        ' "$LOG" 2>/dev/null | head -20
    fi
    [ "$RN" -ge "$MAXR" ] && break
    kill -0 $QP 2>/dev/null || { say "!! QEMU 退出（t=${ELAPSED}s）"; break; }

    # 断链检测：180s 无新轮次 = 卡住
    if [ "$RN" -ge 1 ] && [ "$STALL" -ge 180 ]; then
        say "!! STALL: ${STALL}s 无新 NETPROBE-BEGIN（最后是 round $RN）"
        say "   最后 5 行 serial："
        tail -5 "$LOG" 2>/dev/null | sed 's/^/   /'
        break
    fi

    # 整机重启检测：boot_id 变了 = 不是 QEMU 的问题
    BIDN=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    if [ -n "$BIDN" ] && [ "$BIDN" != "$BID0" ]; then
        say "!! DEVICE-REBOOTED: boot_id 变了（$BID0 -> $BIDN）"
        say "   这不是 QEMU crash —— 是整机重启/关机（ColorOS 定时开关机？）"
        say "   最后 5 行 serial："
        tail -5 "$LOG" 2>/dev/null | sed 's/^/   /'
        DEVREBOOT=1
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    STALL=$((STALL + 5))
done

sleep 2
kill -9 $QP 2>/dev/null
sleep 1
trap - EXIT HUP INT TERM

# ---- 汇总 ----
set -- $($H/vclk); M1=$1; B1=$2
# vclk 在 QEMU 已退出后调用，M/B 仍有效；但若读失败会给 -1，兜底成 0
DS=$(( (B1 - B0) - (M1 - M0) ))
[ "$DS" -lt 0 ] && DS=0

BEG=$(cnt 'NETPROBE-BEGIN'); END=$(cnt 'NETPROBE-END')
ADDR=$(cnt 'NETPROBE-ADDR')
# grep -c 零命中时同时打印 0 并返回 1，`|| echo 0` 会变成两行 —— 用 cnt()。
# 三态：ok=连上 / refused=收到 RST（网络通，端口无服务） / timeout=不通
REF=$(cnt 'state=refused')
TOUT=$(cnt 'state=timeout')
OKC=$(cnt 'state=ok')
C200=$(cnt 'NETPROBE-CURL code=200')
PERR=$(cnt 'PROBE-ERR')
CURLN=$(cnt 'NETPROBE-CURL')
strip_ansi
CI=$(cnt 'ci-info: | Device')
MU=$(grep -ac 'Reached target.*multi-user' "$NOANSI" 2>/dev/null); MU=${MU:-0}
SEEDINST=$(cnt 'HENGE-SEED-V2-INSTALLED')

say
say "=== 汇总 ==="
say "轮次: BEGIN=$BEG  END=$END   ci-info=$CI   multi-user=$MU   seed_installed=$SEEDINST"
say "地址行: $ADDR   curl200=$C200/$CURLN   TCP: 连上=$OKC 拒绝=$REF(RST=网络通) 超时=$TOUT"
say "探针异常: $PERR（数的是 err:* 与 PROBE-ERR，不是 refused/timeout）"
say "dsusp_ms=$DS  verdict=$( [ $DS -lt 1000 ] && echo VALID || echo INVALID )"
if [ "$BEG" -eq "$END" ] && [ "$BEG" -gt 0 ]; then
    say "完整性: 每轮都有 END —— 无半途死"
else
    say "完整性: BEGIN=$BEG != END=$END  ⚠ 有轮次中断"
fi
say "boot_id: 起始 $BID0   结束 $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
[ "${DEVREBOOT:-0}" = 1 ] && say "!! 判定: 整机重启过（不是 QEMU 的问题）"
if [ "$BEG" -gt 1 ]; then
    say "★ per-instance 坑已绕过：第 $BEG 轮仍在跑（cloud-init 模块早已失效）"
else
    say "⚠ 只跑到 $BEG 轮 —— 无法证明 per-instance 已绕过"
fi
