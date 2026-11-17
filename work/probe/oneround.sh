#!/bin/sh
# oneround.sh - 单轮启动/停止，不 sleep。
#
# 为什么不用脚本内 sleep 循环控制节奏：实测 Termux 上 `sleep 240` 会跑 400 秒
# 还不返回（Android 的计时/doze 会让 sleep 变慢）。把它当计时器，整组实验的
# 时间轴就不可信了。改成"启动一次就返回"，节奏由调用方（本地 Bash + 我的
# sleep）控制——本地的 sleep 是准的，而且每一轮我都能当场看到读数。
#
# 用法:
#   oneround.sh start <tag> <bin> [secs]    启动，写 pidfile+metadata
#   oneround.sh stop  <tag>                 杀死（只读 pidfile，永不模式匹配）
#   oneround.sh stat  <tag>                 打印该轮的行数/BdsDxe/耗时
set -u
H=${H:-/data/data/com.termux/files/home/h}
CMD=${1:?start|stop|stat}
TAG=${2:?tag}

case "$CMD" in
start)
    BIN=${3:?binary}
    SECS=${4:-240}
    SER=$H/ab-$TAG.serial.log
    ERR=$H/ab-$TAG.stderr.log
    VARS=$H/ab-$TAG.img
    MD5=$(md5sum "$BIN" | cut -c1-16)
    F0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null || echo na)
    F6=$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq 2>/dev/null || echo na)

    [ -x "$BIN" ] || { echo "MISSING $BIN" >&2; exit 3; }
    cp -f $H/vars0.img "$VARS" 2>/dev/null
    rm -f "$SER" "$ERR"

    # 探针全关：这一组只测通过率，任何额外输出都可能改变时序。
    nohup sh -c "exec taskset -c 0,1 $BIN \
      -L /data/local/tmp/henge/bios \
      -M virt,gic-version=3 -cpu max -m 2048 \
      -display none -no-reboot -smp 2 -accel henge \
      -drive if=pflash,format=raw,unit=0,file=/data/local/tmp/henge/bios/edk2-aarch64-code.fd,readonly=on \
      -drive if=pflash,format=raw,unit=1,file=$VARS \
      -serial file:$SER -monitor none" > "$ERR" 2>&1 &
    echo $! > "$H/ab-$TAG.pid"
    printf "%s\t%s\t%s\t%s\n" "$(basename "$BIN")" "$MD5" "$F0" "$F6" > "$H/ab-$TAG.meta"
    echo "started $TAG pid=$(cat $H/ab-$TAG.pid) bin=$(basename $BIN) md5=$MD5 f0=$F0 f6=$F6"
    ;;
stop)
    PIDF=$H/ab-$TAG.pid
    [ -f "$PIDF" ] && { p=$(cat "$PIDF" 2>/dev/null); [ -n "$p" ] && kill -9 "$p" 2>/dev/null; }
    echo "stopped $TAG"
    ;;
stat)
    SER=$H/ab-$TAG.serial.log
    [ -f "$SER" ] || { echo "$TAG: no log"; exit 0; }
    N=$(grep -av "^#" "$SER" 2>/dev/null | wc -l)
    B=$(grep -ac BdsDxe "$SER" 2>/dev/null)
    L=$(grep -ac "Linux version" "$SER" 2>/dev/null)
    echo "$TAG lines=$N bds=$B linux=$L"
    ;;
*)
    echo "bad cmd" >&2; exit 2 ;;
esac
