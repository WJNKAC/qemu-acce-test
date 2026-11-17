#!/system/bin/sh
# dnsdiag.sh —— 单次 boot，只为回答一个问题：DNS 坏在哪一层。
#
# 与 seedtest.sh 的区别：那个靠 NETPROBE-* 计轮次，这个只等一组 DNSDIAG-* 结束标记。
# 判据只有两条：
#   DNSDIAG-pre-BEGIN    cloud-init 的 runcmd 真的跑到了
#   DNSDIAG-post-END    两个 phase 都跑完了（缺 END = 半途死，不是"通过"）
# seed v2 的 runcmd 有两步：裸状态一次、换 link DNS 后再一次。
# 结束标记认的是第二步 —— 认第一步会在中途退出，post 读数全丢。
# 其余 DNSDIAG-* 行原样吐出，由读的人按层看，脚本不替它下结论。
#
# 用法: dnsdiag.sh <tag> <bin> [timeout_s] [smp] [seed.iso]
set -u
TAG=${1:?tag}
BIN=${2:?bin}
TMO=${3:-300}
SMP=${4:-2}
SEED=${5:-/data/local/tmp/seed-dns.iso}
H=/data/local/tmp
BIOS=$H/henge/bios
LOG=$H/dd-$TAG.serial.log
ERR=$H/dd-$TAG.err
VARS=$H/dd-$TAG.img
DISK=$H/dd-$TAG.qcow2
MPORT=${MPORT:-4470}
NET=${NET:-slirp}
export HV_PASST_NO_SECCOMP=1 HV_PASST_NO_SANDBOX=1 HV_PASST_NO_USERNS=1
PASST_DNS=${PASST_DNS:-223.5.5.5}
# passt 模式下 resolv.conf 里的 nameserver 就是它。故意允许从外部覆盖，
# 用来做"把 DNS 指到一个必然超时的地址"这类对照实验。
KEEP_DISK=${KEEP_DISK:-0}
# 追加到 -netdev user,id=n0 后面的 slirp 选项。留空是常态；
# 用来验"把虚拟 DNS 地址改掉会发生什么"这类反事实实验。
USER_OPTS=${USER_OPTS:-}
# 结束标记。seed 换版本（只跑 pre）时可以 -e ENDMARK=DNSDIAG-pre-END 覆盖。
ENDMARK=${ENDMARK:-DNSDIAG-post-END}

[ -x "$BIN" ] || { echo "MISSING $BIN"; exit 3; }
[ -f "$SEED" ] || { echo "MISSING $SEED"; exit 3; }
say() { echo "$@"; }

# 基线盘必须复制，绝不直接挂 —— 13.44 那次污染就是直接挂 deb12.qcow2。
cp -f $H/vars0.img "$VARS" 2>/dev/null; chmod 644 "$VARS" 2>/dev/null
if [ "$KEEP_DISK" != 1 ]; then
    cp -f ${DISK_SRC:-$H/deb12-clean.qcow2} "$DISK" 2>/dev/null; chmod 644 "$DISK" 2>/dev/null
fi
rm -f "$LOG" "$ERR"

QEMU_ARGS="-L $BIOS -M virt,gic-version=3 -cpu max -m 2048
  -display none -smp $SMP -accel henge
  -drive if=pflash,format=raw,unit=0,file=$BIOS/edk2-aarch64-code.fd,readonly=on
  -drive if=pflash,format=raw,unit=1,file=$VARS
  -drive if=none,id=d0,format=qcow2,file=$DISK -device virtio-blk-pci,drive=d0
  -drive if=none,id=sd,format=raw,file=$SEED -device virtio-blk-pci,drive=sd
  -serial file:$LOG -monitor tcp:127.0.0.1:$MPORT,server,nowait"

# QEMU_ARGS 靠无引号展开，含空格的路径会被拆成两个参数。
for v in "$LOG" "$VARS" "$DISK" "$SEED" "$BIN" "$BIOS"; do
    case "$v" in *" "*) echo "ABORT: 路径含空格，QEMU_ARGS 会拆断: $v"; exit 2 ;; esac
done

# 端口预检。QEMU 报 "Failed to find an available port" 之后现场只剩一个 err 文件，
# 而且这现象在汇总里看起来像"QEMU 莫名退出"。提前查，把原因直接说出来。
PHEX=$(printf '%04X' "$MPORT")
if grep -qaiE ":$PHEX " /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
    say "ABORT: monitor 端口 $MPORT(0x$PHEX) 已被占用 —— 上一轮的 qemu/passt 没死干净。"
    say "       查: ps -A -o PID,NAME | grep -E 'q-p0a8|passt' 然后 kill -9"
    exit 2
fi

case "$NET" in
  slirp)
    # shellcheck disable=SC2086
    # USER_OPTS 用来追加 slirp 选项（例如 ",dns=223.5.5.5"）做对照实验。
    $BIN $QEMU_ARGS -netdev user,id=n0$USER_OPTS -device virtio-net-pci,netdev=n0 >/dev/null 2>"$ERR" &
    QP=$! ;;
  passt)
    [ -x "$H/passtlaunch" ] || { echo "MISSING passtlaunch"; exit 3; }
    [ -x "$H/passt" ]       || { echo "MISSING passt"; exit 3; }
    # shellcheck disable=SC2086
    $H/passtlaunch $H/passt -f -q -F %PFD% -D "$PASST_DNS" -- \
        $BIN $QEMU_ARGS -netdev socket,id=n0,fd=%QFD% -device virtio-net-pci,netdev=n0 \
        >/dev/null 2>"$ERR" &
    QP=$! ;;
  *) echo "bad NET=$NET (slirp|passt)"; exit 2 ;;
esac

# 结束后代：passtlaunch 会 fork 出 passt 与 qemu 两个子进程，杀 launcher
# 不会带走它们。实测：passt1 那轮跑完留下 passt + q-p0a8 两个孤儿，
# 下一轮直接栽在 "-monitor tcp:127.0.0.1:4470: Address already in use"。
# 只按 PPID 递归找子进程 —— 不按名字匹配（名字会打到外层 sh -c 的 cmdline）。
killtree() {
    p=$1
    kids=$(cat /proc/$p/task/$p/children 2>/dev/null)
    [ -z "$kids" ] && kids=$(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')
    for k in $kids; do killtree "$k"; done
    kill -9 "$p" 2>/dev/null
}
cleanup() { killtree "$QP"; }
trap cleanup EXIT HUP INT TERM

BID0=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
say "=== dnsdiag tag=$TAG net=$NET smp=$SMP timeout=${TMO}s ==="
say "seed=$(basename "$SEED")  bin=$(basename "$BIN")"

ELAPSED=0
DONE=0
while [ $ELAPSED -lt $TMO ]; do
    if grep -aq "$ENDMARK" "$LOG" 2>/dev/null; then DONE=1; break; fi
    kill -0 $QP 2>/dev/null || { say "!! QEMU 退出（t=${ELAPSED}s）rc 未知，见 $ERR"; break; }
    BIDN=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    if [ -n "$BIDN" ] && [ "$BIDN" != "$BID0" ]; then
        say "!! DEVICE-REBOOTED: boot_id 变了（$BID0 -> $BIDN）—— 整机重启，不是 QEMU 的问题"
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
done

# 收尾前留一点时间把 serial 缓冲写盘（file: 后端是带缓冲的）
sleep 2
killtree "$QP"
sleep 1
trap - EXIT HUP INT TERM

# ANSI：systemd 的 [  OK  ] 行自带颜色码，会切断任何跨词匹配。
sed -E 's/\x1b\[[0-9;]*m//g' "$LOG" > "$LOG.noansi" 2>/dev/null

say
say "--- DNSDIAG 原文（t=${ELAPSED}s，ansi 已剥）---"
grep -a 'DNSDIAG-' "$LOG.noansi" 2>/dev/null | sed 's/^/  /'
say
BEG=$(grep -ac 'DNSDIAG-pre-BEGIN' "$LOG.noansi" 2>/dev/null); BEG=${BEG:-0}
PREEND=$(grep -ac 'DNSDIAG-pre-END' "$LOG.noansi" 2>/dev/null); PREEND=${PREEND:-0}
POSTB=$(grep -ac 'DNSDIAG-post-BEGIN' "$LOG.noansi" 2>/dev/null); POSTB=${POSTB:-0}
END=$(grep -ac 'DNSDIAG-post-END' "$LOG.noansi" 2>/dev/null); END=${END:-0}
say "=== 完整性 ==="
say "  pre:  BEGIN=$BEG  END=$PREEND      post: BEGIN=$POSTB  END=$END"
if [ "$BEG" -eq 0 ]; then
    say "  ✗ 没有 DNSDIAG-pre-BEGIN：cloud-init 的 runcmd 没跑到。"
    say "    依次查：seed 挂上没（virtio-blk 第二个盘）、instance-id 是否重复、约 90s 是否等够。"
    say "    最后 8 行 serial："
    tail -8 "$LOG.noansi" 2>/dev/null | sed 's/^/    /'
elif [ "$END" -eq 0 ]; then
    say "  ✗ 没有 post-END：第二阶段半途死（不是通过）。最后 8 行："
    tail -8 "$LOG.noansi" 2>/dev/null | sed 's/^/    /'
else
    say "  ✓ 两个 phase 都跑完了"
fi
say "boot_id: 起始 $BID0  结束 $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
[ -s "$ERR" ] && { say "--- stderr（非空，QEMU/passt 有话说）---"; tail -5 "$ERR" | sed 's/^/  /'; }
