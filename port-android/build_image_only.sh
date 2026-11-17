#!/bin/bash
# 增量构建内核 Image。注意务必非交互：olddefconfig 遇到新增配置项会提示，
# 而 make 在后台跑时没人应答就会一直挂着（表现为"构建卡死"）。
set -e
H=$(cd "$(dirname "$0")" && pwd)
. "$H/config.sh"
K=$CACHE/linux-6.12
cd $K
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- PATH=/usr/bin:/bin:$PATH
export KCONFIG_NOTIMESTAMP=1
yes "" | make ARCH=arm64 olddefconfig >/dev/null 2>&1 </dev/null
rm -f usr/initramfs_data.cpio*          # initramfs 内容变了必须重打
make -j"$(nproc)" Image </dev/null
ls -lh arch/arm64/boot/Image
