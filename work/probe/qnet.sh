#!/bin/sh
#
# qnet - 设备侧 passt 启动器。三种模式集中管理，参数不再手输。
#
# 用法：
#   ./qnet.sh passt      # -netdev stream 用的普通 socket（默认地址，别传 -a/-g！）
#   ./qnet.sh vhost      # --vhost-user 模式（配 qrun.sh passt-vhost）
#   ./qnet.sh stop       # 停掉所有 passt
#   ./qnet.sh status
#
# 为什么默认不给 -a / -g：
#   给一个宿主不拥有的地址（如 192.168.1.134，而 wlan0 是 192.168.1.9）会让
#   passt 替它做 ARP/邻居代理，失败连接走超时重传，吞吐呈双峰：
#   6 轮里 5 轮 0.1-0.5 MB/s、1 轮 3-8 MB/s。去掉后稳定 6-9 MB/s。
#   这个坑在 hv-linux 上还踩出过 914 B/s，别再加回去。
set -u
H=${H:-/data/data/com.termux/files/home/h}
PASST=${PASST:-$H/passt_j}
ACT=${1:-passt}

kill_all() {
    # 精确匹配 cmdline，不能用 pkill -f（会匹配到调用者自己的命令行）
    for p in $(ls /proc | grep -E '^[0-9]+$'); do
        c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
        case "$c" in
            ./passt_j*|*/passt_j\ *) kill -9 "$p" 2>/dev/null ;;
        esac
    done
    sleep 1
}

case "$ACT" in
  passt)
    kill_all
    rm -f "$H/passt.sock" "$H/passt.log"
    cat > "$H/net-passt.sh" <<EOF
#!/bin/sh
cd "$H"
exec "$PASST" -f -q --socket "$H/passt.sock" >> "$H/passt.log" 2>&1
EOF
    chmod +x "$H/net-passt.sh"
    setsid "$H/net-passt.sh" </dev/null >/dev/null 2>&1 &
    sleep 4
    ls -l "$H/passt.sock" 2>&1 | head -1
    ;;
  vhost)
    kill_all
    # --repair-path none 不可省：默认会再建 vu.sock.repair，
    # 上次残留时启动即 "Socket path ... already in use"
    rm -f "$H/vu.sock" "$H/vu.sock.repair" "$H/vu.log"
    cat > "$H/net-vhost.sh" <<EOF
#!/bin/sh
cd "$H"
exec "$PASST" --vhost-user -f -q -s "$H/vu.sock" --repair-path none >> "$H/vu.log" 2>&1
EOF
    chmod +x "$H/net-vhost.sh"
    setsid "$H/net-vhost.sh" </dev/null >/dev/null 2>&1 &
    sleep 4
    ls -l "$H/vu.sock" 2>&1 | head -1
    ;;
  stop)
    kill_all
    echo "stopped"
    ;;
  status)
    for p in $(ls /proc | grep -E '^[0-9]+$'); do
        c=$(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null)
        case "$c" in ./passt_j*) echo "pid $p: $c" ;; esac
    done
    ls -l "$H"/passt.sock "$H"/vu.sock 2>&1
    ;;
  *)
    echo "usage: $0 {passt|vhost|stop|status}" >&2; exit 2 ;;
esac
