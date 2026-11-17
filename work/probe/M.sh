#!/bin/sh
# M.sh - 最终判定：memfd + **完整 cp 的盘**（T1 那套）+ slirp。
#
# 为什么必须是完整 cp 的盘：
#   H 那次（memfd）用的是 overlay 盘，而 A2 已经证明 overlay 盘单独就能让
#   匿名 RAM 卡在 BdsDxe 前。所以 H 的失败被 overlay 污染，不能用来判 memfd。
#   这一格把 overlay 这个变量彻底拿掉，只剩 memfd。
# 判据：BdsDxe 是否出现。出现 = memfd 无罪，问题全在 overlay。
export HV_SYNC_IRQ_COUNT=1
exec timeout -s KILL 240 taskset -c 6,7 /data/data/com.termux/files/home/h/q-vu \
  -L /data/local/tmp/henge/bios \
  -M virt,gic-version=3,memory-backend=mem -cpu max -m 2048 \
  -nographic -no-reboot -smp 2 -accel henge \
  -object memory-backend-memfd,id=mem,size=2048M,share=on \
  -drive if=pflash,format=raw,unit=0,file=/data/local/tmp/henge/bios/edk2-aarch64-code.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/data/data/com.termux/files/home/h/T1.img \
  -drive if=none,id=d0,format=qcow2,file=/data/data/com.termux/files/home/h/T1.qcow2 \
  -device virtio-blk-pci,drive=d0 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  > /data/data/com.termux/files/home/h/M.log 2>&1
