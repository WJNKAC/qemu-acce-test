#!/bin/sh
# sidecar.sh - 随每次运行自动记录的观测曲线。这是本轮的核心投资。
#
# 之前的问题：验尸是一次性手工操作，而且卡死之后才想起来做，
# 于是"vCPU 停烧 CPU 的时刻"和"核被降频的时刻"无法对齐。
# sidecar 每 10 秒落一行，两者自动落在同一时间轴上。
#
# 同时给出**进展斜率**（判活用斜率，不用墙钟到里程碑）：
#   guest 的串口输出行数每 10 秒涨多少 —— 卡死时该值为 0。
#
# ★ 13.26 之后新增：M/B 双时钟列 (mono_ms / boot_ms / dm_ms / db_ms /
#   dsusp_ms / susp_cum_ms / flag)
#
#   为什么必须有：整个 flaky 史的根因是设备 suspend 冻结 CLOCK_MONOTONIC，
#   而 QEMU 的 get_clock() 就是 MONOTONIC，所以设备一睡 guest 就冻。
#   在那之前的所有实验数据都被这条污染过而无人知道 ——
#   **因为没有任何一列记录过"这段时间里设备睡了多少"**。
#
#   判据：dsusp_ms = ΔBOOTTIME − ΔMONOTONIC
#           两个时钟都走  → dsusp = 0
#           设备 suspend  → MONOTONIC 停、BOOTTIME 继续 → dsusp > 0
#   单间隔 dsusp > 200ms 记 SUSPEND；累计 susp_cum > 1000ms 的 run
#   一律作废（不许进通过率统计）。
#
# 用法: sidecar.sh <qemu_pid> <serial_log> <out.tsv> [interval]
set -u

# ---- 设备 suspend 会让 CLOCK_MONOTONIC 停走，guest 被一起冻住 ----
# 实测：30 秒真实时间里 MONOTONIC 只走 0.98 秒（97% 在 suspend），
# 结果是 guest 的 85 秒 timer deadline 要等约 2550 秒真实时间。
# QEMU 的 get_clock() 用 CLOCK_MONOTONIC，所以设备一睡 guest 就停。
termux-wake-lock 2>/dev/null || true

P=${1:?pid}
LOG=${2:?serial log}
OUT=${3:?out tsv}
IV=${4:-10}

printf "t\tserial_lines\trss_kb\tf_cpu0\tf_cpu2\tf_cpu6\tf_cpu7\tonline6\tonline7\tloadavg\ttemp\tmono_ms\tboot_ms\tdm_ms\tdb_ms\tdsusp_ms\tsusp_cum_ms\tflag\n" > "$OUT"

# 线程 schedstat 单独一份（列数随线程数变化，不适合塞进主表）
THR=$OUT.threads
printf "t\ttid\tcomm\ton_cpu_ns\twq_ns\tslices\n" > "$THR"

MP=""
BP=""
SUSP_CUM=0

while kill -0 "$P" 2>/dev/null; do
    T=$(date +%H:%M:%S)
    lines=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    rss=$(awk '/^VmRSS:/{print $2}' /proc/$P/status 2>/dev/null)
    f0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null)
    f2=$(cat /sys/devices/system/cpu/cpu2/cpufreq/scaling_cur_freq 2>/dev/null)
    f6=$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq 2>/dev/null)
    f7=$(cat /sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq 2>/dev/null)
    o6=$(cat /sys/devices/system/cpu/cpu6/online 2>/dev/null)
    o7=$(cat /sys/devices/system/cpu/cpu7/online 2>/dev/null)
    la=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
    # 温度：这台设备的 thermal zone 可能不可读，可读则记最大值
    tmax=""
    for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] || continue
        v=$(cat "$z" 2>/dev/null)
        [ -n "$v" ] || continue
        if [ -z "$tmax" ] || [ "$v" -gt "$tmax" ] 2>/dev/null; then tmax=$v; fi
    done

    # ---- M/B 双时钟 ----
    # 用 python 取**整数毫秒**：shell 没有可靠 float，这两个值也超过 32 位。
    # 每 10 秒起一次 python 的开销可忽略，换来精确到毫秒的对账。
    MN=""
    BN=""
    if command -v python3 >/dev/null 2>&1; then
        MB=$(python3 -c 'import time
print(int(time.clock_gettime(time.CLOCK_MONOTONIC)*1000),
      int(time.clock_gettime(time.CLOCK_BOOTTIME)*1000))' 2>/dev/null)
        MN=$(echo "$MB" | awk '{print $1}')
        BN=$(echo "$MB" | awk '{print $2}')
    fi

    if [ -n "${MN}" ] && [ -n "$MP" ]; then
        dm=$((MN - MP))
        db=$((BN - BP))
        ds=$((db - dm))
        # BOOTTIME − MONOTONIC 在数学上单调不减（差值只增不减），
        # 所以任何负增量都是两次 clock_gettime 调用的微秒级顺序偏差。
        # 只累加正值：否则噪声会把真实的 suspend 抵消掉，
        # 让一个被污染的 run 显示成 VALID —— 这正是要防的事。
        [ "$ds" -gt 0 ] && SUSP_CUM=$((SUSP_CUM + ds))
        # 单间隔睡掉 >200ms 记 SUSPEND；累计 >1s 整 run 作废
        if [ "$ds" -gt 200 ]; then flag=SUSPEND; else flag=ok; fi
    else
        dm=0
        db=0
        ds=0
        flag=init
    fi
    [ -n "${MN}" ] && { MP=$MN; BP=$BN; }

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$T" "$lines" "${rss:-}" "${f0:-}" "${f2:-}" "${f6:-}" "${f7:-}" \
        "${o6:-}" "${o7:-}" "${la:-}" "${tmax:-na}" \
        "${MN:-}" "${BN:-}" "$dm" "$db" "$ds" "$SUSP_CUM" "$flag" >> "$OUT"

    for t in /proc/$P/task/*; do
        [ -r "$t/schedstat" ] || continue
        tid=${t##*/}
        cm=$(sed 's/^[0-9]* (//; s/).*//' "$t/comm" 2>/dev/null)
        read -r a b c < "$t/schedstat" 2>/dev/null
        printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$T" "$tid" "$cm" "${a:-}" "${b:-}" "${c:-}" >> "$THR"
    done

    sleep "$IV"
done
