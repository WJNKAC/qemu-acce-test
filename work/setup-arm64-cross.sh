#!/bin/sh
# 在容器内装 x86_64 构建工具链 + aarch64 交叉工具链 + arm64 开发库
set -e
export DEBIAN_FRONTEND=noninteractive
A="-o APT::Sandbox::User=root -y -qq --no-install-recommends"

echo "########## 1) x86_64 侧：QEMU 构建工具链 ##########"
apt-get $A install \
    build-essential gcc g++ make pkg-config \
    meson ninja-build python3 python3-venv \
    git ca-certificates flex bison \
    libglib2.0-dev libpixman-1-dev zlib1g-dev libslirp-dev \
    2>&1 | grep -vE "^(W:|debconf)" | tail -6

echo "########## 2) aarch64 交叉工具链 ##########"
apt-get $A install \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
    2>&1 | grep -vE "^(W:|debconf)" | tail -6

echo "########## 3) arm64 版开发库（交叉编译 QEMU 必须）##########"
apt-get $A install \
    libglib2.0-dev:arm64 libpixman-1-dev:arm64 zlib1g-dev:arm64 libslirp-dev:arm64 \
    2>&1 | grep -vE "^(W:|debconf)" | tail -10

echo "########## 结果自检 ##########"
echo -n "foreign arch: "; dpkg --print-foreign-architectures | tr '\n' ' '; echo
for t in meson ninja pkg-config aarch64-linux-gnu-gcc; do
    printf "%-28s %s\n" "$t" "$(command -v $t || echo MISSING)"
done
echo -n "x86_64 glib: "; pkg-config --modversion glib-2.0
echo -n "arm64  glib: "
PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig pkg-config --modversion glib-2.0 || echo MISSING
echo -n "arm64 glib pc: "
ls /usr/lib/aarch64-linux-gnu/pkgconfig/glib-2.0.pc 2>/dev/null || echo MISSING
