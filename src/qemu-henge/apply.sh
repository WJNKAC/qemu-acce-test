#!/bin/sh
# apply.sh [--force] —— 从 qemu/（-> ../qemu 上游子模块）+ patches/ 生成 work/src
#
# 为什么不在 qemu/ 里原地打补丁：
#   qemu/ 是**干净的上游检出**，它的 HEAD 必须始终是钉住的 v11.1.3；原地打补丁
#   会让它永久变脏，`git submodule update` 一次就把改动冲掉。work/src 是可丢弃
#   的派生树，apply.sh 幂等重建；patch 序列的哈希存在 work/.patch-hash，
#   没变就跳过（增量编译不会因为重新 cp 而全量重编，cp -a 保留 mtime）。
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$HERE/qemu
WORK=$HERE/work/src
PIN=005c61c0ef6f6ae615283440b4bb7be51b2c6ddd   # upstream v11.1.3

# 子模块的 .git 是 gitfile（指向 ../../.git/modules/src/qemu），不是目录；
# 用 git 自己判断，别用 -d 探测。
git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "apply: 缺少上游子模块 src/qemu（git submodule update --init src/qemu；qemu/ 是软链接）" >&2
    exit 1
}
rev=$(git -C "$SRC" rev-parse HEAD)
[ "$rev" = "$PIN" ] || {
    echo "apply: qemu/ 在 $rev，不是钉住的 v11.1.3（$PIN）" >&2
    exit 1
}

HASH=$(cat "$HERE"/patches/*.patch | sha256sum | cut -c1-16)
if [ "${1:-}" != "--force" ] && [ -d "$WORK" ] && [ -f "$HERE/work/.patch-hash" ] &&
   [ "$(cat "$HERE/work/.patch-hash")" = "$HASH" ]; then
    echo "apply: patches 未变（$HASH），复用 work/src"
    exit 0
fi

# 关键：$HERE/qemu 是软链接（-> ../qemu），cp -a 会把**软链接本身**拷成 work/src，
# 下一行 rm -rf work/src/.git 就会顺着软链接删掉上游子模块的 .git（真踩过）。
# 所以先 readlink -f 解析，再按“目录内容”拷贝。
REAL=$(readlink -f "$SRC")
rm -rf "$WORK"
mkdir -p "$WORK"
cp -a "$REAL/." "$WORK/"
rm -rf "$WORK/.git"

# 0001..0003 打在 qemu 根；0004 打在 subprojects/slirp 里（它的路径前缀
# 是 a/src/slirp.c，相对 slirp 子项目根，不是 qemu 根）。
cd "$WORK"
for p in "$HERE"/patches/000[123]-*.patch; do
    echo "apply: $(basename "$p")"
    patch -p1 --batch --forward < "$p" >/dev/null || {
        echo "apply: FAILED $(basename "$p")" >&2
        exit 1
    }
done
echo "apply: 0004-libslirp-dns-env.patch（在 subprojects/slirp）"
(cd "$WORK/subprojects/slirp" && patch -p1 --batch --forward < "$HERE/patches/0004-libslirp-dns-env.patch" >/dev/null) || {
    echo "apply: FAILED 0004-libslirp-dns-env.patch" >&2
    exit 1
}
printf '%s\n' "$HASH" > "$HERE/work/.patch-hash"
echo "apply: work/src 就绪（patch series $HASH）"
