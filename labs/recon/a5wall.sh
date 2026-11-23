#!/bin/bash
# a5wall.sh <smp> <serial-prefix> <secs> —— A5 墙：authority 形态的 time-to-GDM + IAR 延迟
#
# 判据（DESIGN 预注册）：time-to-GDM 不回归（smp4 硬门 ≤90 s）；
# IAR 均值 ≤15 µs、≥160 µs 的尾巴 <1%。
# 手表用轮询 serial 里的 gdm.service 得到，guest 时间戳另记。
set -u
cd "$HOME/qa" || exit 1
smp=$1; ser=$2; secs=$3
cp -f bios/vars.base a3-vars.img
rm -f "$ser" "$ser.log" "$ser.gdm"
t0=$(date +%s.%N)
(
  while [ ! -f "$ser.gdm" ]; do
    if grep -aq "gdm.service" "$ser" 2>/dev/null; then
      date +%s.%N > "$ser.gdm"
      break
    fi
    sleep 0.2
  done
) &
wd=$!
HENGE_GIC_AUTHORITY=1 HENGE_IAR_LAT=1 timeout -s TERM -k 5 "$secs" ./bin/q-henge -accel henge \
  -L /data/data/com.termux/files/usr/share/qemu -M virt,gic-version=3,its=off -cpu max -m 2048 -smp "$smp" \
  -drive if=pflash,format=raw,unit=0,file=bios/edk2-aarch64-code.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=a3-vars.img \
  -drive if=none,id=d0,format=qcow2,file=images/ovl-henge.qcow2 -device virtio-blk-pci,drive=d0 \
  -nic user,model=virtio-net-pci -display none -serial file:"$ser" -monitor none \
  >/dev/null 2>"$ser.log"
rc=$?
kill "$wd" 2>/dev/null
t1=$(date +%s.%N)
if [ -f "$ser.gdm" ]; then
  g=$(awk -v a="$t0" -v b="$(cat "$ser.gdm")" 'BEGIN{printf "%.1f", b-a}')
else
  g=none
fi
last=$(sed -n 's/^\[ *\([0-9]*\.[0-9]*\)\].*/\1/p' "$ser" 2>/dev/null | tail -1)
echo "A5 smp=$smp rc=$rc gdm_wall=${g}s wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}') last_ts=${last:-none} lines=$(wc -l < "$ser")"
grep henge-iarlat "$ser.log" 2>/dev/null | tail -2
