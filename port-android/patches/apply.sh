#!/bin/sh
# apply.sh - 把移植层补丁打到 qemu submodule 上。
#
# 为什么不把改动直接提交进 submodule：
#   submodule 指向的是干净的 upstream commit（v11.1.3）。移植层是自己的东西，
#   放进 patch 才有三个能力 —— 可 review（14223 行改动一眼看完）、
#   可 rebase（换 qemu 版本时 git apply --3way）、可计数（改了多少行是硬数字）。
#
# 用法:
#   ./apply.sh           打补丁
#   ./apply.sh --check   只检查能不能打（不动文件）
#   ./apply.sh --revert  撤回补丁
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
QEMU=$ROOT/src/qemu-mainline
PATCH=$HERE/0001-henge-port.patch

MODE=${1:-apply}

[ -d "$QEMU/.git" ] || {
    echo "apply: 没有 $QEMU/.git" >&2
    echo "       先跑: git submodule update --init --depth 1 src/qemu-mainline" >&2
    exit 1
}
[ -f "$PATCH" ] || { echo "apply: 缺 $PATCH" >&2; exit 1; }

cd "$QEMU"

# 基线校验：所有数据都是对着这个版本取的，换了版本必须重跑基线而不是默默打补丁。
WANT=005c61c0ef6f6ae615283440b4bb7be51b2c6ddd
HAVE=$(git rev-parse HEAD 2>/dev/null)
if [ "$HAVE" != "$WANT" ]; then
    echo "apply: qemu HEAD 是 ${HAVE%"${HAVE#????????????}"}，补丁基线是 ${WANT%"${WANT#????????????}"}" >&2
    echo "       要么 checkout 回基线，要么先重跑基线测量再 rebase 补丁。" >&2
    echo "       强制继续: ALLOW_BASE_MISMATCH=1 ./apply.sh" >&2
    [ "${ALLOW_BASE_MISMATCH:-0}" = "1" ] || exit 1
fi

case "$MODE" in
--check)
    # 反向能打 = 当前已经是打过补丁的状态
    if git apply --check --reverse "$PATCH" 2>/dev/null; then
        echo "已应用（patch 与工作区一致）"
    elif git apply --check "$PATCH" 2>/dev/null; then
        echo "未应用，可以打"
    else
        echo "既不能正向也不能反向应用 —— 工作区有别的改动，先处理" >&2
        git apply --check "$PATCH" 2>&1 | head -5 >&2
        exit 1
    fi
    ;;
--revert)
    git apply --reverse "$PATCH"
    echo "已撤回移植层（qemu 回到干净 v11.1.3）"
    # 新增的空目录 git apply 不会删，手工收尾
    rmdir "$QEMU/accel/henge/engine/compat/mach" 2>/dev/null || true
    rmdir "$QEMU/accel/henge/engine/compat/libkern" 2>/dev/null || true
    ;;
apply)
    if git apply --check --reverse "$PATCH" 2>/dev/null; then
        echo "已经打过了，跳过"
        exit 0
    fi
    git apply "$PATCH"
    echo "移植层已应用: $(grep -c '^diff --git' "$PATCH") 个文件"
    echo "下一步: ninja -C build qemu-system-aarch64"
    ;;
*)
    echo "apply: 未知参数 $MODE（--check | --revert | 空）" >&2
    exit 2
    ;;
esac
