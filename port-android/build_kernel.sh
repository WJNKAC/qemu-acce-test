#!/bin/bash
# 构建一个自包含的 aarch64 内核：initramfs 与 cmdline 都编进去，
# 这样 guest 只需要 Image + DTB 两样东西就能起来。
set -e
W=$(cd "$(dirname "$0")" && pwd)
. "$W/config.sh"
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
export PATH=/usr/bin:/bin:$PATH
cd $K
make -j"$(nproc)" defconfig
INITRAMFS=${INITRAMFS:-$W/initramfs-alpine}   # 出货用的那份（Alpine + myinit + 基准）
scripts/config --enable CONFIG_INITRAMFS_SOURCE="$INITRAMFS"
scripts/config --enable CONFIG_DEVTMPFS
scripts/config --enable CONFIG_DEVTMPFS_MOUNT
scripts/config --disable CONFIG_MODULES
scripts/config --enable CONFIG_CMDLINE_BOOL
scripts/config --set-str CONFIG_CMDLINE "console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/myinit loglevel=7"
scripts/config --enable CONFIG_ARM64_VA_BITS_48
scripts/config --enable CONFIG_SERIAL_AMBA_PL011
scripts/config --enable CONFIG_SERIAL_AMBA_PL011_CONSOLE
scripts/config --disable CONFIG_RANDOMIZE_BASE
scripts/config --enable CONFIG_PCI
scripts/config --enable CONFIG_PCI_HOST_GENERIC
scripts/config --enable CONFIG_PCI_MSI
scripts/config --enable CONFIG_BLK_DEV_NVME
scripts/config --enable CONFIG_VIRTIO_PCI
scripts/config --enable CONFIG_VIRTIO_BLK
scripts/config --enable CONFIG_VIRTIO_NET
scripts/config --enable CONFIG_ARM_GIC_V3_ITS
yes "" | make olddefconfig
make -j"$(nproc)" Image
ls -lh $K/arch/arm64/boot/Image
