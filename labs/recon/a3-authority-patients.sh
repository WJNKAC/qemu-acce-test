#!/bin/bash
# a3-authority-patients.sh —— A3：UEFI 两病人的 authority 回归（手机侧）
#
# 病人（v3 病人已由 g1/g2/g3 覆盖：-kernel Image + initramfs，authority smp1/smp2 全通）：
#   UEFI-INTx its=off + virtio-net-pci（钉住 INTx）
#   UEFI-ITS  its=on  + virtio-net-pci（MSI→LPI，DESIGN 的未决范围旗标）
#
# 每个病人跑 off / authority 各一次，同一命令行，只差 HENGE_GIC_AUTHORITY。
# 判据（预注册，写在这里防止事后改口）：
#   * 不 panic：serial 里不得出现 "Kernel panic" / "Internal error" / "Oops"
#   * 里程碑不退：auth 跑的 last_ts 不低于 off 跑的大半，且两跑都过内核启动段
#   * ITS：its=on 与 its=off 的 panic 类不得不同（同崩溃可以，新崩溃不行）
#
# 用法（手机侧）：nohup ./scripts/a3-authority-patients.sh > a3.out 2>&1 &
set -u
cd "$HOME/qa" || exit 1
QEMU_DATA=/data/data/com.termux/files/usr/share/qemu
TIMEOUT=${A3_TIMEOUT:-90}

base() {
    echo "-L $QEMU_DATA -M virt,gic-version=3,its=$1 -cpu max -m 2048 -smp 2 \
      -drive if=pflash,format=raw,unit=0,file=bios/edk2-aarch64-code.fd,readonly=on \
      -drive if=pflash,format=raw,unit=1,file=a3-vars.img \
      -drive if=none,id=d0,format=qcow2,file=images/ovl-henge.qcow2 \
      -device virtio-blk-pci,drive=d0 \
      -nic user,model=virtio-net-pci"
}

run() { # run <name> <its> <authority 0|1>
    local name=$1 its=$2 auth=$3
    cp -f bios/vars.base a3-vars.img
    rm -f "$name.serial" "$name.log"
    local t0=$(date +%s)
    if [ "$auth" = 1 ]; then
        HENGE_GIC_AUTHORITY=1 timeout -s TERM -k 5 "$TIMEOUT" ./bin/q-henge -accel henge \
            $(base "$its") -display none -serial file:"$name.serial" -monitor none \
            >/dev/null 2>"$name.log"
    else
        timeout -s TERM -k 5 "$TIMEOUT" ./bin/q-henge -accel henge \
            $(base "$its") -display none -serial file:"$name.serial" -monitor none \
            >/dev/null 2>"$name.log"
    fi
    local rc=$? t1=$(date +%s)
    local ts=$(sed -n "s/^\[ *\([0-9]*\.[0-9]*\)\].*/\1/p" "$name.serial" 2>/dev/null | tail -1)
    local gdm=$(tr -d "\r" < "$name.serial" 2>/dev/null | grep -ac "gdm.service")
    local panic=$(grep -ac "Kernel panic\|Internal error\|Oops\|rcu.*stall" "$name.serial" 2>/dev/null)
    local lines=$(wc -l < "$name.serial" 2>/dev/null)
    echo "A3 $name its=$its auth=$auth wall=$((t1-t0))s rc=$rc last_ts=${ts:-none} gdm=$gdm panic=$panic lines=$lines"
}

run a3-intx-off       off 0
run a3-intx-auth      off 1
run a3-its-off        on  0
run a3-its-auth       on  1
echo A3-DONE
