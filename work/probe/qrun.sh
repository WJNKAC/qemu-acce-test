#!/bin/sh
#
# qrun.sh - 设备侧 QEMU 启动器（v2）
#
# 相对 v1 的三处纪律修正，全部来自实际翻车：
#
#   1. set -eu。v1 只有 `set -u`，于是 `cp` 失败、`TAG` 没 export 这类错误
#      一路带病执行到"日志为空"，而我还去猜引擎问题。现在任何一步失败立即停。
#
#   2. 前置存在性检查。qemu 二进制 / BIOS / 三个镜像，缺一个就当场报错，
#      不再生成一个注定失败的 cmd。
#
#   3. qcow2 backing overlay 代替 405MB 的 cp。以前每轮都 cp deb12.qcow2(340M)
#      + vars0.img(64M) + seed.iso，SSH 会话一超时就把它打断，日志根本没产生，
#      而现象看起来像"QEMU 起不来"。overlay 只有几 KB，且天然满足
#      "每轮全新"的测量卫生（写全落在 overlay 上，backing 只读）。
#      overlay 由调用方在本地用 qemu-img 生成后推过来，这里只负责用它。
#
# 用法：
#   ./qrun.sh <mode> [tag]
#   mode: slirp | slirp-memfd | passt-stream | passt-vhost | tcg-memfd | tcg-slirp
#
# 环境：MEM SMP CPUS SECS TAG
set -eu

H=${H:-/data/data/com.termux/files/home/h}
BIOS=${BIOS:-/data/local/tmp/henge/bios}
MODE=${1:?usage: qrun.sh <mode> [tag]}
TAG=${2:-${TAG:-$(date +%H%M%S)}}
MEM=${MEM:-2048}
SMP=${SMP:-2}
CPUS=${CPUS:-6,7}
SECS=${SECS:-400}
export TAG SECS MEM SMP CPUS

QEMU=${QEMU:-$H/q-vu}
DISK=$H/r-$TAG.qcow2
VARS=$H/r-$TAG.img
SEED=$H/r-$TAG.iso
LOG=$H/r-$TAG.log

# ---- 前置检查：缺东西就当场停，不要生成注定失败的 cmd ----
for f in "$QEMU" "$BIOS/edk2-aarch64-code.fd" "$DISK" "$VARS" "$SEED"; do
    if [ ! -e "$f" ]; then
        echo "MISSING: $f" >&2
        echo "  overlay 必须由本地 qemu-img 生成后推过来，例如：" >&2
        echo "  qemu-img create -f qcow2 -b $H/deb12.qcow2 -F qcow2 $DISK" >&2
        exit 3
    fi
done

# ---- 机器型号：gic-version 与 memory-backend 必须在同一个 -M 里 ----
# 写成两个 -M / -machine，后者会整体覆盖前者，gic-version=3 被丢掉，
# QEMU 直接静默退出（0 行日志），看起来像"什么都没发生"。
MACHINE="virt,gic-version=3"
MEMARGS="-m $MEM"
ACCEL="henge"
NETARGS=""

case "$MODE" in
  slirp)
    NETARGS="-netdev user,id=n0 -device virtio-net-pci,netdev=n0"
    ;;
  slirp-memfd)
    MEMARGS="$MEMARGS -object memory-backend-memfd,id=mem,size=${MEM}M,share=on"
    MACHINE="$MACHINE,memory-backend=mem"
    NETARGS="-netdev user,id=n0 -device virtio-net-pci,netdev=n0"
    ;;
  tcg-slirp)
    ACCEL="tcg"
    NETARGS="-netdev user,id=n0 -device virtio-net-pci,netdev=n0"
    ;;
  tcg-memfd)
    ACCEL="tcg"
    MEMARGS="$MEMARGS -object memory-backend-memfd,id=mem,size=${MEM}M,share=on"
    MACHINE="$MACHINE,memory-backend=mem"
    NETARGS="-netdev user,id=n0 -device virtio-net-pci,netdev=n0"
    ;;
  passt-stream)
    NETARGS="-netdev stream,id=n0,server=off,addr.type=unix,addr.path=$H/passt.sock -device virtio-net-pci,netdev=n0"
    ;;
  passt-vhost)
    MEMARGS="$MEMARGS -object memory-backend-memfd,id=mem,size=${MEM}M,share=on"
    MACHINE="$MACHINE,memory-backend=mem"
    NETARGS="-chardev socket,id=chr0,path=$H/vu.sock -netdev vhost-user,id=n0,chardev=chr0 -device virtio-net-pci,netdev=n0"
    ;;
  *)
    echo "unknown mode: $MODE" >&2
    exit 2
    ;;
esac

CMD=$H/cmd-$TAG.sh
cat > "$CMD" <<EOF
#!/bin/sh
exec timeout -s KILL $SECS taskset -c $CPUS "$QEMU" -L "$BIOS" \\
  -M $MACHINE -cpu max $MEMARGS -nographic -no-reboot -smp $SMP -accel $ACCEL \\
  -drive if=pflash,format=raw,unit=0,file=$BIOS/edk2-aarch64-code.fd,readonly=on \\
  -drive if=pflash,format=raw,unit=1,file=$VARS \\
  -drive if=none,id=d0,format=qcow2,file=$DISK -device virtio-blk-pci,drive=d0 \\
  -drive if=none,id=sd,format=raw,file=$SEED -device virtio-blk-pci,drive=sd \\
  $NETARGS > "$LOG" 2>&1
EOF
chmod +x "$CMD"

printf "mode=%s tag=%s accel=%s\n" "$MODE" "$TAG" "$ACCEL"
printf "  machine: %s\n" "$MACHINE"
printf "  mem:     %s\n" "$MEMARGS"
printf "  net:     %s\n" "$(echo "$NETARGS" | tr -s ' ')"
printf "  log:     %s\n" "$LOG"
printf "  cmd:     %s\n" "$CMD"
