#!/bin/bash
# build-android.sh —— 兼容入口。实体与参数说明见 src/qemu-henge/build.sh
#
# 仓库现在只放「上游子模块 + patch + 脚本」：
#   src/qemu-henge/qemu       子模块，钉在上游 v11.1.3（005c61c0ef）
#   src/qemu-henge/patches/   移植层
#   src/qemu-henge/apply.sh   qemu/ + patches/ -> work/src
#   src/qemu-henge/build.sh   唯一的构建脚本
#
# 用法不变：./build-android.sh [--fresh|--apply|--deps|--check]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
exec "$HERE/../src/qemu-henge/build.sh" "$@"
