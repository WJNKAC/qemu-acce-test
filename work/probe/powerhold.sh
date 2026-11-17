#!/bin/sh
# powerhold.sh - 内核级 suspend blocker 的持有/释放/自检。
#
# 为什么不用 termux-wake-lock（13.30 的教训）：
#   termux-wake-lock 拿的是 Android PowerManager 层的 PARTIAL_WAKE_LOCK。
#   Doze 会越过它 —— 实测 10 秒采样间隔里设备睡了 141.9 秒。
#   而 /sys/power/wake_lock 是**内核**的 suspend blocker，系统要 suspend
#   必须先等所有 blocker 释放，Doze 也绕不过。
#
# 实测（写入后 20 秒）：
#   dM=20.00s  dB=20.00s  dsusp=0.00s   → 完全挡住
#
# ⚠ 这是宿主配置，不是软件修复。用它换"可测量的基线"，
#   不要用它掩盖 guest 侧的真实行为。
#
# 用法:
#   powerhold.sh hold [name]     创建一个 suspend blocker
#   powerhold.sh release [name]  释放
#   powerhold.sh check [secs]    测 dsusp，默认 20 秒
#   powerhold.sh status
#
# 需要 root（设备上 `echo <pw> | su -c ...`）；本脚本假设调用方已能拿到 root。
set -u
NAME=${POWERHOLD_NAME:-henge_hold}
SUPW=${SUPW:-a72}

# root 执行一条命令。Termux 的 su 从 stdin 读密码，
# 所以密码由 echo 喂进去，命令本身用 -c 传参（不要把密码和命令混在管道里，
# 那会让内层 sh 把密码当命令：`<stdin>[1]: a72: inaccessible or not found`）。
asroot() {
    printf '%s\n' "$SUPW" | su -c "$1" 2>/dev/null
}

CMD=${1:-check}
case "$CMD" in
hold)
    asroot "echo $NAME > /sys/power/wake_lock"
    got=$(asroot "cat /sys/power/wake_lock")
    case "$got" in
        *"$NAME"*) echo "hold: OK ($NAME)" ;;
        *)         echo "hold: FAILED (wake_lock='$got')" >&2; exit 1 ;;
    esac
    ;;
release)
    asroot "echo $NAME > /sys/power/wake_unlock"
    got=$(asroot "cat /sys/power/wake_lock")
    case "$got" in
        *"$NAME"*) echo "release: 仍在锁中 ($got)" >&2; exit 1 ;;
        *)         echo "release: OK" ;;
    esac
    ;;
status)
    got=$(asroot "cat /sys/power/wake_lock")
    echo "wake_lock=[${got}]"
    ;;
check)
    SECS=${2:-20}
    python3 -c "
import time
m0=time.clock_gettime(time.CLOCK_MONOTONIC); b0=time.clock_gettime(time.CLOCK_BOOTTIME)
time.sleep($SECS)
m1=time.clock_gettime(time.CLOCK_MONOTONIC); b1=time.clock_gettime(time.CLOCK_BOOTTIME)
dm, db = m1-m0, b1-b0
print(f'check: {dm:.2f}s mono / {db:.2f}s boot / dsusp={db-dm:.2f}s')
raise SystemExit(0 if abs(db-dm) < 1.0 else 1)
"
    rc=$?
    [ $rc -eq 0 ] && echo "check: 时钟连续" || echo "check: 仍在 suspend（阻塞无效）" >&2
    exit $rc
    ;;
*)
    echo "usage: powerhold.sh hold|release|status|check [secs]" >&2
    exit 2
    ;;
esac
