#!/bin/sh
# 完全脱离式启动。qrun.sh 负责生成 cmd 文件，这里只做 detach。
#
# 两个坑都在这个脚本里踩过：
#   1. cp 三个镜像约 405MB，SSH 会话 60s 超时会把它打断 —— 所以整个流程必须
#      先 detach 再跑，不能挂在 SSH 前台。
#   2. TAG 必须 export，否则 qrun.sh 用自己的时间戳，这里就会去执行一个
#      根本不存在的 <TAG>.cmd。于是改成从 qrun 的输出里取真实路径。
H=${H:-/data/data/com.termux/files/home/h}
cd "$H" || exit 1
MODE=${1:-slirp}
SECS=${2:-300}
export SECS
./qrun.sh "$MODE" > "$H/launch.out" 2>&1
CMD=$(sed -n "s/^  launch:  setsid \(.*\.cmd\) .*/\1/p" "$H/launch.out" | head -1)
[ -n "$CMD" ] && [ -x "$CMD" ] || { echo "no cmd in launch.out" >&2; exit 1; }
setsid "$CMD" < /dev/null > /dev/null 2>&1 &
echo "launched $CMD"
