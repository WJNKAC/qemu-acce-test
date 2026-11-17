#!/bin/sh
# sidecar_check.sh - 判一个 run 是否被 doze 污染（13.26 之后每个 run 都要过这道闸）。
#
# 为什么单独一个脚本：通过率比较的前提是"这些 run 的时钟是连续的"。
# 之前 6 个格子被污染过而无人知道，就是因为没有这道闸。
#
# 用法: sidecar_check.sh <out.tsv>
# 退出码: 0 = VALID（可用于统计）  1 = INVALID（丢进垃圾桶，别拿来比较）
set -u
F=${1:?sidecar tsv}

[ -f "$F" ] || { echo "INVALID: 没有 $F"; exit 1; }

awk -F'\t' '
NR==1 { for (i=1;i<=NF;i++) if ($i=="susp_cum_ms") c=i; 
        for (i=1;i<=NF;i++) if ($i=="flag") g=i;
        for (i=1;i<=NF;i++) if ($i=="serial_lines") s=i;
        for (i=1;i<=NF;i++) if ($i=="t") tt=i;
        next }
{
    n++
    if (c && $c+0 > cum) cum = $c+0
    if (g && $g == "SUSPEND") nsusp++
    if (s) last = $s+0
    if (tt) lastt = $tt
}
END {
    if (n == 0) { print "INVALID: 没有采样行"; exit 1 }
    cum = cum+0; nsusp = nsusp+0
    printf "samples=%d  susp_cum=%dms  suspend_intervals=%d  最后一行=%s  serial=%d\n", n, cum, nsusp, lastt, last
    if (cum > 1000 || nsusp > 0) {
        printf "INVALID: 设备在此 run 中 suspend 过（%dms），时钟不连续，通过率不可比\n", cum
        exit 1
    }
    print "VALID: 时钟连续，可用于统计"
    exit 0
}' "$F"
