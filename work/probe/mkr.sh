#!/bin/sh
#
# mkr.sh - 在本地生成三个 qcow2 overlay 并推到设备。每轮只用几 KB。
#
# 为什么不再 cp：
#   deb12.qcow2 340MB + vars0.img 64MB + seed.iso 366KB ≈ 405MB。
#   通过 SSH 传要几十秒，而我的会话超时是 60s，于是经常传一半被打断，
#   结果是没有日志文件——现象看起来却像"QEMU 起不来"。
#   overlay 让 backing 保持只读、写全落在几 KB 的叠加层上，
#   既消除整类超时，又顺手满足"每轮全新"的测量卫生。
#
# 用法：./mkr.sh <tag>
set -eu

HOST=${HOST:-union@192.168.1.9}
PORT=${PORT:-8022}
HPASS=${HPASS:-a72}
DEV_H=${DEV_H:-/data/data/com.termux/files/home/h}
TAG=${1:?usage: mkr.sh <tag>}

D=$(cd "$(dirname "$0")" && pwd)
ASK=$D/../../../../WorkBuddy/2026-11-14-22-13-50/work/askpass.sh
[ -x "$ASK" ] || ASK=/home/laptop/WorkBuddy-CN/WorkBuddy/2026-11-14-22-13-50/work/askpass.sh
[ -x "$ASK" ] || { echo "askpass not found" >&2; exit 1; }

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# 只对 deb12.qcow2 做 overlay：它是 340MB 的大头，也是"每轮全新"最需要的东西。
#
# vars/seed 不做 overlay，理由是一条实测过的坑：
#   -drive if=pflash,...,format=raw 对 vars 是对的（vars0.img 是 raw），
#   而 overlay 是 qcow2。一旦把 vars 也换成 overlay 却仍写 format=raw，
#   QEMU 就把 qcow2 文件按 raw 读，长度=文件物理大小 197120，于是
#       cfi.pflash01 requires 67108864 bytes, backend provides 197120 bytes
#   —— 整个 UEFI 起不来。同理 seed。
#   而 vars(64MB)+seed(366KB) 的 cp 只要 1 秒，不值得为它引入新的格式语义。
#
# -u 让 qemu-img 不必读到 backing（它在设备上），必须显式给虚拟大小：
# 3G 是 deb12.qcow2 的真实 virtual size，已核对。
qemu-img create -q -u -f qcow2 -b "$DEV_H/deb12.qcow2" -F qcow2 "$OUT/r-$TAG.qcow2" 3G

S() {
    SSH_TEST_PW=$HPASS SSH_ASKPASS=$ASK SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
    setsid -w timeout 60 ssh -F /dev/null -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
        -p "$PORT" "$HOST" "$1" 2>/dev/null
}

# 三个小文件一次打包推过去，省来回
tar -C "$OUT" -cf - . 2>/dev/null | \
    SSH_TEST_PW=$HPASS SSH_ASKPASS=$ASK SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
    setsid -w timeout 60 ssh -F /dev/null -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=1 \
        -p "$PORT" "$HOST" "cd $DEV_H && tar -xf -"

S "cd $DEV_H && rm -f r-$TAG.img r-$TAG.iso && cp vars0.img r-$TAG.img && cp seed-net4.iso r-$TAG.iso && ls -l r-$TAG.qcow2 r-$TAG.img r-$TAG.iso"
echo "overlays for $TAG ready"
