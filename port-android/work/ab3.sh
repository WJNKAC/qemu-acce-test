#!/bin/bash
# 差值法测三桶 + 基线重测。
#
# 为什么要交错：设备是手机，逐次运行会热降频/后台抖动；同一变体连着跑会系统性偏高。
# 所以按 base/bank/base/bank 交替，最后取中位数。
#
# 为什么要 refills：三桶不用 JIT 插桩（bank 在 x28+4MB 外，imm12 寻址够不到，
# 插桩会把计数写进野地址）。改用差值：
#   bank_hit = refills(base) - refills(bank)
#   k4_hit   = N - refills(base)
#   N        = knee STEPS = 16M
set -u
DEV=/data/local/tmp
OUT=${OUT:-/tmp/k3}
mkdir -p "$OUT"
ROUNDS=${ROUNDS:-3}
for kib in 65536 524288 2097152; do
    for r in $(seq 1 "$ROUNDS"); do
        for v in base bank; do
            log="$OUT/${v}_${kib}_r${r}.log"
            adb shell "su -c \"sh $DEV/rk.sh $DEV/hv-$v $kib 2560\"" > "$log" 2>&1
            kn=$(grep -E '^knee ' "$log" | awk '{print $4}')
            rf=$(grep -o 'refills=[0-9]*' "$log" | head -1 | cut -d= -f2)
            bf=$(grep -o 'fills=[0-9]*' "$log" | head -1 | cut -d= -f2)
            sw=$(grep -o 'on_switch=[0-9]*' "$log" | cut -d= -f2)
            su=$(grep -o 'switch_user_calls=[0-9]*' "$log" | cut -d= -f2)
            gi=$(grep -o 'guest_insns=[0-9]*' "$log" | head -1 | cut -d= -f2)
            echo "$kib $v $r ns=$kn refills=$rf fills=$bf switch_inv=$sw switch=$su insns=$gi"
        done
    done
done
