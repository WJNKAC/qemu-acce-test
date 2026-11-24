#!/bin/bash
# henge-probe: 一条命令证明"引擎真的在 QEMU 的 RAM 上执行 guest 代码"
#
# 为什么需要这个探针。跑到 0x40080000 并不能证明什么——引擎完全可以在
# 一个空 RAM 表上取指失败、然后报一个看起来像"跑到入口了"的错误。这个
# 探针让 guest 做三件可观察的事：
#
#   1. 取指 + 执行      movz/adr/ldrb(后索引)/cbz/strb/b
#   2. MMIO 写          向 PL011 DR (0x09000000) 写字符串
#   3. WFI              让引擎走 HENGE_EXIT_WFI 干净退出
#
# 第 2 步是关键：PL011 是 QEMU 的设备模型，引擎自己没有任何设备。能看到
# HENGE-MMIO-OK 就说明整条路径成立：
#
#   guest store -> 引擎快路径 miss -> 引擎慢路径 -> 引擎 MMIO 表未命中
#       -> catch-all HvMmio -> henge_mmio_forward()
#       -> address_space_rw() -> QEMU 的 pl011 -> 串口
#
# tcg 对照必须在同一份 probe.elf 上打印同样的字符串，否则说明探针本身有
# 问题（踩过：多写 -nodefaults 会去掉 PL011，两边都静默无输出）。
#
# 交叉汇编必须在容器内做——宿主 x86_64 上没有 aarch64-linux-gnu-gcc。
set -eu

CT=/data/用户/应用/操作系统/虚拟化/容器/Devuan/excalibur/apm-test/overlay/manual-build-qemu
PW=${SUDO_PW:-laptop}
SRCDIR=$(cd "$(dirname "$0")/probe" && pwd)

as_root() { echo "$PW" | sudo -S -p '' "$@"; }
in_ct() { echo "$PW" | sudo -S -p '' "$CT/tool/rurima" r -S -k cap_sys_admin "$CT/overlay" /bin/sh "$@"; }

as_root mkdir -p "$CT/overlay/work/probe"
as_root cp "$SRCDIR/probe.S" "$SRCDIR/probe.ld" "$CT/overlay/work/probe/"

RUN=$(mktemp)
cat > "$RUN" <<'EOS'
set -e
cd /work/probe
aarch64-linux-gnu-gcc -nostdlib -nostartfiles -T probe.ld -o probe.elf probe.S 2>/dev/null
aarch64-linux-gnu-readelf -h probe.elf | grep -E "Entry point"
cd /src/qemu-henge
export QEMU_LD_PREFIX=/usr/aarch64-linux-gnu
Q=./build/qemu-system-aarch64
M="-M virt -cpu cortex-a57 -m 256 -smp 1 -nographic"
echo "--- tcg 对照（必须打印 HENGE-MMIO-OK）---"
timeout 10 qemu-aarch64 $Q $M -accel tcg -kernel /work/probe/probe.elf 2>&1 | head -3
echo "--- henge ---"
timeout 10 qemu-aarch64 $Q $M -accel henge -kernel /work/probe/probe.elf 2>&1 | head -5
echo "--- henge + HENGE_DEBUG_RAM（RAM 镜像与 MMIO）---"
HENGE_DEBUG_RAM=1 timeout 10 qemu-aarch64 $Q $M -accel henge -kernel /work/probe/probe.elf 2>&1 \
    | grep -E "mach-virt.ram|setup_post mirrored|MMIO" | head -4
EOS

as_root cp "$RUN" "$CT/overlay/tmp/probe-run.sh"
rm -f "$RUN"
in_ct /tmp/probe-run.sh
