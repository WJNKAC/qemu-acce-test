#!/bin/sh
# nrun.sh - n 轮通过率测量，每轮自带 doze 闸（13.26 之后的标准姿势）。
#
# 与 abtest.sh 的区别（那次失败的三点都改了）：
#   1. Termux 的 sleep 不可靠（sleep 240 跑成 400s+）→ 改用 python3 time.sleep，
#      它基于 CLOCK_MONOTONIC，而我们已拿 wakelock，所以 M 正常走、计时准确。
#   2. 每轮都跑 sidecar，用 sidecar_check 判 VALID/INVALID，
#      被 suspend 污染的轮次直接作废，**不进通过率分子分母**。
#   3. 交替 A/B 不再靠"我手工控制节奏"，而是脚本内确定性执行，
#      并记录每轮的 md5 与频率，事后可复现。
#
# 用法: nrun.sh <tag> <binA> <nA> [binB nB] [secs]
#   nrun.sh wl1 ./b-old 8 360
#   nrun.sh cmp ./b-old 4 ./q-clean 4 360
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
TAG=${1:?tag}
BINA=${2:?binA}
NA=${3:?nA}
BINB=${4:-}
NB=${5:-0}
SECS=${6:-360}

RES=$H/nr-$TAG.tsv
printf "round\tbin\tmd5\tvalid\tserial\tbds\tlinux\tsusp_ms\treal_s\tf0\n" > "$RES"

i=0
run_one() {
    BIN=$1
    i=$((i + 1))
    T=$(printf "%s-r%02d" "$TAG" "$i")
    SER=$H/nr-$T.serial.log
    ERR=$H/nr-$T.stderr.log
    SC=$H/nr-$T.sidecar.tsv
    VARS=$H/nr-$T.img

    MD5=$(md5sum "$BIN" | cut -c1-16)
    F0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo na)
    cp -f $H/vars0.img "$VARS" 2>/dev/null
    rm -f "$SER" "$ERR" "$SC"

    # 探针一律关：这组只测通过率
    nohup sh -c "exec taskset -c 0,1 $BIN \
      -L /data/local/tmp/henge/bios \
      -M virt,gic-version=3 -cpu max -m 2048 \
      -display none -no-reboot -smp 2 -accel henge \
      -drive if=pflash,format=raw,unit=0,file=/data/local/tmp/henge/bios/edk2-aarch64-code.fd,readonly=on \
      -drive if=pflash,format=raw,unit=1,file=$VARS \
      -serial file:$SER -monitor none" > "$ERR" 2>&1 &
    QP=$!
    echo "$QP" > $H/nr.pid

    # sidecar 同时起（它自己也会再拿一次 wakelock）
    sh $H/sidecar.sh "$QP" "$SER" "$SC" 10 >/dev/null 2>&1 &
    SCP=$!

    # ★ 用 python sleep 而不是 sh sleep：Termux 的 sleep 实测可跑成 1.7 倍
    T0=$(python3 -c 'import time; print(int(time.clock_gettime(time.CLOCK_MONOTONIC)))')
    python3 -c "import time; time.sleep($SECS)" 2>/dev/null
    T1=$(python3 -c 'import time; print(int(time.clock_gettime(time.CLOCK_MONOTONIC)))')

    kill -9 "$QP" 2>/dev/null
    sleep 1
    kill -9 "$SCP" 2>/dev/null

    N=$(grep -av '^#' "$SER" 2>/dev/null | wc -l)
    B=$(grep -ac BdsDxe "$SER" 2>/dev/null)
    L=$(grep -ac 'Linux version' "$SER" 2>/dev/null)
    SUSP=0
    if [ -f "$SC" ]; then
        SUSP=$(awk -F'\t' 'NR>1 && $17+0>m {m=$17+0} END{print m+0}' "$SC" 2>/dev/null)
    fi
    # 判定：累计 suspend >1000ms 即污染
    if [ "${SUSP:-0}" -gt 1000 ]; then VALID=NO; else VALID=YES; fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$i" "$(basename "$BIN")" "$MD5" "$VALID" "$N" "$B" "$L" "$SUSP" "$((T1 - T0))" "$F0" >> "$RES"
    echo "r$i $(basename "$BIN") valid=$VALID serial=$N bds=$B susp=${SUSP}ms real=$((T1-T0))s"
}

i2=0
while [ "$i2" -lt "$NA" ]; do run_one "$BINA"; i2=$((i2 + 1)); done
i2=0
if [ -n "$BINB" ] && [ "$NB" -gt 0 ]; then
    while [ "$i2" -lt "$NB" ]; do run_one "$BINB"; i2=$((i2 + 1)); done
fi

echo "=== $TAG 汇总 ==="
cat "$RES"
echo "--- 只统计 VALID 的通过率（BdsDxe>0）---"
awk -F'\t' 'NR>1 { if ($4=="YES") { tot[$2]++; if ($6>0) ok[$2]++ } else bad[$2]++ }
     END {
        for (b in tot) printf "%-12s %d/%d 通过   (另有 %d 轮被 doze 污染，已剔除)\n", b, ok[b]+0, tot[b], bad[b]+0
        if (length(tot)==0) print "  没有任何 VALID 轮次 —— 全部被污染，检查 wakelock"
     }' "$RES"
