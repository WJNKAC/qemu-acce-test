#!/bin/bash
# 所有脚本共用的路径与环境。
#
# 纪律：不写死绝对路径，也不写死设备序列号 —— 换机器、换手机都能直接跑。
# 目录约定：
#   src/      上游参考实现（只读）
#   port-android/  移植源码 + 构建脚本（本文件所在处）
#   cache/    大件中间产物（内核树、镜像、日志、下载物）——换设备不必带走
#   output/   可执行交付物（换设备只拷这一份）

H=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)     # port-android
ROOT=$(cd "$H/.." && pwd)                            # qemu-acce
CACHE=${CACHE:-$ROOT/cache}
K=${K:-$CACHE/linux-6.12}                            # 内核源码树
OUT=$ROOT/output
BIN=$OUT/bin
DEV=${DEV:-/data/local/tmp}                          # 设备上的工作目录

# 设备：显式给 SERIAL 就用它，否则取第一个在线设备
if [ -z "${SERIAL:-}" ]; then
    SERIAL=$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device"{print $1; exit}')
fi
[ -n "${SERIAL:-}" ] || { echo "没有可用的 adb 设备（或用 SERIAL=xxx 指定）" >&2; return 1 2>/dev/null || exit 1; }

NDK=${NDK:-/data/software/apps/android_studio/main/x86_64/installed/android-sdk/ndk/29.0.14206865/toolchains/llvm/prebuilt/linux-x86_64/bin}
CC_ANDROID=$NDK/aarch64-linux-android30-clang

adbd() { adb -s "$SERIAL" "$@"; }

export H ROOT CACHE K OUT BIN DEV SERIAL NDK CC_ANDROID
