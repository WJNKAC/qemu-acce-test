#!/bin/sh
# serve.sh —— 在设备上给客机提供一个一次性 HTTP 取文件的通道
#
# 为什么要它：客机（slirp NAT 后面）能访问 10.0.2.2 = 宿主回环，
# 但宿主是 Android，没有 python -m http.server 之类。用 toybox 的 nc
# 拼一个最小的 HTTP/1.0 响应就够了。
#
# 两个必须注意的点（都踩过）：
#   1. 必须 setsid 起。直接在 adb shell 里用 & 起后台进程，
#      adb shell 一退出，整个进程组被 Android 杀掉，
#      客户端会看到 "transfer closed with N bytes remaining"。
#   2. 要循环，否则 nc 处理完一次连接就退出，第二次连接被拒。
cd /data/local/tmp || exit 1
FILE=${1:-bench}
PORT=${2:-8089}
while true; do
    SZ=$(stat -c %s "$FILE" 2>/dev/null) || { sleep 2; continue; }
    # 结尾必须 sleep：cat 一完 stdin 就 EOF，nc 会立刻退出，
    # 而 socket 发送缓冲里还有没发完的字节 —— 客户端就会报
    # "transfer closed with N bytes remaining"。实测固定缺 513 字节。
    {
        printf 'HTTP/1.0 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' "$SZ"
        cat "$FILE"
        sleep 3
    } | nc -l -p "$PORT" >/dev/null 2>&1
done
