#!/bin/bash
# build-vnc.sh —— 编一个**带 VNC 显示**的 qemu-system-aarch64（Android / henge）
#
# 为什么单独一个脚本：这条链有 5 个坑，每个都让人重试一整轮编译。
# 13.64 那轮我踩的顺序是：--help 清空主力 build → -Werror 报 hv_helper →
# 9p 的 packed → --static 与 slirp 冲突 → keymap 缺文件。
# 全部固化在这里，下次一条命令。
#
# 用法:
#   ./build-vnc.sh              # 增量（已有 build 就复用）
#   ./build-vnc.sh --fresh      # 从头 cmake setup
#   ./build-vnc.sh --deps       # 只重编 pixman
#
# 产物: $BUILD/qemu-system-aarch64
set -eu

QSRC=${QSRC:-/data/用户/项目/qemu-acce/src/qemu-mainline}
BUILD=${BUILD:-/tmp/qb-vnc}          # 独立目录，绝不碰 $QSRC/build
DEPS=${DEPS:-/data/qemu-android/prefix}
NDK_TOOLCHAIN=${NDK_TOOLCHAIN:-/data/software/apps/android_studio/main/x86_64/installed/android-sdk/ndk/29.0.14206865/toolchains/llvm/prebuilt/linux-x86_64}
WRAPS=${WRAPS:-/data/qemu-android/wrappers/aarch64-linux-android30-}
JOBS=$(nproc)

# ------------------------------------------------------------------ pixman
# 唯一的新依赖。NDK sysroot 里没有，必须自己编。
# 装进 $DEPS 是硬要求：QEMU 的 configure 会把 pkg_config_libdir 固化进
# config-meson.cross，靠 PKG_CONFIG_PATH 指是没用的（13.x 记过这条）。
build_pixman() {
    local V=0.44.2
    local S=/tmp/pixman-$V
    local TAR=/tmp/pixman-$V.tar.gz
    [ -f "$TAR" ] || curl -sL -o "$TAR" "https://cairographics.org/releases/pixman-$V.tar.gz"
    [ -d "$S" ] || tar xzf "$TAR" -C /tmp
    cd "$S"

    cat > /tmp/android-aarch64-cross.txt <<'EOF'
[binaries]
c = 'aarch64-linux-android30-clang'
cpp = 'aarch64-linux-android30-clang++'
ar = 'llvm-ar'
strip = 'llvm-strip'
ranlib = 'llvm-ranlib'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

    rm -rf build-android
    PATH="$NDK_TOOLCHAIN/bin:$PATH" meson setup build-android \
        --cross-file /tmp/android-aarch64-cross.txt \
        --prefix=/tmp/pixman-stage -Ddefault_library=static >/dev/null
    PATH="$NDK_TOOLCHAIN/bin:$PATH" ninja -C build-android >/dev/null

    # 手工装（DESTDIR 比 --prefix 可靠：meson 的 install 不接受位置参数）
    rm -rf /tmp/pixman-stage
    DESTDIR= PATH="$NDK_TOOLCHAIN/bin:$PATH" ninja -C build-android install >/dev/null
    local SRC=/tmp/pixman-stage
    cp -f "$SRC/lib/libpixman-1.a" "$DEPS/lib/"
    mkdir -p "$DEPS/include"
    cp -r "$SRC/include/pixman-1" "$DEPS/include/"
    sed "s|^prefix=.*|prefix=$DEPS|" "$SRC/lib/pkgconfig/pixman-1.pc" > "$DEPS/lib/pkgconfig/pixman-1.pc"

    echo "pixman: $(ls -l "$DEPS/lib/libpixman-1.a" | awk '{print $5}') B"
    objdump_arch="$NDK_TOOLCHAIN/bin/llvm-objdump"
    $objdump_arch -f "$DEPS/lib/libpixman-1.a" 2>/dev/null | grep -m1 architecture || true
}

# ------------------------------------------------------------------ qemu
configure_qemu() {
    mkdir -p "$BUILD"; cd "$BUILD"
    export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
    unset PKG_CONFIG_PATH

    # 逐条都对应一个踩过的坑，注释保留原因。
    "$QSRC/configure" \
        --target-list=aarch64-softmmu \
        --cross-prefix="$WRAPS" \
        --enable-henge --enable-slirp \
        --enable-vnc --enable-pixman \
        --enable-fdt=internal \
        --disable-werror \
        --disable-docs --disable-guest-agent --disable-modules \
        --disable-capstone --disable-malloc-trim \
        --disable-attr --disable-keyring --disable-l2tpv3 --disable-plugins \
        --disable-replication --disable-tpm \
        --disable-vhost-crypto --disable-vhost-kernel --disable-vhost-vdpa \
        --disable-virtfs \
        -Ddefault_library=static
}

check_config() {
    cd "$BUILD"
    local need="CONFIG_VNC CONFIG_PIXMAN"
    for k in $need; do
        grep -q "^#define $k\$" config-host.h || { echo "!! $k 没开"; exit 4; }
    done
    grep -q "^#undef CONFIG_VIRTFS" config-host.h || { echo "!! VIRTFS 还开着（9p 会编不过）"; exit 4; }
    echo "config: VNC/PIXMAN 已开，VIRTFS 已关"
}

case "${1:-}" in
    --deps) build_pixman; exit 0 ;;
    --fresh)
        build_pixman
        rm -rf "$BUILD"
        configure_qemu
        ;;
    "")
        [ -f "$BUILD/config-host.mak" ] || { build_pixman; configure_qemu; }
        ;;
    *) echo "未知参数 $1"; exit 2 ;;
esac

check_config
cd "$BUILD"
ninja qemu-system-aarch64
echo
echo "产物: $BUILD/qemu-system-aarch64 ($(ls -l qemu-system-aarch64 | awk '{print $5}') B)"
echo "依赖:"
"$NDK_TOOLCHAIN/bin/llvm-readelf" -d qemu-system-aarch64 | grep NEEDED | sed 's/^/  /'
echo
echo "注意：libslirp.so.0 若出现在上面，说明 -Ddefault_library=static 没生效。"
echo "部署时别忘了 keymap："
echo "  adb push $QSRC/pc-bios/keymaps/en-us /data/local/tmp/henge/bios/keymaps/"
