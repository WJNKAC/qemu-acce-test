#!/bin/sh
# gui.sh —— 在设备上启动一台**带图形界面 + 键鼠**的 Debian 客机
#
# 这套参数是 13.64~13.67 试出来的，每一条都对应一个踩过的坑：
#
#   -device virtio-gpu-pci        必须；但光有它不够，客机内核还得有 virtio_gpu 驱动
#                                 （-cloud 内核没有，见 13.66）
#   -device qemu-xhci             键盘/鼠标必须挂 USB；virtio-keyboard-pci 会让
#                                 henge 直接退出（13.66）
#   -device usb-kbd               键盘。没有它 monitor 的 sendkey 无处投递，
#                                 因为 ui/input.c 的 handlers 链表为空（13.67）
#   -device usb-tablet            鼠标，**绝对坐标**。usb-mouse 是相对的，
#                                 VNC/触摸屏会漂（limbo 也只用 usb-tablet）
#   -serial tcp:...               不用 file:。file 只能写不能读，没法交互；
#                                 tcp 是独占流，配合 probe/serialctl.py 用
#   -vnc 127.0.0.1:N              只绑本机，靠 adb forward 暴露，别绑 0.0.0.0
#   SLIRP_DNS_SERVER=223.5.5.5    Android 没有 /etc/resolv.conf，不给这个变量
#                                 虚拟 DNS 地址整个不可路由（13.54/13.55）
#
# 用法：
#   ./gui.sh start [tag]        启动（默认 tag=gui）
#   ./gui.sh stop [tag]         停止
#   ./gui.sh status [tag]       看进程和端口
#   ./gui.sh shot [tag]         抓一帧到 /tmp/gui-<tag>.png（需要宿主有 PIL）
#
# 环境变量：
#   DISK   客机磁盘（默认 /data/local/tmp/deb12-gui.qcow2）
#   SEED   cloud-init seed（默认 seed-v7，串口 root 自动登录）
#   VARS   UEFI 变量（默认 vars0.img，每次启动复制一份，别共用）
#   RAM    内存 MB（默认 2048）
#   SMP    vCPU 数（默认 2）
set -eu

DEV=${DEV:-3538956564001EV}
TAG=${2:-gui}
BIN=${BIN:-/data/local/tmp/q-vnc}
BIOS=/data/local/tmp/henge/bios
DISK=${DISK:-/data/local/tmp/deb12-gui.qcow2}
SEED=${SEED:-/data/local/tmp/seed-v7.iso}
VARS=${VARS:-/data/local/tmp/vars0.img}
RAM=${RAM:-2048}
SMP=${SMP:-2}

MPORT=4490     # QEMU monitor（screendump / sendkey / mouse_move）
SPORT=4491     # 串口（配合 serialctl.py 交互）
VPORT=5900     # VNC

adbs() { adb -s "$DEV" shell "$@"; }

case "${1:-}" in
start)
    # 先清掉同名实例，避免端口占用
    adbs "for p in \$(ps -A -o PID,ARGS 2>/dev/null | grep '[q]-vnc' | awk '{print \$1}'); do kill -9 \$p 2>/dev/null; done" || true
    sleep 2
    adbs "cp -f $VARS /data/local/tmp/$TAG-vars.img; chmod 644 /data/local/tmp/$TAG-vars.img"

    adbs "cd /data/local/tmp && setsid sh -c 'SLIRP_DNS_SERVER=223.5.5.5 $BIN \
        -L $BIOS \
        -M virt,gic-version=3 -cpu max -m $RAM -smp $SMP -accel henge \
        -drive if=pflash,format=raw,unit=0,file=$BIOS/edk2-aarch64-code.fd,readonly=on \
        -drive if=pflash,format=raw,unit=1,file=/data/local/tmp/$TAG-vars.img \
        -drive if=none,id=d0,format=qcow2,file=$DISK -device virtio-blk-pci,drive=d0 \
        -drive if=none,id=sd,format=raw,file=$SEED -device virtio-blk-pci,drive=sd \
        -device virtio-gpu-pci \
        -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0 \
        -vnc 127.0.0.1:0 \
        -monitor tcp:127.0.0.1:$MPORT,server,nowait \
        -serial tcp:127.0.0.1:$SPORT,server,nowait \
        -netdev user,id=n0 -device virtio-net-pci,netdev=n0' \
        </dev/null >/data/local/tmp/$TAG.out 2>&1 &"

    sleep 6
    adb -s "$DEV" forward tcp:$MPORT tcp:$MPORT >/dev/null 2>&1 || true
    adb -s "$DEV" forward tcp:$SPORT tcp:$SPORT >/dev/null 2>&1 || true
    adb -s "$DEV" forward tcp:$VPORT tcp:$VPORT >/dev/null 2>&1 || true
    echo "已启动 tag=$TAG"
    echo "  monitor 127.0.0.1:$MPORT   serial 127.0.0.1:$SPORT   vnc 127.0.0.1:$VPORT"
    echo "  串口交互: python3 probe/serialctl.py --port $SPORT send \"uname -r\""
    ;;
stop)
    adbs "for p in \$(ps -A -o PID,ARGS 2>/dev/null | grep '[q]-vnc' | awk '{print \$1}'); do kill -9 \$p 2>/dev/null; done" || true
    echo "已停止"
    ;;
status)
    adbs "echo \"q-vnc=\$(ps -A -o ARGS 2>/dev/null | grep -c '[q]-vnc')\"; \
          awk 'NR>1 && \$4==\"0A\" {print \$2}' /proc/net/tcp 2>/dev/null | \
          grep -iE ':118A\$|:118B\$|:170C\$' || echo '端口未监听'"
    ;;
shot)
    # 抓帧并转 PNG。screendump 只能写设备本地，所以要 pull 回来再转。
    OUT=${OUT:-/tmp/gui-$TAG}
    adbs "printf 'screendump /data/local/tmp/$TAG-shot.ppm\r' | timeout 10 nc 127.0.0.1 $MPORT >/dev/null 2>&1"
    sleep 2
    adb -s "$DEV" pull "/data/local/tmp/$TAG-shot.ppm" "$OUT.ppm" >/dev/null
    /usr/bin/python3 -c "
from PIL import Image
im = Image.open('$OUT.ppm')
im.save('$OUT.png')
print('$OUT.png', im.size)
"
    ;;
*)
    sed -n '2,40p' "$0"
    ;;
esac
