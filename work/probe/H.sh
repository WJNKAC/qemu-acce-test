#!/bin/sh
# H.sh - henge + memfd + 盘 + vars，600 秒窗口。
# 环境变量打开 DMA 命中诊断和 sync_irq 计数。
# 参数全部写死，避免 shell 展开出错（这条是踩过 printf/heredoc 的坑之后定的）。
export HV_DMA_DEBUG=1
export HV_SYNC_IRQ_COUNT=1
exec timeout -s KILL 600 taskset -c 6,7 /data/data/com.termux/files/home/h/q-vu \
  -L /data/local/tmp/henge/bios \
  -M virt,gic-version=3,memory-backend=mem -cpu max -m 2048 \
  -nographic -no-reboot -smp 2 -accel henge \
  -object memory-backend-memfd,id=mem,size=2048M,share=on \
  -drive if=pflash,format=raw,unit=0,file=/data/local/tmp/henge/bios/edk2-aarch64-code.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/data/data/com.termux/files/home/h/r-h2.img \
  -drive if=none,id=d0,format=qcow2,file=/data/data/com.termux/files/home/h/r-h2.qcow2 \
  -device virtio-blk-pci,drive=d0 \
  -drive if=none,id=sd,format=raw,file=/data/data/com.termux/files/home/h/r-h2.iso \
  -device virtio-blk-pci,drive=sd \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  > /data/data/com.termux/files/home/h/H.log 2>&1
