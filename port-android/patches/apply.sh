#!/bin/sh
# apply.sh - 把移植层补丁打到 qemu submodule 上。
#
# 为什么不把改动直接提交进 submodule：
#   submodule 指向的是干净的 upstream commit（v11.1.3）。移植层是自己的东西，
#   放进 patch 才有三个能力 —— 可 review（14223 行改动一眼看完）、
#   可 rebase（换 qemu 版本时 git apply --3way）、可计数（改了多少行是硬数字）。
#
# 两个补丁目标（13.54 起）：
#   0001-henge-port.patch       -> src/qemu-henge                （qemu 主仓）
#   0002-libslirp-dns-env.patch -> src/qemu-henge/subprojects/slirp
#
# 为什么 libslirp 要单独一个文件：subprojects/slirp 是**独立 git 仓库**
# （subprojects/slirp.wrap 指向 libslirp.git，qemu 主仓不跟踪它的内容），
# 0001 在 qemu 主仓里根本看不到那些文件。
#
# 用法:
#   ./apply.sh           打补丁
#   ./apply.sh --check   只检查能不能打（不动文件）
#   ./apply.sh --revert  撤回补丁
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
QEMU=$ROOT/src/qemu-henge
SLIRP=$QEMU/subprojects/slirp
P1=$HERE/0001-henge-port.patch
P2=$HERE/0002-libslirp-dns-env.patch

MODE=${1:-apply}
case "$MODE" in
    apply|--check|--revert) ;;
    *) echo "apply: 未知参数 $MODE（--check | --revert | 空）" >&2; exit 2 ;;
esac

# one <仓库目录> <补丁> <短名> <基线 commit>
one() {
    dir=$1; patch=$2; label=$3; want=$4
    [ -d "$dir/.git" ] || {
        echo "apply: 没有 $dir/.git" >&2
        echo "       先跑: git submodule update --init --depth 1 src/qemu-henge" >&2
        exit 1
    }
    [ -f "$patch" ] || { echo "apply: 缺 $patch" >&2; exit 1; }

    # 基线校验：所有数据都是对着这个版本取的，换了版本必须重跑基线而不是默默打补丁。
    have=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo none)
    if [ "$have" != "$want" ]; then
        echo "apply[$label]: HEAD 是 ${have%"${have#????????????}"}，补丁基线是 ${want%"${want#????????????}"}" >&2
        echo "       要么 checkout 回基线，要么先重跑基线测量再 rebase 补丁。" >&2
        echo "       强制继续: ALLOW_BASE_MISMATCH=1 ./apply.sh" >&2
        [ "${ALLOW_BASE_MISMATCH:-0}" = "1" ] || exit 1
    fi

    case "$MODE" in
    --check)
        # 反向能打 = 当前已经是打过补丁的状态
        if git -C "$dir" apply --check --reverse "$patch" 2>/dev/null; then
            echo "[$label] 已应用（patch 与工作区一致）"
        elif git -C "$dir" apply --check "$patch" 2>/dev/null; then
            echo "[$label] 未应用，可以打"
        else
            echo "[$label] 既不能正向也不能反向应用 —— 工作区有别的改动，先处理" >&2
            git -C "$dir" apply --check "$patch" 2>&1 | head -5 >&2
            exit 1
        fi
        ;;
    --revert)
        git -C "$dir" apply --reverse "$patch"
        echo "[$label] 已撤回（回到干净上游）"
        ;;
    apply)
        if git -C "$dir" apply --check --reverse "$patch" 2>/dev/null; then
            echo "[$label] 已经打过了，跳过"
            return 0
        fi
        git -C "$dir" apply "$patch"
        echo "[$label] 已应用: $(grep -c '^diff --git' "$patch") 个文件"
        ;;
    esac
}

one "$QEMU"  "$P1" henge-port    005c61c0ef6f6ae615283440b4bb7be51b2c6ddd
one "$SLIRP" "$P2" libslirp-dns  26be815b86e8d49add8c9a8b320239b9594ff03d

if [ "$MODE" = --revert ]; then
    # 新增的空目录 git apply 不会删，手工收尾
    rmdir "$QEMU/accel/henge/engine/compat/mach" 2>/dev/null || true
    rmdir "$QEMU/accel/henge/engine/compat/libkern" 2>/dev/null || true
fi

if [ "$MODE" = apply ]; then
    echo "下一步: ninja -C src/qemu-henge/build qemu-system-aarch64"
fi
exit 0
