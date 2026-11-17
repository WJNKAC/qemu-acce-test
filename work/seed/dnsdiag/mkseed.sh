#!/bin/bash
# mkseed.sh —— 打 DNS 三层诊断的 seed ISO 并推到设备。在宿主机上跑。
#
# instance-id 每次唯一：cloud-init 的 runcmd 是 per-instance 语义，
# 同一个 id 第二次出现会被整段跳过（/var/lib/cloud/instances/<id> 有记录）。
# 这里虽然每次都从 deb12-clean.qcow2 干净副本起，但唯一性不花钱，别省。
set -euo pipefail
cd "$(dirname "$0")"

TS=$(date +%s)
cat > meta-data <<EOF
instance-id: deb12-dns-$TS
local-hostname: deb12
EOF

[ -f user-data ] || { echo "MISSING user-data"; exit 3; }
command -v genisoimage >/dev/null || { echo "MISSING genisoimage"; exit 3; }

rm -f seed-dns.iso
genisoimage -quiet -output seed-dns.iso -volid cidata -joliet -rock user-data meta-data

# 写后验证：把 user-data / meta-data 从 ISO 里抽回来逐字节比对。
# 上一版这里是 grep 固定串（'DNSDIAG-VERDICT'），改版把那个串换成
# `DNSDIAG-$PHASE-VERDICT` 之后它立刻误报 —— 判据自己会过期。
# 逐字节 diff 不会过期。
command -v 7z >/dev/null || { echo "MISSING 7z（要它来抽 ISO 做比对）"; exit 3; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
7z x -o"$TMP" -y seed-dns.iso user-data meta-data >/dev/null 2>&1 || {
    echo "FAIL: 解不开 ISO"; exit 4; }
diff -q "$TMP/user-data" user-data >/dev/null || { echo "FAIL: ISO 里的 user-data 与源文件不一致"; exit 4; }
diff -q "$TMP/meta-data" meta-data >/dev/null || { echo "FAIL: ISO 里的 meta-data 与源文件不一致"; exit 4; }
echo "ISO 内容验证：user-data / meta-data 逐字节一致（$(wc -c <user-data) B）"

MD5=$(md5sum seed-dns.iso | cut -d' ' -f1)
SZ=$(stat -c %s seed-dns.iso)
echo "seed-dns.iso  md5=$MD5  size=$SZ  instance-id=deb12-dns-$TS"

DEV=${DEV:-3538956564001EV}
if [ "${PUSH:-1}" = 1 ]; then
    adb -s "$DEV" push seed-dns.iso /data/local/tmp/seed-dns.iso >/dev/null
    RMD5=$(adb -s "$DEV" shell md5sum /data/local/tmp/seed-dns.iso | tr -d '\r' | cut -d' ' -f1)
    echo "pushed -> /data/local/tmp/seed-dns.iso  device-md5=$RMD5"
    [ "$RMD5" = "$MD5" ] || { echo "FAIL: 设备侧 md5 不一致（传输截断？）"; exit 5; }
    echo "md5 一致"
fi
