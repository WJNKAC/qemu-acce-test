#!/bin/sh
# c2b.sh - 无盘 edk2→Shell，跑在 cpu2,3（当前满频 2.0GHz）。
#
# 目的：区分"卡住"是引擎/二进制问题，还是 CPU6,7 热降频（1.274/2.0 GHz）造成的超时。
# 参数与 C2E 完全相同，唯一的差别是 taskset 的核。
exec timeout -s KILL 240 taskset -c 2,3 /data/data/com.termux/files/home/h/b-old \
  -L /data/local/tmp/henge/bios -M virt,gic-version=3 -cpu max -m 1024 \
  -nographic -no-reboot -smp 2 -accel henge \
  -drive if=pflash,format=raw,unit=0,file=/data/local/tmp/henge/bios/edk2-aarch64-code.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=/data/data/com.termux/files/home/h/e-vars.img \
  > /data/data/com.termux/files/home/h/C2B.log 2>&1
