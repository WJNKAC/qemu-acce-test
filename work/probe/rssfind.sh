#!/system/bin/sh
# rssfind.sh - RSS 增长的层次定位：每轮里程碑处按 VMA 汇总 RSS
#
# 为什么需要它：nrun2 的 RSS 曲线只能证明"跨轮累积 +67MB"，不能说明在谁身上。
# 三层的判据分别是：
#   引擎侧   → err 里的 "blocks held / JIT MB"（已排除：11 条 stats 无累积趋势）
#   QEMU 侧  → smaps 里非 [anon] 的具名映射（RAMBlock、ROM blob、dirty bitmap 都在这）
#   guest RAM→ smaps 里那条 2GB 的匿名大块（QEMU 的 pc.ram）
#
# 汇总口径：按 /proc/pid/smaps 的 header 名称聚合 Rss，取 top 12。
# 匿名大块没有名字（显示空白），统一记为 [anon]，因为 QEMU 的 RAMBlock 就是这种。
#
# 用法：rssfind.sh <tag> <bin> <rounds> [secs] [smp] [milestone]
set -u
TAG=${1:?tag}
BIN=${2:?bin}
ROUNDS=${3:-6}
SECS=${4:-90}
SMP=${5:-4}
MILE=${6:-linux}
case "$MILE" in
    bds)     MPAT='BdsDxe: starting' ;;
    linux)   MPAT='Linux version' ;;
    # 不用 'systemd\[1\]' —— boot 中共匹配 75 次，判据不唯一（#10 同类）。
    # 用剥 ANSI 后的宽匹配。
    systemd) MPAT='Reached target.*multi-user' ;;
esac

H=/data/local/tmp
BIOS=$H/henge/bios
LOG=$H/rf-$TAG.serial.log
ERR=$H/rf-$TAG.err
MAP=$H/rf-$TAG.smaps
VARS=$H/rf-$TAG.img
DISK=$H/rf-$TAG.qcow2
MPORT=${MPORT:-4456}

# 基线 vars0.img 是 444（防误当工作文件）；toybox 的 cp -f 会
# 保留源权限，所以目标必须显式放开写权限，否则 QEMU 打不开 varstore。
cp -f $H/vars0.img "$VARS" 2>/dev/null; chmod 644 "$VARS" 2>/dev/null
qemu-img create -f qcow2 -b $H/deb12.qcow2 -F qcow2 "$DISK" >/dev/null 2>&1 || cp -f $H/deb12.qcow2 "$DISK"
rm -f "$LOG" "$ERR" "$MAP"

HV_STATS=${HV_STATS:-3600}   # 这轮只要 RSS 分区，不要 stats 刷屏
export HV_STATS

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

NOANSI=$LOG.noansi
strip_ansi() { sed -E 's/\x1b\[[0-9;]*m//g' "$LOG" > "$NOANSI" 2>/dev/null; }
cnt() { strip_ansi; n=$(grep -ac "$1" "$NOANSI" 2>/dev/null); echo "${n:-0}"; }
mon() { printf '%s\n' "$1" | timeout 3 nc 127.0.0.1 $MPORT 2>/dev/null; }

# 按 VMA 名称聚合 Rss（kB）。无名的记作 [anon]。
# 只保留 >=1MB 的项，输出按大小降序的 top 12。
dump_map() {   # $1 = round
    awk -v rnd="$1" '
        /^[0-9a-f]+-[0-9a-f]+ / {
            name = (NF >= 6) ? $6 : "[anon]"
            if (NF < 6) name = "[anon]"
            if ($6 ~ /^\[/) name = $6
        }
        /^Rss:/ { rss[name] += $2 }
        END {
            for (n in rss) if (rss[n] >= 1024) printf "%d\t%s\t%d\n", rnd, n, rss[n]
        }' /proc/$QP/smaps 2>/dev/null | sort -k3 -rn | head -12
    # 总 RSS 单独一行
    T=$(awk '/^Rss:/{s+=$2}END{print s+0}' /proc/$QP/smaps 2>/dev/null)
    echo "$1	[TOTAL]	$T"
}

wait_mile() {
    W=0
    while [ $W -lt $(($2 * 2)) ]; do
        [ "$(cnt "$MPAT")" -ge "$1" ] && return 0
        kill -0 $QP 2>/dev/null || return 2
        W=$((W + 1)); sleep 0.5
    done
    return 1
}

echo "=== rssfind tag=$TAG smp=$SMP milestone=$MILE rounds=$ROUNDS ==="
printf 'round\tregion\trss_kb\n' > "$MAP"
R=0
while [ $R -lt $ROUNDS ]; do
    R=$((R + 1))
    if wait_mile $R $SECS; then :; else echo "round $R: timeout"; fi
    dump_map $R >> "$MAP"
    T=$(awk -F'\t' -v r=$R '$1==r && $2=="[TOTAL]"{print $3}' "$MAP")
    echo "round $R: total_rss=${T}KB  mile_n=$(cnt "$MPAT")"
    [ $R -ge $ROUNDS ] && break
    mon system_reset >/dev/null 2>&1
    sleep 2
    kill -0 $QP 2>/dev/null || { echo "!! QEMU 退出"; break; }
done

sleep 2
kill -9 $QP 2>/dev/null
sleep 1
trap - EXIT HUP INT TERM

echo
echo "=== 同一区域跨轮对比（只列第1轮与最后一轮都在、且涨幅 top 10）==="
awk -F'\t' -v a=1 -v b=$R '
    $2 != "[TOTAL]" { v[$2 SUBSEP $1] = $3; seen[$2] = 1 }
    END {
        for (n in seen) {
            x = v[n SUBSEP a]; y = v[n SUBSEP b]
            if (x == "") x = 0
            if (y == "") y = 0
            printf "%d\t%s\t%d\n", y - x, n, y
        }
    }' "$MAP" | sort -rn | head -10 | awk -F'\t' '{printf "  %+8d KB  %s  (末轮 %d KB)\n", $1, $2, $3}'
echo
echo "原始数据: $MAP"
