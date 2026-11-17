#!/bin/sh
# probe-freeze.sh - 检查 QEMU 进程是否被 Android 的 cgroup 冻结/限流。
#
# 为什么这个假设值得查：
#   F0-2 实测 vCPU 每 192ms 才醒一次，每次只跑 2ms；
#   但 wait_for_interrupt() 的等待上限是 240000 tick @24MHz = 10ms
#   （算术已验证：240000/24e6 = 0.01s，ts 换算正确）。
#   10ms 的 cap 造不出 190ms 的间隙，而 futex 超时是绝对的 30 小时；
#   唯一的"无限等待"sit 是 dispatch.c:90 的 stw_cv。
#   如果两者都不成立，剩下的解释就是：进程根本没被调度——
#   Android 的 app freezer（cgroup v2 cgroup.freeze）会把 cached app 冻住，
#   冻结期间线程既不跑也不在 futex 上，schedstat 的 wait 字段也不增长。
#   这能同时解释"两个字段都小、却有 96 秒缺口"和"同一二进制时快时慢"。
#
# 用法: probe-freeze.sh <pid>
set -u
P=${1:?pid}

echo "=== pid=$P comm=$(cat /proc/$P/comm 2>/dev/null) ==="
echo
echo "--- 1. cgroup 归属 ---"
cat /proc/$P/cgroup 2>/dev/null

echo
echo "--- 2. 该 cgroup 的 freeze 状态与 CPU 配额 ---"
# 从 cgroup 行里取路径，例如 0::/uid_10280/pid_12345
CG=$(awk -F: '$1=="0" {print $3}' /proc/$P/cgroup 2>/dev/null | head -1)
if [ -n "$CG" ]; then
    for base in /sys/fs/cgroup /sys/fs/cgroup/unified; do
        d=$base$CG
        [ -d "$d" ] || continue
        echo "dir=$d"
        for f in cgroup.freeze cgroup.procs cpu.max cpu.weight cpu.stat memory.max; do
            [ -r "$d/$f" ] && { printf "  %-14s = " "$f"; head -3 "$d/$f" | tr '\n' ' '; echo; }
        done
        break
    done
fi

echo
echo "--- 3. 整机 memory pressure（冻结常伴随） ---"
for f in /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io; do
    [ -r "$f" ] && { printf "%-24s " "$(basename $f)"; head -1 "$f"; }
done

echo
echo "--- 4. 三次 slices 采样（间隔 5s）：冻结时应完全不动 ---"
V=$(ls -d /proc/$P/task/* 2>/dev/null | while read t; do
        case "$(cat $t/comm 2>/dev/null)" in "CPU 0"*) echo $t ;; esac
    done | head -1)
if [ -n "$V" ]; then
    for i in 1 2 3; do
        read -r on wq sl < "$V/schedstat" 2>/dev/null
        printf "  %s on-cpu=%sms wait=%sms slices=%s\n" \
            "$(date +%H:%M:%S)" \
            "$(awk -v x="$on" 'BEGIN{printf "%.1f", x/1e6}')" \
            "$(awk -v x="$wq" 'BEGIN{printf "%.1f", x/1e6}')" "$sl"
        [ $i -lt 3 ] && sleep 5
    done
else
    echo "  vCPU0 线程未找到"
fi
