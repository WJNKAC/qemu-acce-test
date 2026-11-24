#!/bin/bash
# build-android.sh —— 编 Android(bionic, NDK) 上的 qemu-system-aarch64 + henge
#
# 这是**唯一**的 Android 构建脚本，取代 build-vnc.sh。
# 参数集就是「对齐 Termux qemu-system-aarch64-headless 1:11.1.3」的唯一事实来源：
#   - 对齐口径见 port-android/TERMUX-TESTING.md 的 Tier A/B/C
#   - 任何在这里增删特性的改动，都要同步 conformance 的期望差集
#
# 与 Termux 包的差别只有两处：
#   1. 多一个 -accel henge；
#   2. 少几项——分两类，别混：
#      * 真做不了：alsa（/dev/snd 读不到）、jack/dbus/spice（Android 无服务）、
#        vhost-*（无 /dev/vhost-*）、passt（seccomp SIGSYS）、l2tpv3（CAP_NET_RAW）；
#      * 还没做（留位子）：pa 音频（Termux 的 PulseAudio 守护进程能出声）、
#        usb-host/usb-redir（Termux:API 的 termux-usb 提供设备 fd）。
#      这两项的 TODO 见文件末尾。
#
# 历史教训（别再犯）：
#   9p 曾经因为「clang 对 packed 更严」的错误归因被 --disable-virtfs 关掉，
#   而真正的修法（include/qemu/osdep.h 里 undef 掉 bionic 的 st_*_nsec 宏）
#   早就进了树。于是 VNC 构建把 9p 关了，部署的永远是没 9p 的那个。
#   现在 check_config 是**正向**断言：要的东西必须在。
#
# 用法:
#   ./build-android.sh                 # 增量（已有 build 就复用）
#   ./build-android.sh --fresh         # 从头 configure
#   ./build-android.sh --deps          # 只重编 pixman
#   ./build-android.sh --check         # 只检查现有 build 的 config，不编
#   JOBS=4 ./build-android.sh          # 限并发（默认取 nproc，内存紧时下调）
#
# 产物: $BUILD/q-henge  +  $BUILD/q-henge.sha256
set -eu

QSRC=${QSRC:-/data/用户/项目/qemu-acce/src/qemu-henge}
# 构建目录必须放在 / 上，不能放 /tmp：/tmp 是 6.7 GB 的 tmpfs（吃内存），
# 一次完整 build 要 3 GB+，2026-11-19 就在 2076/2225 处撞过 Disk quota exceeded。
BUILD=${BUILD:-/data/qemu-android/build-android}
DEPS=${DEPS:-/data/qemu-android/prefix}
NDK_TOOLCHAIN=${NDK_TOOLCHAIN:-/data/software/apps/android_studio/main/x86_64/installed/android-sdk/ndk/29.0.14206865/toolchains/llvm/prebuilt/linux-x86_64}
WRAPS=${WRAPS:-/data/qemu-android/wrappers/aarch64-linux-android30-}
JOBS=${JOBS:-$(nproc)}

say() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

# 版本戳：让手机上的 --version 直接说出「哪个提交、干净与否」。
# 现在 q-rt / q-vnc / q-9p 三个名字已经说不清谁是谁了。
pkgversion() {
    local sha dirty
    sha=$(git -C "$QSRC" rev-parse --short HEAD 2>/dev/null || echo unknown)
    if git -C "$QSRC" diff --quiet 2>/dev/null; then dirty=""; else dirty="-dirty"; fi
    printf 'henge-11.1.3-%s%s' "$sha" "$dirty"
}

# ------------------------------------------------------------------ pixman
# 唯一的新依赖（VNC 需要）。NDK sysroot 里没有，必须自己编。
# 装进 $DEPS 是硬要求：QEMU 的 configure 会把 pkg_config_libdir 固化进
# config-meson.cross，靠 PKG_CONFIG_PATH 指是没用的。
build_pixman() {
    local V=0.44.2
    local S=/tmp/pixman-$V
    local TAR=/tmp/pixman-$V.tar.gz
    if [ ! -f "$DEPS/lib/libpixman-1.a" ]; then
        [ -f "$TAR" ] || curl -sL -o "$TAR" "https://cairographics.org/releases/pixman-$V.tar.gz"
        [ -d "$S" ] || tar xzf "$TAR" -C /tmp

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

        rm -rf "$S/build-android"
        PATH="$NDK_TOOLCHAIN/bin:$PATH" meson setup "$S/build-android" \
            --cross-file /tmp/android-aarch64-cross.txt \
            --prefix="$DEPS" -Ddefault_library=static >/dev/null
        PATH="$NDK_TOOLCHAIN/bin:$PATH" ninja -C "$S/build-android" >/dev/null
        PATH="$NDK_TOOLCHAIN/bin:$PATH" ninja -C "$S/build-android" install >/dev/null
        echo "pixman: $(ls -l "$DEPS/lib/libpixman-1.a" | awk '{print $5}') B"
    else
        echo "pixman: 已在 $DEPS（跳过）"
    fi
}

# ------------------------------------------------------------------ qemu
configure_qemu() {
    mkdir -p "$BUILD"; cd "$BUILD"
    export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig"
    unset PKG_CONFIG_PATH

    local ver; ver=$(pkgversion)
    say "configure（$ver）"

    # 逐条都对应一个踩过的坑或一个对齐决策，注释保留原因。
    "$QSRC/configure" \
        --target-list=aarch64-softmmu \
        --cross-prefix="$WRAPS" \
        --with-pkgversion="$ver" \
        --enable-henge --enable-slirp \
        --enable-vnc --enable-pixman \
        --enable-fdt=internal \
        --enable-virtfs --enable-attr \
        --enable-tpm \
        --disable-werror --disable-zstd \
        --disable-alsa --disable-pa \
        --disable-docs --disable-guest-agent --disable-modules \
        --disable-capstone --disable-malloc-trim \
        --disable-keyring --disable-l2tpv3 --disable-plugins \
        --disable-replication \
        --disable-vhost-crypto --disable-vhost-kernel --disable-vhost-vdpa \
        --disable-vhost-user \
        -Ddefault_library=static
}

# 正向断言：这个构建**必须**有的东西，缺一个就失败。
check_config() {
    cd "$BUILD"
    [ -f config-host.h ] || { echo "!! $BUILD/config-host.h 不存在（先 --fresh）"; exit 4; }
    local need="CONFIG_VNC CONFIG_PIXMAN CONFIG_VIRTFS CONFIG_ATTR CONFIG_SLIRP CONFIG_TCG"
    local miss=0
    for k in $need; do
        # 注意 CONFIG_TCG 写成 "#define CONFIG_TCG 1"，其余是裸 "#define CONFIG_X"，
        # 所以匹配到行尾或空白都算有。
        grep -qE "^#define $k([[:space:]]|\$)" config-host.h || { echo "!! 缺 $k"; miss=1; }
    done
    # TPM 是 auto：libtpms 不在时它会被关掉，不当作硬失败，但要报出来。
    grep -qE "^#define CONFIG_TPM([[:space:]]|\$)" config-host.h \
        && echo "   TPM: 已开" || echo "   TPM: 未开（libtpms 缺失，tpm-tis 设备不会出现）"
    # vhost-user 必须关：44 个设备，静态链接的客户端没有对端进程。
    grep -qE "^#undef CONFIG_VHOST_USER([[:space:]]|\$)" config-host.h \
        || { echo "!! CONFIG_VHOST_USER 还开着（44 个无用的 vhost-user-* 设备）"; miss=1; }
    [ "$miss" = 0 ] || exit 4
    grep -E "^#define CONFIG_(VNC|PIXMAN|VIRTFS|ATTR|SLIRP|TPM)$" config-host.h | sed 's/^/   /'
}

case "${1:-}" in
    --deps)  build_pixman; exit 0 ;;
    --check) check_config; exit 0 ;;
    --fresh)
        build_pixman
        rm -rf "$BUILD"
        configure_qemu
        ;;
    "")
        [ -f "$BUILD/config-host.mak" ] || { build_pixman; configure_qemu; }
        ;;
    *) echo "未知参数 $1（可用: --fresh / --deps / --check）"; exit 2 ;;
esac

check_config

say "ninja -j$JOBS"
cd "$BUILD"
ninja -j"$JOBS" qemu-system-aarch64

cp -f qemu-system-aarch64 q-henge
sha256sum q-henge > q-henge.sha256

say "产物"
ls -l q-henge | awk '{print "   "$9" "$5" B"}'
cat q-henge.sha256 | sed 's/^/   /'
echo
"$NDK_TOOLCHAIN/bin/llvm-readelf" -d q-henge | grep NEEDED | sed 's/^/   /'
echo
echo "版本: $("$NDK_TOOLCHAIN/bin/llvm-strings" q-henge 2>/dev/null | grep -m1 '^henge-11\.' || true)"
echo
echo "部署:  ./termux/deploy.sh            （见 port-android/termux/）"

# ------------------------------------------------------------------ TODO
# [ ] pa 音频：静态编 libpulse-simple 进 $DEPS，configure 加 --enable-pa。
#     可行依据：Termux 自带 PulseAudio 守护进程，sink 走 Android 音频栈，
#     QEMU 的 pa 后端不需要 /dev/snd。验收：客机 aplay 出声。
# [ ] usb-host / usb-redir：Termux:API 的 termux-usb 交出设备 fd，
#     libusb 用 libusb_wrap_sys_device()。先验证 QEMU 侧能否接 fd。
# [ ] 这两项落地后，从 termux/baseline 的期望差集里删掉对应条目。
