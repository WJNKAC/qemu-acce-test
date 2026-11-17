#!/bin/sh
# A.sh - 匿名 RAM + slirp + 盘 + vars，600 秒窗口。
# 与 H.sh 唯一的差别是内存后端（匿名 vs memfd），用来对照 sync_irq 计数：
# 如果两边 UEFI 阶段的 sync_irq 都在 30 万量级、而只有 memfd 卡住，
# 那 sync_irq 就不是根因；如果 memfd 侧明显更多，它就是变量。
export HV_SYNC_IRQ_COUNT=1
exec timeout -s KILL 600 taskset -c 6,7 /data/data/com.termux/files/home/h/q-vu \
  -L /data/local/tmp/henge/bios \
  -M virt,gic-version=3 -cpu max -m 2048 \
  -nographic -no-reboot -smp 2 -accel henge \
  -drive if=pflash,format=raw,unit=0,file=/data/local/tmp/henge/bios/edk2-aarch64-code.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/data/data/com.termux/files/home/h/r-a1.img \
  -drive if=none,id=d0,format=qcow2,file=/data/data/com.termux/files/home/h/r-a1.qcow2 \
  -device virtio-blk-pci,drive=d0 \
  -drive if=none,id=sd,format=raw,file=/data/data/com.termux/files/home/h/r-a1.iso \
  -device virtio-blk-pci,drive=sd \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  > /data/data/com.termux/files/home/h/A2.log 2>&1
