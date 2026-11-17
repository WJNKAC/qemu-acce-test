#!/data/data/com.termux/files/usr/bin/sh
# pboot.sh - PDYT20 上的"到 Shell"计时，用内核 suspend blocker 保证时钟连续。
# 与 vboot.sh 同逻辑，差别只是路径在内核锁下。
set -u
termux-wake-lock 2>/dev/null || true
echo a72 | su -c "echo henge_hold > /sys/power/wake_lock" 2>/dev/null

TAG=${1:-p}
BIN=${2:-$HOME/h/q-p0a}
N=${3:-3}
MAXS=${4:-300}
H=$HOME/h
BIOS=/data/local/tmp/henge/bios

# PDYT20 的 Termux 读不了 /proc/uptime（permission denied），用 python3。
now_ms() { python3 -c 'import time; print(int(time.clock_gettime(time.CLOCK_MONOTONIC)*1000))' 2>/dev/null; }

i=1
while [ "$i" -le "$N" ]; do
    LOG=$H/$TAG-$i.log; VARS=$H/$TAG-$i.img
    cp -f $H/vars0.img "$VARS" 2>/dev/null; rm -f "$LOG"
    T0=$(now_ms)
    $BIN -L "$BIOS" -M virt,gic-version=3 -cpu max -m 2048 \
        -display none -no-reboot -smp 2 -accel henge \
        -drive if=pflash,format=raw,unit=0,file=$BIOS/edk2-aarch64-code.fd,readonly=on \
        -drive if=pflash,format=raw,unit=1,file=$VARS \
        -serial file:$LOG -monitor none >/dev/null 2>&1 &
    QP=$!
    got=0
    while kill -0 $QP 2>/dev/null; do
        if grep -aq 'Shell>' "$LOG" 2>/dev/null; then got=1; break; fi
        NOW=$(now_ms)
        [ $((NOW - T0)) -gt $((MAXS * 1000)) ] && break
        sleep 0.2
    done
    T1=$(now_ms); kill -9 $QP 2>/dev/null; sleep 1
    LINES=$(grep -av '^#' "$LOG" 2>/dev/null | wc -l)
    BDS=$(grep -ac BdsDxe "$LOG" 2>/dev/null)
    EL=$(( (T1-T0)/1000 )).$(( (T1-T0)%1000/100 ))
    [ "$got" = 1 ] && echo "r$i  Shell@${EL}s  lines=$LINES bds=$BDS  OK" || echo "r$i  TIMEOUT>${MAXS}s lines=$LINES bds=$BDS FAIL"
    i=$((i + 1))
done
