#!/bin/sh
# w1.sh - 手动构造，只为开 HV_WFI_COUNT。
# launch3.sh 在 HVDBG 前置赋值下会因 set -eu 提前退出，所以这里不依赖它。
#
# HV_WFI_COUNT=1 会让引擎打印三条 WFI 路径的计数：
#   A(line-high) = IRQ 已挂起，直接返回（不睡）
#   B(no-tick)   = m->tick 为 NULL，整个 WFI 交回 QEMU
#   slept        = 真的 sleep 了
# 这三者的比例直接决定 96 秒的主人是谁。
export HV_WFI_COUNT=1
exec taskset -c 0,1 /data/data/com.termux/files/home/h/b-old \
  -L /data/local/tmp/henge/bios \
  -M virt,gic-version=3 -cpu max -m 2048 \
  -display none -no-reboot -smp 2 -accel henge \
  -drive if=pflash,format=raw,unit=0,file=/data/local/tmp/henge/bios/edk2-aarch64-code.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/data/data/com.termux/files/home/h/g-W2.img \
  -serial file:/data/data/com.termux/files/home/h/run-W2.serial.log \
  -monitor none
