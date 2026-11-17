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
# 用法: sidecar.sh <qemu_pid> <serial_log> <out.tsv> [interval]
set -u
P=${1:?pid}
LOG=${2:?serial log}
OUT=${3:?out tsv}
IV=${4:-10}

printf "t\tserial_lines\trss_kb\tf_cpu0\tf_cpu2\tf_cpu6\tf_cpu7\tonline6\tonline7\tloadavg\ttemp\n" > "$OUT"

# 线程 schedstat 单独一份（列数随线程数变化，不适合塞进主表）
THR=$OUT.threads
printf "t\ttid\tcomm\ton_cpu_ns\twq_ns\tslices\n" > "$THR"

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
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$T" "$lines" "${rss:-}" "${f0:-}" "${f2:-}" "${f6:-}" "${f7:-}" \
        "${o6:-}" "${o7:-}" "${la:-}" "${tmax:-na}" >> "$OUT"

    for t in /proc/$P/task/*; do
        [ -r "$t/schedstat" ] || continue
        tid=${t##*/}
        cm=$(sed 's/^[0-9]* (//; s/).*//' "$t/comm" 2>/dev/null)
        read -r a b c < "$t/schedstat" 2>/dev/null
        printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$T" "$tid" "$cm" "${a:-}" "${b:-}" "${c:-}" >> "$THR"
    done

    sleep "$IV"
done
