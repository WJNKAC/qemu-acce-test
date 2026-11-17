#!/bin/sh
# abtest.sh - 交替重复实验：测"通过率"，而不是比单次。
#
# 为什么要交替：单次对比没有判别力。实测里同一二进制 b-old 在
#   09:00 的 wf 那次跑通了（进了 UEFI Shell，20 行，BdsDxe=2），
#   而在 20:12 的 R1、20:53 的 F0、还有 S2/W1/W2 上全部停在 12 行。
# 同一 md5、同一参数、同一组核。这就是 flaky，任何单次 A/B 都可能是噪声。
#
# 交替（A B A B A B）而不是（A A A B B B）：后者 A 全在开头、B 全在末尾，
# 把热漂移、后台 app 状态、电池曲线全部混进二进制这一列里了。
#
# 每轮记录：md5、serial 行数、BdsDxe 次数、启动瞬间的频率。
# 判据是**通过率**（BdsDxe>0 的轮数 / 总轮数），不是某一轮的输赢。
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
BIN_A=${2:?binA}
BIN_B=${3:?binB}
ROUNDS=${4:-6}
SECS=${5:-240}
CPUS=${6:-0,1}

RES=$H/ab-$TAG.tsv
printf "round\tbin\tmd5\tlines\tbds\tfreq0\tfreq6\n" > "$RES"

i=1
while [ "$i" -le "$ROUNDS" ]; do
    # 奇偶交替：1,3,5 → A；2,4,6 → B
    if [ $((i % 2)) -eq 1 ]; then CUR=$BIN_A; else CUR=$BIN_B; fi
    T=$(printf "%s-r%s" "$TAG" "$i")
    SER=$H/ab-$T.serial.log
    ERR=$H/ab-$T.stderr.log

    # 停上一轮（只读 pidfile，永不模式匹配）
    [ -f "$H/ab.pid" ] && { p=$(cat "$H/ab.pid" 2>/dev/null); [ -n "$p" ] && kill -9 "$p" 2>/dev/null; }
    sleep 3

    F0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo na)
    F6=$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq 2>/dev/null || echo na)
    MD5=$(md5sum "$CUR" | cut -c1-16)
    VARS=$H/ab-$T.img
    cp -f $H/vars0.img "$VARS" 2>/dev/null

    rm -f "$SER" "$ERR"
    # 探针一律关掉：这一组只测通过率，任何额外输出都可能改变时序。
    nohup sh -c "exec taskset -c $CPUS $CUR \
      -L /data/local/tmp/henge/bios \
      -M virt,gic-version=3 -cpu max -m 2048 \
      -display none -no-reboot -smp 2 -accel henge \
      -drive if=pflash,format=raw,unit=0,file=/data/local/tmp/henge/bios/edk2-aarch64-code.fd,readonly=on \
      -drive if=pflash,format=raw,unit=1,file=$VARS \
      -serial file:$SER -monitor none" > "$ERR" 2>&1 &
    echo $! > "$H/ab.pid"

    sleep "$SECS"
    p=$(cat "$H/ab.pid" 2>/dev/null); [ -n "$p" ] && kill -9 "$p" 2>/dev/null
    sleep 2

    N=$(grep -av "^#" "$SER" 2>/dev/null | wc -l)
    B=$(grep -ac BdsDxe "$SER" 2>/dev/null)
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$i" "$(basename "$CUR")" "$MD5" "$N" "$B" "$F0" "$F6" >> "$RES"
    i=$((i + 1))
done

echo "=== $TAG 完成 ==="
cat "$RES"
echo "--- 通过率 ---"
awk -F'\t' 'NR>1 { tot[$2]++; if ($5>0) ok[$2]++ }
     END { for (b in tot) printf "%-10s %d/%d\n", b, ok[b]+0, tot[b] }' "$RES"
