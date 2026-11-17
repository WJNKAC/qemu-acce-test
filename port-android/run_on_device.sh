#!/bin/bash
# 把 hv-linux + 内核推到设备上跑。用法：./run_on_device.sh [hv-linux 参数...]
set -e
H=$(cd "$(dirname "$0")" && pwd)
. "$H/config.sh"
K=$CACHE/linux-6.12/arch/arm64/boot/Image
DEV=${DEV:-/data/local/tmp}

adbd push "$H/build/hv-linux" "$DEV/hv-linux" >/dev/null
adbd push "$K" "$DEV/Image" >/dev/null
adbd shell "chmod 755 $DEV/hv-linux"
exec adbd shell "$DEV/hv-linux --kernel $DEV/Image $*"
