#!/data/data/com.termux/files/usr/bin/sh
# vboot.sh - 在 vivo 上测"到 Shell 的墙钟时间"，跑 N 轮。
# vivo 的 USB 常亮让时钟天然连续（实测 dsusp=0），不需要 root/suspend blocker。
set -u
TAG=${1:-v}
BIN=${2:-/data/local/tmp/q-p0a}
N=${3:-3}
MAXS=${4:-180}

H=/data/local/tmp
BIOS=$H/henge/bios

i=1
while [ "$i" -le "$N" ]; do
    LOG=$H/$TAG-$i.log
    VARS=$H/$TAG-$i.img
    cp -f $H/vars0.img "$VARS"
    rm -f "$LOG"

    # adb shell 里没有 python3；/proc/uptime 是 CLOCK_BOOTTIME 精度 10ms，
    # 但 vivo 常亮不 suspend，所以 BOOTTIME == MONOTONIC，可用。
    now_ms() { awk '{printf "%d", $1*1000}' /proc/uptime; }
    uptime_ms() { cat /proc/uptime 2>/dev/null; }
    T0=$(now_ms)
    $BIN -L "$BIOS" -M virt,gic-version=3 -cpu max -m 2048 \
        -display none -no-reboot -smp 2 -accel henge \
        -drive if=pflash,format=raw,unit=0,file=$BIOS/edk2-aarch64-code.fd,readonly=on \
        -drive if=pflash,format=raw,unit=1,file=$VARS \
        -serial file:$LOG -monitor none >/dev/null 2>&1 &
    QP=$!

    # 轮询等 Shell>，每 200ms 一次；超时就杀
    got=0
    while kill -0 $QP 2>/dev/null; do
        if grep -aq 'Shell>' "$LOG" 2>/dev/null; then got=1; break; fi
        NOW=$(now_ms)
        [ $((NOW - T0)) -gt $((MAXS * 1000)) ] && break
        sleep 0.2
    done

    T1=$(now_ms)
    kill -9 $QP 2>/dev/null
    sleep 1

    LINES=$(grep -av '^#' "$LOG" 2>/dev/null | wc -l)
    BDS=$(grep -ac BdsDxe "$LOG" 2>/dev/null)
    if [ "$got" = 1 ]; then
        echo "r$i  Shell@$(( (T1-T0)/1000 )).$(( (T1-T0)%1000/100 ))s  lines=$LINES bds=$BDS  OK"
    else
        echo "r$i  TIMEOUT>${MAXS}s  lines=$LINES bds=$BDS  FAIL"
    fi
    i=$((i + 1))
done
