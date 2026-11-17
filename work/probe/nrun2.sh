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
#   bds      UEFI BDS 起来就 reset        ~8s/轮   最快，测 UEFI 阶段的槽位语义
#   linux    "Linux version" 出现         ~14s/轮  测内核早期 + retired_hit
#   net      cloud-init 的 ci-info 网卡表 ~76s/轮  **C6 用它**：表里有 DHCP 结果
#   systemd  multi-user.target            ~110s/轮 端到端可用
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
    # ci-info 的网卡表头。cloud-init 每次 boot 打一次，t≈76s，
    # 表里的 enp0s1 行直接给出 DHCP 拿到的地址或 False。
    net)     MPAT='ci-info: | Device |' ;;
    # 不用 'systemd\[1\]' —— boot 过程中每个 unit 都打一行，里程碑判据
    # 就不唯一了（第一次试跑 round 1 就数到 4，等于没等）。
    systemd) MPAT='Reached target multi-user.target' ;;
    *) echo "bad milestone: $MILE (bds|linux|net|systemd)"; exit 2 ;;
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

# 基线 vars0.img 是 444（防误当工作文件）；toybox 的 cp -f 会
# 保留源权限，所以目标必须显式放开写权限，否则 QEMU 打不开 varstore。
cp -f $H/vars0.img "$VARS" 2>/dev/null; chmod 644 "$VARS" 2>/dev/null
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
    # 掉 UEFI Shell 是一个假阳性源：BdsDxe 没找到可引导项时会停在
    # "UEFI Interactive Shell"，而那里既没有 Linux version 也没有 ci-info，
    # 看起来完全像"boot 失败"。必须单独标出来，否则会被当成 C6。
    # （实测发生一次：Boot0001 从 "UEFI Misc Device" 变成了
    #   "EFI Internal Shell"，nvram 里的引导项变了。）
    if [ "$RES" = timeout ] && grep -aq 'UEFI Interactive Shell' "$LOG" 2>/dev/null; then
        RES=UEFI-SHELL
    fi
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

# ---- C6 专用：每轮 DHCP 结果 ----
# ci-info 的网卡表每次 boot 打一次，一行一台设备。判据是 enp0s1 那一行：
#   | enp0s1 | True  | 10.0.2.15 | ...   ← DHCP 成功
#   | enp0s1 | False | .         | ...   ← 没起来（C6 的症状）
# 这套判据不需要登录、不需要抓包、不需要改镜像 —— 它一直就在 serial 里，
# 只是我之前只把它当"cloud-init 噪声"（13.34 的 diff 分类里正是这么写的）。
if [ "$MILE" = net ]; then
    echo
    echo "=== C6: 每轮 DHCP 结果 ==="
    # 不要写死空格宽度。第一版写成 'enp0s1 | True  | 10\.'（True 后两个空格），
    # 而实际是 '| True |         10.0.2.15'（一个空格 + 列对齐），永远不匹配，
    # 于是 4/4 全部拿到地址的一轮被判定成"C6 复现"。用 .* 跨过对齐。
    # 这就是"判据非空"的第三次具体化：非空、唯一、而且**匹配要宽于格式**。
    UP=$(grep -ac 'enp0s1 | True.*10\.0\.2\.15' "$LOG" 2>/dev/null)
    DOWN=$(grep -ac 'enp0s1 | False' "$LOG" 2>/dev/null)
    echo "enp0s1 拿到 10.0.2.15 的次数=$UP   标记 False 的次数=$DOWN   轮数=$ROUND"
    echo "（每轮 ci-info 打一次网卡表，所以 UP 应等于轮数）"
    grep -a 'enp0s1 | True.*10\.0\.2\.15' "$LOG" 2>/dev/null | sed -E 's/.*ci-info: //' | head -$ROUND
    if [ "$UP" -ge "$ROUND" ]; then
        echo "判定: $UP/$ROUND 轮拿到 IPv4 —— 本轮未复现 C6"
    elif [ "$UP" -eq 0 ]; then
        echo "判定: 0/$ROUND 拿到 IPv4 —— 需要确认是 C6 还是 boot 本身失败（看 UEFI-SHELL / lines）"
    else
        echo "判定: $UP/$ROUND 拿到 IPv4 —— C6 部分复现"
    fi
fi
