#!/bin/sh
# 交叉编译 QEMU（aarch64 产物）
set -e
cd /src/qemu-mainline
export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig
export PKG_CONFIG_LIBDIR=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/share/pkgconfig

# 并行度：容器里 nproc 会看到全部 CPU
N=$(nproc)
echo "=== ninja -j$N ==="
ninja -C build -j"$N" 2>&1 | grep -vE "^\[[0-9]+/[0-9]+\]" | tail -40

echo "=== 产物自检 ==="
ls -l build/qemu-system-aarch64 2>/dev/null
file build/qemu-system-aarch64 2>/dev/null
echo "=== hv accel 是否编进去 ==="
aarch64-linux-gnu-strings build/qemu-system-aarch64 2>/dev/null | grep -iE "^hv$|hv-accel|Hv acceleration" | head -5 || true
