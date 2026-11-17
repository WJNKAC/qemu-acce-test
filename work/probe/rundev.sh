#!/bin/bash
# rundev.sh —— 在设备上**脱离 adb 管道**跑长任务。宿主侧用。
#
# 为什么必须脱离：
#   长跑把输出直接写 adb 管道，一旦宿主这边的管道没人读（adb 断了、
#   或者 shell 会话被挂起），设备侧的 `echo` 就会**永久阻塞在 write 上**，
#   脚本自己的 timeout 也随之失效。实测：fix6 那次 timeout=900s，
#   到点后 50 分钟进程还活着，输出停在 round 4。
#   现场看起来是"guest 卡死"，实际是宿主侧的管道。
#
# 做法：setsid + 输出全部重定向到设备侧文件。管道断了也不影响它。
#
# 用法:
#   ./rundev.sh start <tag> [seedtest.sh 的参数...]
#   ./rundev.sh status <tag>
#   ./rundev.sh collect <tag> [本地目录]
#   ./rundev.sh clean  <tag>
#
# 例:
#   ./rundev.sh start fix6 /data/local/tmp/q-p0a9 6 900 2 /data/local/tmp/seed-v3.iso
set -uo pipefail
SER=${SER:-3538956564001EV}
D=/data/local/tmp
SUB=${1:?start|status|collect|clean}
TAG=${2:?tag}
shift 2

adb_() { adb -s "$SER" "$@"; }
HOUT=$D/st-$TAG.out
HPID=$D/st-$TAG.pid

case "$SUB" in
start)
    # 前置：不许有同 tag 的残留，也不许有别的 seedtest 在跑
    OLD=$(adb_ shell "cat $HPID 2>/dev/null" | tr -d '\r')
    if [ -n "$OLD" ] && adb_ shell "kill -0 $OLD 2>/dev/null && echo alive" | grep -q alive; then
        echo "ABORT: tag=$TAG 已有进程在跑（PID=$OLD）。先 ./rundev.sh clean $TAG"; exit 2
    fi
    RUNNING=$(adb_ shell 'ps -A -o ARGS 2>/dev/null | grep -c "[s]eedtest.sh"' | tr -d '\r')
    if [ "${RUNNING:-0}" -gt 0 ]; then
        echo "ABORT: 设备上还有 $RUNNING 个 seedtest.sh 在跑 —— 会抢 4460/10080。"
        echo "       先 ./rundev.sh clean <tag>，或手工 killtree。"
        adb_ shell 'ps -A -o PID,ARGS 2>/dev/null | grep "[s]eedtest.sh"'
        exit 2
    fi
    adb_ shell "rm -f $HOUT"
    # setsid 脱离当前会话；stdin/stdout/stderr 全部指向文件或 /dev/null，
    # 于是 adb 管道断掉对设备侧没有任何影响。
    adb_ shell "cd $D && setsid sh -c 'echo \$\$ > $HPID; exec sh seedtest.sh $TAG $* > $HOUT 2>&1' </dev/null >/dev/null 2>&1 &"
    sleep 3
    P=$(adb_ shell "cat $HPID 2>/dev/null" | tr -d '\r')
    if [ -z "$P" ]; then echo "启动失败：没有 pidfile"; exit 3; fi
    echo "已在设备侧启动 tag=$TAG PID=$P（输出 $HOUT，与 adb 管道无关）"
    ;;
status)
    P=$(adb_ shell "cat $HPID 2>/dev/null" | tr -d '\r')
    ALIVE=no
    [ -n "$P" ] && adb_ shell "kill -0 $P 2>/dev/null && echo alive" | grep -q alive && ALIVE=yes
    echo "tag=$TAG pid=${P:-?} alive=$ALIVE"
    adb_ shell "
        L=$D/st-$TAG.serial.log
        echo \"serial=\$(wc -c < \$L 2>/dev/null || echo 0)B  BEGIN=\$(grep -ac NETPROBE-BEGIN \$L 2>/dev/null || echo 0)  END=\$(grep -ac NETPROBE-END \$L 2>/dev/null || echo 0)\"
        echo '--- 最近 6 行 out ---'; tail -6 $HOUT 2>/dev/null"
    ;;
collect)
    DEST=${1:-.}
    mkdir -p "$DEST"
    adb_ pull "$HOUT" "$DEST/st-$TAG.out" >/dev/null 2>&1 && echo "out  -> $DEST/st-$TAG.out"
    adb_ pull "$D/st-$TAG.serial.log" "$DEST/st-$TAG.serial.log" >/dev/null 2>&1 && echo "serial -> $DEST/st-$TAG.serial.log"
    # 判据一律从 serial 重算：脚本的汇总可能根本没跑到（管道断、被杀）
    L="$DEST/st-$TAG.serial.log"
    [ -f "$L" ] || { echo "没有 serial 日志，无法重算"; exit 4; }
    echo "--- 按 serial 重算判据 ---"
    printf 'BEGIN=%s END=%s\n' "$(grep -ac NETPROBE-BEGIN "$L")" "$(grep -ac NETPROBE-END "$L")"
    for pat in 'DNS-RESOLVE result=fail' 'TCP-EXT state=timeout' 'TCP-GW22 state=timeout' 'CURL-EXT code=000' 'state=timeout'; do
        printf '%-28s %s\n' "$pat" "$(grep -ac "$pat" "$L")"
    done
    printf '%-28s %s\n' 'CURL-GW code=200' "$(grep -ac 'CURL-GW code=200' "$L")"
    ;;
clean)
    P=$(adb_ shell "cat $HPID 2>/dev/null" | tr -d '\r')
    adb_ shell "
        killtree() { for k in \$(pgrep -P \"\$1\" 2>/dev/null); do killtree \"\$k\"; done; kill -9 \"\$1\" 2>/dev/null; }
        [ -n '$P' ] && killtree $P
        for p in \$(ps -A -o PID,ARGS 2>/dev/null | grep '[s]eedtest.sh' | awk '{print \$1}'); do killtree \$p; done
        for p in \$(ps -A -o PID,ARGS 2>/dev/null | grep '[n]c -l -p 10080' | awk '{print \$1}'); do killtree \$p; done
        sleep 2
        echo \"seedtest=\$(ps -A -o ARGS | grep -c '[s]eedtest.sh')  nc=\$(ps -A -o ARGS | grep -c '[n]c -l -p 10080')  10080监听=\$(awk 'NR>1 && \$4==\"0A\" {print \$2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -ci ':2760$')\""
    adb_ shell "rm -f $HPID"
    ;;
*)
    echo "未知子命令 $SUB（start|status|collect|clean）"; exit 2 ;;
esac
