#!/bin/bash
# corpus.sh —— Phase B：病人语料回放（手机侧），给 pass/fail 而不是"跑一下看看"
#
# 语料（预注册，与 STATE 的 A3/A5 同一批判据）：
#   v3-auth-smp1    authority + -kernel Image + initramfs，1 vCPU
#   v3-auth-smp2    authority，2 vCPU（CPU_ON 链）
#   v3-off-smp1     非权威基线
#   v3-shadow-smp1  影子模式（常驻诊断：引擎 GIC 对 QEMU 活 GIC 的 diff）
#   uefi-intx-auth  edk2 + Debian 根盘，its=off（INTx），到 gdm
#   uefi-its-auth   同上，its=on（设备 MSI/LPI），到 gdm
#
# 用法: ./corpus.sh [-q]        -q: UEFI 病人只跑 100 s（默认 120 s）
# 注：time-to-GDM 实测 69–83 s（smp2/smp4），超时必须留余量，否则会把"慢"判成"挂"。
# 退出码 = 失败的检查数（0 = 全过）。产物 corpus-<name>.serial/.log 留在 ~/qa。
set -u
cd "$HOME/qa" || exit 1
Q=/data/data/com.termux/files/usr/share/qemu
UEFI_SECS=120
[ "${1:-}" = "-q" ] && UEFI_SECS=100
V3_SECS=20
FAILS=0

chk() { # chk <name> <desc> <cmd...>
    local name=$1 desc=$2; shift 2
    if "$@"; then
        echo "PASS $name: $desc"
    else
        echo "FAIL $name: $desc"
        FAILS=$((FAILS + 1))
    fi
}

v3() { # v3 <name> <smp> [env...]
    local name=$1 smp=$2; shift 2
    rm -f "corpus-$name.serial" "corpus-$name.log"
    env "$@" timeout -s TERM -k 5 "$V3_SECS" ./bin/q-henge -L "$Q" \
        -M virt,gic-version=3,its=off -cpu max -m 1024 -smp "$smp" \
        -kernel images/Image -append "console=ttyAMA0 rdinit=/myinit loglevel=7" \
        -no-reboot -display none -monitor none \
        -serial file:"corpus-$name.serial" -accel henge >/dev/null 2>"corpus-$name.log"
    echo $?
}

uefi() { # uefi <name> <its> [env...]
    local name=$1 its=$2; shift 2
    cp -f bios/vars.base corpus-vars.img
    rm -f "corpus-$name.serial" "corpus-$name.log"
    env "$@" timeout -s TERM -k 5 "$UEFI_SECS" ./bin/q-henge -L "$Q" \
        -M "virt,gic-version=3,its=$its" -cpu max -m 2048 -smp 2 \
        -drive if=pflash,format=raw,unit=0,file=bios/edk2-aarch64-code.fd,readonly=on \
        -drive if=pflash,format=raw,unit=1,file=corpus-vars.img \
        -drive if=none,id=d0,format=qcow2,file=images/ovl-henge.qcow2 \
        -device virtio-blk-pci,drive=d0 -nic user,model=virtio-net-pci \
        -display none -serial file:"corpus-$name.serial" -monitor none -accel henge \
        >/dev/null 2>"corpus-$name.log"
    echo $?
}

no_panic() { ! grep -aq "Kernel panic\|Internal error\|Oops\|rcu.*stall" "corpus-$1.serial"; }
has() { grep -aq -- "$2" "corpus-$1.serial"; }
loghas() { grep -aq -- "$2" "corpus-$1.log"; }
rc0() { [ "$1" = 0 ]; }
shadow_clean() {
    # 影子 diff 必须无 mismatch、无 bad settle、无 unexplained
    ! grep -aqE "mismatch=[1-9]|bad=[1-9]|settle=[0-9]+/[1-9]|unexplained=[1-9]" "corpus-$1.log"
}

echo "== corpus: v3-auth-smp1"
r=$(v3 v3-auth-smp1 1 HENGE_GIC_AUTHORITY=1)
chk v3-auth-smp1 "exit 0 (/myinit + power down)" rc0 "$r"
chk v3-auth-smp1 "myinit ran" has v3-auth-smp1 "myinit"
chk v3-auth-smp1 "no panic" no_panic v3-auth-smp1

echo "== corpus: v3-auth-smp2"
r=$(v3 v3-auth-smp2 2 HENGE_GIC_AUTHORITY=1)
chk v3-auth-smp2 "CPU1 booted" has v3-auth-smp2 "Booted secondary"
chk v3-auth-smp2 "2 CPUs online" has v3-auth-smp2 "Brought up 1 node, 2 CPUs"
chk v3-auth-smp2 "no panic" no_panic v3-auth-smp2

echo "== corpus: v3-off-smp1"
r=$(v3 v3-off-smp1 1 X=1)
chk v3-off-smp1 "exit 0" rc0 "$r"
chk v3-off-smp1 "myinit ran" has v3-off-smp1 "myinit"

echo "== corpus: v3-shadow-smp1"
r=$(v3 v3-shadow-smp1 1 HENGE_GIC_SHADOW=1)
chk v3-shadow-smp1 "exit 0" rc0 "$r"
chk v3-shadow-smp1 "myinit ran" has v3-shadow-smp1 "myinit"
chk v3-shadow-smp1 "shadow engine online" loghas v3-shadow-smp1 "engine GIC online"
chk v3-shadow-smp1 "shadow diff mismatch=0" loghas v3-shadow-smp1 "mismatch=0"
chk v3-shadow-smp1 "shadow diff clean (bad/unexplained=0)" shadow_clean v3-shadow-smp1

echo "== corpus: uefi-intx-auth"
r=$(uefi uefi-intx-auth off HENGE_GIC_AUTHORITY=1)
chk uefi-intx-auth "gdm started" has uefi-intx-auth "gdm.service"
chk uefi-intx-auth "no panic" no_panic uefi-intx-auth

echo "== corpus: uefi-its-auth"
r=$(uefi uefi-its-auth on HENGE_GIC_AUTHORITY=1 X=1)
chk uefi-its-auth "gdm started" has uefi-its-auth "gdm.service"
chk uefi-its-auth "no panic" no_panic uefi-its-auth

echo "== CORPUS FAILURES: $FAILS"
exit "$FAILS"
