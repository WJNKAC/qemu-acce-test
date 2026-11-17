#!/bin/bash
# 编译 passt（Android/aarch64，bionic）。六处 bionic 兼容改动见 FINDINGS.md 第八节。
# 产物推到设备：adb push passt /data/local/tmp/passt
set -e
W=/data/用户/项目/qemu-acce/port-android/work
NDK=/data/software/apps/android_studio/main/x86_64/installed/android-sdk/ndk/29.0.14206865/toolchains/llvm/prebuilt/linux-x86_64/bin
SRC=$W/passt-2026_10_02.cba3570

if [ ! -d "$SRC" ]; then
    echo "== 取 passt 源码（Debian 源里有，比 GitHub 可靠）"
    cd "$W"
    curl -sSLO "https://mirrors.tuna.tsinghua.edu.cn/debian/pool/main/p/passt/passt_0.0~git20261002.cba3570.orig.tar.xz"
    tar xJf passt_0.0~git20261002.cba3570.orig.tar.xz
fi

cd "$SRC"
# 四个 Android 开关（缺一个就是 SIGSYS 静默死亡，退出码 159 = 128+31）
#   HV_PASST_NO_CAPDROP       capget/capset/PR_CAPBSET_DROP 被 seccomp 直接杀。
#                             drop_caps_ep_except() 和 clamp_caps() 两处都要关。
#   HV_PASST_NO_USERNS        ns_is_init() 读不到 /proc/self/uid_map
#   HV_PASST_NO_SECCOMP       passt 装的白名单按 glibc 生成，bionic 下第一个 SYN 就死
#   HV_PASST_NO_CLOSE_RANGE   close_range(2) 被 seccomp 杀成 SIGSYS（不是 ENOSYS），
#                             原代码只兜 ENOSYS/EINVAL，兜不住 → 改用循环 close()
#   HV_PASST_NO_SETGROUPS     setgroups(2) [aarch64 159] 被 seccomp 杀
#   HV_PASST_NO_SANDBOX       isolate_prefork 的 unshare(IPC|NS|UTS|PID) 要 CAP_SYS_ADMIN，
#                             isolate_user 的 setgid/setuid [144/146] 也被杀
#
# 排查方法（很有用）：Android seccomp 用 SECCOMP_RET_TRAP，进程收到 SIGSYS
# （rc=159=128+31）。在 main() 开头装 SA_SIGINFO handler，打印 si_syscall 即可
# 拿到确切的 syscall 号，比二分二进制快得多：
#   [sigsys] syscall=159 arch=3221225655   -> setgroups
#   [sigsys] syscall=144 arch=3221225655   -> setgid
ANDROID_FLAGS="-DHV_PASST_NO_CAPDROP -DHV_PASST_NO_USERNS \
               -DHV_PASST_NO_SECCOMP -DHV_PASST_NO_CLOSE_RANGE \
               -DHV_PASST_NO_SETGROUPS -DHV_PASST_NO_SANDBOX"

make -j"$(nproc)" CC=$NDK/aarch64-linux-android30-clang \
     TARGET=aarch64-linux-android VERSION=2026_10_02 \
     CPPFLAGS="-include $W/passt-compat/android_compat.h $ANDROID_FLAGS"
ls -lh passt

# 验收：两个安全域都要 rc=0
#   Termux/app 域  Seccomp:2  ->  ./passt --version 必须 rc=0（不是 159）
#   adb shell 域   Seccomp:0  ->  同上
echo "== 自检 =="
./passt --version >/dev/null 2>&1 && echo "local rc=$?" || echo "local FAILED rc=$?"
