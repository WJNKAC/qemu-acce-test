#!/system/bin/sh
# nrun2.sh - 单进程连续 system_reset：跨 boot 序列测试
#
# 为什么必须"单进程"：每次重启 QEMU 进程的短跑，对 reset 相关的问题永远
# 零判别力 —— JIT 块缓存、page_gen、RAM 槽位的 epoch 都随进程一起清空
# 重建。只有同一个进程里的连续 reset，才会让"第 N 轮还带着第 N-1 轮的
# 残留"这件事第一次成为可能。
#
# 服务的三个问题（一把梯子）：
#   C6   重启丢网 —— 复现形态就是重启序列
#   C2/C5 多核弱序 —— 唯一可观测形态是 smp2+ 连续 reset
#   序列泄漏 —— 单 boot 的 RSS 平台期不能外推到多 reset
#
# 通道：-monitor tcp:127.0.0.1:$MPORT 发 system_reset。
# 不用 guest 内 reboot：那要能登录，而登录本身是 C6 的受害者。
#
# 用法：nrun2.sh <tag> <bin> <rounds> [secs_per_round] [smp] [milestone]
#
# milestone 决定每轮 reset 的时机，直接决定这个测试能回答什么：
#   bds      UEFI BDS 起来就 reset        ~6s/轮   最快，测 UEFI 阶段的槽位语义
#   linux    "Linux version" 出现         ~14s/轮  测内核早期 + P0-a/retired_hit
#   systemd  systemd[1] 出现              ~110s/轮 测 C6（重启丢网）必须用它
#
set -u
TAG=${1:?tag}
BIN=${2:?bin}
ROUNDS=${3:-5}
SECS=${4:-120}
SMP=${5:-2}
MILE=${6:-linux}

case "$MILE" in
    bds)     MPAT='BdsDxe: starting' ;;
    linux)   MPAT='Linux version' ;;
    systemd) MPAT='systemd\[1\]' ;;
    *) echo "bad milestone: $MILE (bds|linux|systemd)"; exit 2 ;;
esac

# 验收（每次运行都打印）：
#   - 每轮是否到 Linux / systemd（成功率）
#   - RSS 曲线是否跨轮上涨（第 N 轮终值 vs 第 1 轮终值）
#   - del_hit / ram_reuse 是否随轮数线性增长（每轮 ~5 / ~4）
#   - retired_hit 是否恒为 0（它非 0 = 真的踩到了 del 退役窗口的 NULL）
set -u
TAG=${1:?tag}
BIN=${2:?bin}
ROUNDS=${3:-5}
SECS=${4:-120}
SMP=${5:-2}
H=/data/local/tmp
BIOS=$H/henge/bios
LOG=$H/nr-$TAG.serial.log
ERR=$H/nr-$TAG.err
SC=$H/nr-$TAG.tsv
VARS=$H/nr-$TAG.img
DISK=$H/nr-$TAG.qcow2
MPORT=${MPORT:-4455}

[ -x "$BIN" ] || { echo "MISSING $BIN"; exit 3; }
[ -x "$H/vclk" ] || { echo "MISSING vclk"; exit 3; }

cp -f $H/vars0.img "$VARS" 2>/dev/null
qemu-img create -f qcow2 -b $H/deb12.qcow2 -F qcow2 "$DISK" >/dev/null 2>&1 || \
    cp -f $H/deb12.qcow2 "$DISK"
rm -f "$LOG" "$ERR" "$SC"

# 统计类计数器默认开着（3600 秒一打，不刷屏），但这里要它每一轮都打一次：
# 用 HV_STATS 设成小于单轮时长的值，让每轮至少一组数字。
HV_STATS=${HV_STATS:-60}
export HV_STATS

# 去掉 -no-reboot：system_reset 要真的重来。
$BIN -L "$BIOS" -M virt,gic-version=3 -cpu max -m 2048 \
    -display none -smp "$SMP" -accel henge \
    -drive if=pflash,format=raw,unit=0,file=$BIOS/edk2-aarch64-code.fd,readonly=on \
    -drive if=pflash,format=raw,unit=1,file=$VARS \
    -drive if=none,id=d0,format=qcow2,file=$DISK -device virtio-blk-pci,drive=d0 \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
    -serial file:$LOG -monitor tcp:127.0.0.1:$MPORT,server,nowait \
    >/dev/null 2>"$ERR" &
QP=$!

cleanup() { kill -9 $QP 2>/dev/null; }
trap cleanup EXIT HUP INT TERM

# grep -c 在零命中时既打印 "0" 又返回 1，所以不能写 `|| echo 0`，
# 那会得到两行 "0" 让后面的 -ge 比较炸掉。
cnt() { n=$(grep -ac "$1" "$LOG" 2>/dev/null); echo "${n:-0}"; }
mon() { printf '%s\n' "$1" | timeout 3 nc 127.0.0.1 $MPORT 2>/dev/null; }

set -- $($H/vclk)
M0=$1; B0=$2
SUSP=0
: > "$SC"
echo "round t_s mono_d boot_d dsusp_cum rss_kb lines linux_n systemd_n" >> "$SC"

sample() {   # $1 = round
    # 先把轮次存下来：下面那句 set -- 会把它覆盖掉（vclk 的输出占了 $1..$3）。
    # 这个坑让第一版 tsv 的第一列变成了 mono_ms，round1 的 RSS 也就取不到了。
    RW=$1
    set -- $($H/vclk $QP)
    M=$1; B=$2; R=$3
    DM=$((M - M0)); DB=$((B - B0))
    D=$((DB - DM - SUSP))
    [ $D -gt 0 ] && SUSP=$((SUSP + D))
    L=0; [ -f "$LOG" ] && L=$(wc -l < "$LOG" 2>/dev/null)
    # 列: round t_s mono_d boot_d dsusp_cum rss_kb lines 里程碑次数 systemd_n
    echo "$RW $((DM/1000)) $DM $DB $SUSP $R $L $(cnt "$MPAT") $(cnt 'systemd\[1\]')" >> "$SC"
}

# 等里程碑的累计次数到 $1，超时 $2 秒。
# 不写成 wait_until "命令字符串" —— $($1) 不会重新解析引号，
# 会把 'Linux 和 version' 当成两个带字面引号的参数传给 grep，永远匹配不到。
# 第一版就这么写的，于是每轮都报 timeout，而 tsv 里计数明明是 1。
wait_mile() {
    W=0
    while [ $W -lt $(($2 * 2)) ]; do
        [ "$(cnt "$MPAT")" -ge "$1" ] && return 0
        kill -0 $QP 2>/dev/null || return 2
        W=$((W + 1))
        sleep 0.5
    done
    return 1
}

echo "=== nrun2 tag=$TAG bin=$(basename $BIN) rounds=$ROUNDS smp=$SMP secs/round=$SECS ==="
ROUND=0
OK=0
while [ $ROUND -lt $ROUNDS ]; do
    ROUND=$((ROUND + 1))
    WANT=$ROUND        # 第 N 轮要有 N 次 "Linux version"

    # 本轮：等里程碑（第 $WANT 次）
    if wait_mile $WANT $SECS; then
        RES=$MILE
        OK=$((OK + 1))
    else
        RES=timeout
    fi
    sample $ROUND
    RSS=$(tail -1 "$SC" | awk '{print $6}')
    echo "round $ROUND: $RES  mile_n=$(cnt "$MPAT") systemd_n=$(cnt 'systemd\[1\]') rss=${RSS}KB"

    [ $ROUND -ge $ROUNDS ] && break
    # 发 reset
    mon system_reset >/dev/null 2>&1
    sleep 2
    # 确认还在跑（reset 失败会让 QEMU 退出）
    kill -0 $QP 2>/dev/null || { echo "!! QEMU 在 reset 后退出"; break; }
done

# 收尾采样后关闭
sleep 3
sample $ROUND
kill -9 $QP 2>/dev/null
sleep 1
trap - EXIT HUP INT TERM

# ---- 汇总 ----
LNX=$(cnt 'Linux version'); SYS=$(cnt 'systemd\[1\]'); MILES=$(cnt "$MPAT")
LINES=$(grep -acv '^#' "$LOG")
DH=$(grep -a 'del#[0-9]' "$ERR" 2>/dev/null | tail -1)
RET=$(grep -ac 'RETIRED-window' "$ERR" 2>/dev/null)
SCPLUS=$(grep -ac 'del#[0-9]' "$ERR" 2>/dev/null)
# 同相位对比：第 1 轮与最后一轮到达**同一里程碑**时的 RSS，才有可比性。
RSS1=$(awk '$1==1{print $6}' "$SC" | head -1)
RSSN=$(awk -v r=$ROUND '$1==r{print $6}' "$SC" | head -1)

echo
echo "=== 汇总 (milestone=$MILE) ==="
echo "轮数=$ROUND 成功到 $MILE=$OK/$ROUND"
echo "serial: lines=$LINES  mile_n=$MILES  linux_n=$LNX  systemd_n=$SYS"
echo "dsusp_cum_ms=$SUSP  verdict=$( [ $SUSP -lt 1000 ] && echo VALID || echo INVALID )"
echo "rss@mile round1=${RSS1}KB  round$ROUND=${RSSN}KB  delta=$((RSSN - RSS1))KB"
echo "retired_hit(总)=$RET   del 探针行=$SCPLUS"
echo "末次 del 计数: $DH"
echo "（验收：del_hit 应随轮数增长；retired_hit 必须 0；rss delta 是序列泄漏的唯一读法）"
