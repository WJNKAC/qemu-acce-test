#!/bin/sh
# autopsy.sh - 对一个（可能卡死的）QEMU 进程做线程级验尸。
#
# 为什么不用 /proc/<tid>/stat 的 utime：
#   comm 字段是 "(CPU 0/Henge)"，**含空格**。awk '{print $14}' 会错位，
#   实际读到的是 cmajflt。本轮我据此得出"vCPU utime=0"是错的，已撤回。
#   改用 /proc/<tid>/schedstat：三字段纯数字（on-cpu ns / runqueue-wait ns /
#   timeslices），单行、免疫 comm 空格。
#
# 用法: autopsy.sh <pid> [tag]
# 输出: 线程表 + schedstat 双采样 delta + futex uaddr 归属符号
set -u
H=${H:-/data/data/com.termux/files/home/h}
P=${1:?pid}
TAG=${2:-$(date +%H%M%S)}
OUT=$H/autopsy-$TAG.txt

# ---- 主二进制基址（ASLR 校正用）----
MAPS=$(cat /proc/$P/maps 2>/dev/null)
EXE=$(readlink /proc/$P/exe 2>/dev/null)
BASE=$(echo "$MAPS" | awk -v e="$EXE" '$6==e {split($1,a,"-"); print a[1]; exit}')
[ -n "${BASE:-}" ] || BASE=0

# ---- 符号表（已排序，nm -n）----
SYMTAB=$H/sym-$(basename "$EXE").txt
if [ ! -s "$SYMTAB" ]; then
    nm -n "$EXE" 2>/dev/null | awk '$2 ~ /[tTwWsSbBdDrR]/ {print $1, $3}' > "$SYMTAB"
fi

# 地址 -> 最近符号（<= addr 的最后一个）
sym_of() {
    awk -v a="$1" '
        BEGIN { best="?"; besta=0 }
        { addr = strtonum("0x" $1); if (addr <= a && addr > besta) { besta = addr; best = $2 } }
        END { if (best != "?") printf "%s+0x%x", best, a - besta; else printf "?" }
    ' "$SYMTAB" 2>/dev/null
}

# uaddr -> 符号：先算 maps 内偏移，再按段基址还原
sym_of_ptr() {
    ptr=$1
    echo "$MAPS" | awk -v p="$ptr" '
        BEGIN { pa = strtonum(p) }
        {
            split($1, r, "-"); lo = strtonum("0x" r[1]); hi = strtonum("0x" r[2]);
            if (pa >= lo && pa < hi) { printf "0x%x %s\n", pa - lo, $6; exit }
        }' | while read -r off lib; do
            if [ "$lib" = "$EXE" ]; then
                abs=$(awk -v b="$BASE" -v o="$off" 'BEGIN{printf "%d", strtonum("0x" b) + o}')
                sym_of "$abs"
            else
                printf "[%s+%s]" "$(basename "${lib:-anon}")" "${off:-?}"
            fi
        done
}

{
    echo "# autopsy pid=$P exe=$EXE base=0x$BASE at=$(date +%H:%M:%S)"
    echo "# loadavg: $(cat /proc/loadavg 2>/dev/null)"
    echo "# freq: $(for c in 0 2 6 7; do printf 'c%s=%s ' $c "$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>/dev/null)"; done)"
    echo "#"
    printf "%-8s %-16s %-8s %-12s %-12s %s\n" TID COMM STATE VSW NVSCHED WCHAN

    # ---- 第一遍采样 ----
    : > "$H/.autopsy.s1"
    for t in /proc/$P/task/*; do
        tid=${t##*/}
        st=$(awk '/^State:/{print $2}' "$t/status" 2>/dev/null)
        vs=$(awk '/^voluntary_ctxt_switches:/{print $2}' "$t/status" 2>/dev/null)
        nv=$(awk '/^nonvoluntary_ctxt_switches:/{print $2}' "$t/status" 2>/dev/null)
        cm=$(sed 's/^[0-9]* (//; s/).*//' "$t/comm" 2>/dev/null)
        wc=$(cat "$t/wchan" 2>/dev/null)
        ss=$(cat "$t/schedstat" 2>/dev/null | awk '{print $1" "$2" "$3}')
        echo "$tid|$cm|$st|$vs|$nv|$wc|$ss" >> "$H/.autopsy.s1"
    done
    sleep 2
    # ---- 第二遍，算 delta ----
    for t in /proc/$P/task/*; do
        tid=${t##*/}
        [ -r "$t/schedstat" ] || continue
        ss2=$(cat "$t/schedstat" 2>/dev/null | awk '{print $1" "$2" "$3}')
        line=$(grep "^$tid|" "$H/.autopsy.s1" 2>/dev/null | head -1)
        [ -n "$line" ] || continue
        cm=$(echo "$line" | cut -d'|' -f2)
        st=$(echo "$line" | cut -d'|' -f3)
        vs=$(echo "$line" | cut -d'|' -f4)
        nv=$(echo "$line" | cut -d'|' -f5)
        wc=$(echo "$line" | cut -d'|' -f6)
        ss1=$(echo "$line" | cut -d'|' -f7)
        d_on=$(awk -v a="$ss1" -v b="$ss2" 'BEGIN{split(a,x," ");split(b,y," ");printf "%d", y[1]-x[1]}')
        d_wq=$(awk -v a="$ss1" -v b="$ss2" 'BEGIN{split(a,x," ");split(b,y," ");printf "%d", y[2]-x[2]}')
        d_sl=$(awk -v a="$ss1" -v b="$ss2" 'BEGIN{split(a,x," ");split(b,y," ");printf "%d", y[3]-x[3]}')
        printf "%-8s %-16s %-8s %-12s %-12s %s\n" "$tid" "$cm" "$st" "v=$vs" "nv=$nv/$d_sl" "$wc"
        printf "         on-cpu=+%sms wq=+%sms  (%s)\n" \
            "$(awk -v d="$d_on" 'BEGIN{printf "%.1f", d/1000000}')" \
            "$(awk -v d="$d_wq" 'BEGIN{printf "%.1f", d/1000000}')" \
            "$(if [ "$d_on" -gt 500000000 ]; then echo RUNNING; elif [ "$d_sl" -gt 200 ]; then echo PARKED_HIGH_SWITCH; else echo IDLE; fi)"
    done

    echo "#"
    echo "# ---- futex uaddr 归属 ----"
    for t in /proc/$P/task/*; do
        tid=${t##*/}
        sc=$(cat "$t/syscall" 2>/dev/null)
        [ -n "$sc" ] || continue
        nr=$(echo "$sc" | awk '{print $1}')
        # 98 = futex (aarch64), arg0 = uaddr
        if [ "$nr" = "98" ] || [ "$nr" = "202" ]; then
            ua=$(echo "$sc" | awk '{print $2}')
            cm=$(sed 's/^[0-9]* (//; s/).*//' "$t/comm" 2>/dev/null)
            printf "  %s %s futex uaddr=%s -> %s\n" "$tid" "$cm" "$ua" "$(sym_of_ptr "$ua")"
        elif [ "$nr" = "73" ] || [ "$nr" = "72" ]; then
            cm=$(sed 's/^[0-9]* (//; s/).*//' "$t/comm" 2>/dev/null)
            printf "  %s %s ppoll(nfds=%s) -> 等 I/O\n" "$tid" "$cm" "$(echo "$sc" | awk '{print $3}')"
        fi
    done
} > "$OUT" 2>&1

rm -f "$H/.autopsy.s1"
cat "$OUT"
echo
echo "(saved $OUT)"
