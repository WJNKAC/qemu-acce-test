#!/bin/bash
# a3pair.sh <its on|off> <prefix> —— 一个病人的 off/auth 两次跑（手机侧，同步）
set -u
cd "$HOME/qa" || exit 1
Q=/data/data/com.termux/files/usr/share/qemu
its=$1
pfx=$2
TO=${A3_TIMEOUT:-90}

one() { # one <name> <authority 0|1>
    local name=$1 auth=$2
    cp -f bios/vars.base a3-vars.img
    rm -f "$name.serial" "$name.log"
    local t0=$(date +%s)
    if [ "$auth" = 1 ]; then
        HENGE_GIC_AUTHORITY=1 timeout -s TERM -k 5 "$TO" ./bin/q-henge \
            -L "$Q" -M "virt,gic-version=3,its=$its" -cpu max -m 2048 -smp 2 \
            -drive if=pflash,format=raw,unit=0,file=bios/edk2-aarch64-code.fd,readonly=on \
            -drive if=pflash,format=raw,unit=1,file=a3-vars.img \
            -drive if=none,id=d0,format=qcow2,file=images/ovl-henge.qcow2 \
            -device virtio-blk-pci,drive=d0 \
            -nic user,model=virtio-net-pci \
            -display none -serial file:"$name.serial" -monitor none -accel henge \
            >/dev/null 2>"$name.log"
    else
        timeout -s TERM -k 5 "$TO" ./bin/q-henge \
            -L "$Q" -M "virt,gic-version=3,its=$its" -cpu max -m 2048 -smp 2 \
            -drive if=pflash,format=raw,unit=0,file=bios/edk2-aarch64-code.fd,readonly=on \
            -drive if=pflash,format=raw,unit=1,file=a3-vars.img \
            -drive if=none,id=d0,format=qcow2,file=images/ovl-henge.qcow2 \
            -device virtio-blk-pci,drive=d0 \
            -nic user,model=virtio-net-pci \
            -display none -serial file:"$name.serial" -monitor none -accel henge \
            >/dev/null 2>"$name.log"
    fi
    local rc=$? t1=$(date +%s)
    local ts=$(sed -n "s/^\[ *\([0-9]*\.[0-9]*\)\].*/\1/p" "$name.serial" 2>/dev/null | tail -1)
    local gdm=$(tr -d "\r" < "$name.serial" 2>/dev/null | grep -ac "gdm.service")
    local panic=$(grep -ac "Kernel panic\|Oops\|Internal error\|rcu.*stall" "$name.serial" 2>/dev/null)
    local lines=$(wc -l < "$name.serial" 2>/dev/null)
    echo "A3 $name its=$its auth=$auth wall=$((t1-t0))s rc=$rc last_ts=${ts:-none} gdm=$gdm panic=$panic lines=$lines"
}

one "${pfx}-off"  0
one "${pfx}-auth" 1
