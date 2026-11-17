#!/bin/sh
# run1.sh - 参数化单格启动器。一格 = "binary × RAM × 盘 × 网络"。
#
# 用法: run1.sh <tag> <binary> <ram:anon|memfd> <disk:cp|overlay> <net:slirp|passt-stream> <secs>
#   例: run1.sh c1 q-net2 anon cp slirp 600
#
# 两条纪律（这轮误判的根因就在缺它们）：
#   1. 日志头两行写二进制 md5 + 完整 argv。跨二进制比数据是之前所有
#      "结论"翻车的来源——加列不够，得让日志自己带身份。
#   2. 用 nohup 不用 setsid。Termux 上 setsid 后台进程经常不启动、
#      日志为空，看起来像"QEMU 起不来"。这个坑单独浪费了多轮。
#
# 盘:
#   cp      = 设备本地 cp deb12.qcow2（340MB，本地很快；必须 nohup 到后台，
#             不能挂在 SSH 前台，否则 60s 会话超时会打断 cp）
#   overlay = 复用本地 qemu-img 生成好的 qcow2（几 KB）
#   vars/seed 永远是 cp —— 它们做 overlay 却写 format=raw 会导致
#   cfi.pflash01 requires 67108864 bytes, backend provides 197120 bytes
set -eu
H=${H:-/data/data/com.termux/files/home/h}
BIOS=${BIOS:-/data/local/tmp/henge/bios}
TAG=${1:?tag}; BIN=${2:?binary}; RAM=${3:?anon|memfd}; DISK=${4:?cp|overlay}; NET=${5:?slirp|passt-stream}; SECS=${6:-600}

D=$H/g-$TAG
LOG=$H/L-$TAG.log

case "$RAM" in
  anon)  MEMARGS="-m 2048"; MACH="virt,gic-version=3" ;;
  memfd) MEMARGS="-m 2048 -object memory-backend-memfd,id=mem,size=2048M,share=on"
         MACH="virt,gic-version=3,memory-backend=mem" ;;
  *) echo "bad ram" >&2; exit 2 ;;
esac

case "$DISK" in
  cp)      DISKFILE=$D.qcow2 ;;
  overlay) DISKFILE=$H/r-$TAG.qcow2 ;;
  *) echo "bad disk" >&2; exit 2 ;;
esac

case "$NET" in
  slirp) NETARGS="-netdev user,id=n0 -device virtio-net-pci,netdev=n0" ;;
  passt-stream) NETARGS="-netdev stream,id=n0,server=off,addr.type=unix,addr.path=$H/passt.sock -device virtio-net-pci,netdev=n0" ;;
  *) echo "bad net" >&2; exit 2 ;;
esac

# 前置检查：缺一即停，不生成注定失败的脚本
for f in "$BIN" "$BIOS/edk2-aarch64-code.fd" "$DISKFILE" "$D.img" "$D.iso"; do
    [ -e "$f" ] || { echo "MISSING: $f" >&2; exit 3; }
done

MD5=$(md5sum "$BIN" | cut -c1-16)

CMD=$H/x-$TAG.sh
cat > "$CMD" <<EOF
#!/bin/sh
export HV_SYNC_IRQ_COUNT=1
exec timeout -s KILL $SECS taskset -c 6,7 $BIN -L $BIOS \\
  -M $MACH -cpu max $MEMARGS -nographic -no-reboot -smp 2 -accel henge \\
  -drive if=pflash,format=raw,unit=0,file=$BIOS/edk2-aarch64-code.fd,readonly=on \\
  -drive if=pflash,format=raw,unit=1,file=$D.img \\
  -drive if=none,id=d0,format=qcow2,file=$DISKFILE -device virtio-blk-pci,drive=d0 \\
  -drive if=none,id=sd,format=raw,file=$D.iso -device virtio-blk-pci,drive=sd \\
  $NETARGS
EOF
chmod +x "$CMD"

# 日志头：身份信息必须在第一手数据之前
{
    echo "# bin=$(basename $BIN) md5=$MD5 size=$(stat -c %s $BIN)"
    echo "# argv: $TAG $BIN ram=$RAM disk=$DISK($(basename $DISKFILE)) net=$NET secs=$SECS"
} > "$LOG"

nohup "$CMD" >> "$LOG" 2>&1 &
echo "launched $TAG (bin=$MD5 ram=$RAM disk=$DISK net=$NET secs=$SECS) pid=$!"
