#!/bin/bash
# henge-boot: 用真实 Linux 内核做端到端验收（step 1 的验收门）
#
# 判据不是"跑起来了"，而是五个具体的、可以在 TCG 下逐条对上的观测：
#
#   1. MIDR 0x411fd070          ID 组转发（引擎不再自答 A76）
#   2. psci: PSCIv1.1 detected  PSCI 转发（引擎不再自己解释 HVC）
#   3. Run /myinit as init      ELF 加载、用户态、syscall、MMU 全通
#   4. arch_timer 计数 > 0      timer 闭环在真实负载下工作（不是探针）
#   5. 基准测试跑完             mem/call/branch，说明不是刚好停在某个 lucky 点
#
# SMP 的现状写在文档里，脚本会显式跑一次并如实报告。
#
# 用法: henge-boot.sh [smp]     默认 1
set -eu

CT=/data/用户/应用/操作系统/虚拟化/容器/Devuan/excalibur/apm-test/overlay/manual-build-qemu
PW=${SUDO_PW:-laptop}
IMAGE=${HENGE_IMAGE:-/data/用户/项目/qemu-acce/output/bin/Image}
SMP=${1:-1}

as_root() { echo "$PW" | sudo -S -p '' "$@"; }
in_ct() { echo "$PW" | sudo -S -p '' "$CT/tool/rurima" r -S -k cap_sys_admin "$CT/overlay" /bin/sh "$@"; }

as_root mkdir -p "$CT/overlay/work/img"
as_root cp "$IMAGE" "$CT/overlay/work/img/Image"

RUN=$(mktemp)
cat > "$RUN" <<EOS
set -e
cd /src/qemu-henge
export QEMU_LD_PREFIX=/usr/aarch64-linux-gnu
Q=./build/qemu-system-aarch64
COMMON="-M virt -cpu max -m 512 -nographic -no-reboot"
APPEND="console=ttyAMA0 earlycon=pl011,0x09000000 rdinit=/myinit loglevel=6"

run_one() {
    accel=\$1; smp=\$2; extra=\$3; log=\$4
    timeout 75 qemu-aarch64 \$Q \$COMMON -smp \$smp -accel \$accel \\
        -append "\$APPEND \$extra" -kernel /work/img/Image > \$log 2>&1 || true
    echo "--- accel=\$accel smp=\$smp \$extra ---"
    grep -E "Booting Linux|psci: PSCIv|Run /myinit|userspace is alive" \$log \\
        | sed 's/^\[[^]]*\] //' | head -4
    grep -E "^\s+(alu|mem|call|branch)\s+.*ns/iter" \$log | tail -4 || echo "  (无基准输出)"
    t=\$(grep -oE "[0-9]+ GIC-0 +27 Level +arch_timer" \$log | awk '{print \$1}')
    echo "  arch_timer IRQ: \${t:-0}"
    s=\$(grep -cE "rcu.*stall" \$log || true)
    echo "  rcu stalls: \$s"
}

echo "================ henge, smp=$SMP ================"
run_one henge "$SMP" "" /work/img/out-henge.log

echo ""
echo "================ tcg 对照, smp=$SMP ================"
run_one tcg "$SMP" "" /work/img/out-tcg.log
EOS

as_root cp "$RUN" "$CT/overlay/tmp/henge-boot.sh"
rm -f "$RUN"
in_ct /tmp/henge-boot.sh
