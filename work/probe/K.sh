#!/bin/sh
# K.sh - 基线复现：匿名 RAM + slirp + **cp 的完整 deb12.qcow2**（不用 overlay）。
# 这是为了区分两个变量：
#   A2 卡住是"匿名 RAM 变了"还是"overlay 盘有问题"。
# 如果 K 能到 BDS、A2 不能，那 overlay 就是唯一变量，
# 今天所有用 overlay 的结论（H/A2）都要作废重测。
export HV_SYNC_IRQ_COUNT=1
exec timeout -s KILL 240 taskset -c 6,7 /data/data/com.termux/files/home/h/q-vu \
  -L /data/local/tmp/henge/bios \
  -M virt,gic-version=3 -cpu max -m 2048 \
  -nographic -no-reboot -smp 2 -accel henge \
  -drive if=pflash,format=raw,unit=0,file=/data/local/tmp/henge/bios/edk2-aarch64-code.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/data/data/com.termux/files/home/h/k-vars.img \
  -drive if=none,id=d0,format=qcow2,file=/data/data/com.termux/files/home/h/k-disk.qcow2 \
  -device virtio-blk-pci,drive=d0 \
  -drive if=none,id=sd,format=raw,file=/data/data/com.termux/files/home/h/k-seed.iso \
  -device virtio-blk-pci,drive=sd \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  > /data/data/com.termux/files/home/h/K.log 2>&1
