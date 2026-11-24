#!/bin/bash
# henge-lifecycle: 四条生命周期校验（reset / 停靠 / 迁移拒绝 / 系统寄存器转发）
#
# 每条都对应一个"不挡就会在负载下静默出错"的洞：
#   1  -smp 4        次级 vCPU 必须停靠；若停靠失效，4 个线程会带陈旧 PC 进引擎
#   2  system_reset  引擎必须丢块/TLB/whint；否则第二次启动跑的是第一次的翻译
#   3  migrate       必须拒绝；否则产出"看起来正常的坏快照"
#   4  ICC_* sysreg  必须转给 QEMU 的 cp_regs；引擎自己的 icc_read 是 NULL 时
#                    它会静默返回 0，比 UNDEF 更坏
set -eu

CT=/data/用户/应用/操作系统/虚拟化/容器/Devuan/excalibur/apm-test/overlay/manual-build-qemu
PW=${SUDO_PW:-laptop}
SRCDIR=$(cd "$(dirname "$0")/probe" && pwd)

as_root() { echo "$PW" | sudo -S -p '' "$@"; }
in_ct() { echo "$PW" | sudo -S -p '' "$CT/tool/rurima" r -S -k cap_sys_admin "$CT/overlay" /bin/sh "$@"; }

as_root mkdir -p "$CT/overlay/work/probe"
as_root cp "$SRCDIR/probe.S" "$SRCDIR/sysreg.S" "$SRCDIR/idreg.S" \
            "$SRCDIR/timer.S" "$SRCDIR/timerirq.S" "$SRCDIR/smp.S" \
            "$SRCDIR/smc.S" "$SRCDIR/probe.ld" "$CT/overlay/work/probe/"

RUN=$(mktemp)
cat > "$RUN" <<'EOS'
set -e
cd /work/probe
for p in probe sysreg idreg timer timerirq smp smc; do
    aarch64-linux-gnu-gcc -nostdlib -nostartfiles -T probe.ld -o $p.elf $p.S 2>/dev/null
done
cd /src/qemu-henge
export QEMU_LD_PREFIX=/usr/aarch64-linux-gnu
Q=./build/qemu-system-aarch64
V="-M virt -cpu cortex-a57 -m 256 -nographic"

cat > /tmp/qmp.py <<'PY'
import json, socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(60):
    try: s.connect(sys.argv[1]); break
    except OSError: time.sleep(0.2)
f = s.makefile('rwb'); f.readline()
f.write(b'{"execute":"qmp_capabilities"}\n'); f.flush(); time.sleep(0.3)
for c in sys.argv[2:]:
    f.write((c + "\n").encode()); f.flush(); time.sleep(1.0)
PY

echo "=== 1) -smp 4：次级必须停靠 ==="
timeout 10 qemu-aarch64 $Q $V -smp 4 -accel henge -kernel /work/probe/probe.elf 2>&1 | head -4

echo ""
echo "=== 2) system_reset：reset 钩子 + 二次启动 ==="
rm -f /tmp/q.sock
HENGE_DEBUG_RAM=1 timeout 15 qemu-aarch64 $Q $V -smp 1 -accel henge \
    -kernel /work/probe/probe.elf -qmp unix:/tmp/q.sock,server=on,wait=off > /tmp/r.log 2>&1 &
P=$!; sleep 3
python3 /tmp/qmp.py /tmp/q.sock '{"execute":"system_reset"}'
sleep 4; kill $P 2>/dev/null || true; wait $P 2>/dev/null || true
grep -E "reset, re-mirrored|HENGE-MMIO-OK" /tmp/r.log | head -6
echo "--- region 列表：启动 vs reset 后必须一致（防 2-vs-1 复发）---"
# 启动那次镜像与 reset 后那次镜像的 region 名称集合必须相同。数量不同说明
# 有一次镜像看到了半个 flatview —— 曾经是 2 个（1 真 + 1 个 size=0 的死项）。
awk '/region /{print $3, $4, $5}' /tmp/r.log > /tmp/regions.txt
sort /tmp/regions.txt | uniq -c | awk '$1 != 2 {print "MISMATCH:", $0}' | head -5
echo "region 行数: $(wc -l < /tmp/regions.txt)（应为偶数，即每次镜像相同）"

echo ""
echo "=== 3) migrate：必须被拒绝 ==="
rm -f /tmp/q2.sock
timeout 15 qemu-aarch64 $Q $V -smp 1 -accel henge \
    -kernel /work/probe/probe.elf -qmp unix:/tmp/q2.sock,server=on,wait=off > /tmp/m.log 2>&1 &
P=$!; sleep 3
python3 /tmp/qmp.py /tmp/q2.sock '{"execute":"migrate","arguments":{"uri":"exec:cat>/dev/null"}}'
sleep 2; kill $P 2>/dev/null || true; wait $P 2>/dev/null || true
grep -iE "migration is not supported" /tmp/m.log | head -2

echo ""
echo "=== 4) ICC_* 系统寄存器转发（GICv3）==="
timeout 10 qemu-aarch64 $Q -M virt,gic-version=3 -cpu cortex-a57 \
    -m 256 -smp 1 -nographic -accel henge -kernel /work/probe/sysreg.elf 2>&1 | head -4
echo "--- tcg 对照 ---"
timeout 10 qemu-aarch64 $Q -M virt,gic-version=3 -cpu cortex-a57 \
    -m 256 -smp 1 -nographic -accel tcg -kernel /work/probe/sysreg.elf 2>&1 | head -3

echo ""
echo "=== 5) ID 组三型（CONST / CONST / fieldoffset）==="
timeout 10 qemu-aarch64 $Q -M virt -cpu cortex-a57 \
    -m 256 -smp 1 -nographic -accel henge -kernel /work/probe/idreg.elf 2>&1 | head -8
echo "--- tcg 对照 ---"
timeout 10 qemu-aarch64 $Q -M virt -cpu cortex-a57 \
    -m 256 -smp 1 -nographic -accel tcg -kernel /work/probe/idreg.elf 2>&1 | head -8

echo ""
echo "=== 6) timer 闭环：CVAL 到期 -> gtimer IRQ -> 引擎异常（#2 + #3）==="
timeout 15 qemu-aarch64 $Q -M virt,gic-version=3 -cpu cortex-a57 \
    -m 256 -smp 1 -nographic -accel henge -kernel /work/probe/timerirq.elf 2>&1 | head -8
echo "--- tcg 对照 ---"
timeout 15 qemu-aarch64 $Q -M virt,gic-version=3 -cpu cortex-a57 \
    -m 256 -smp 1 -nographic -accel tcg -kernel /work/probe/timerirq.elf 2>&1 | head -6

echo ""
echo "=== 7) SMP：CPU_ON 经 QEMU 的 psci.c，context_id 必须传到 secondary ==="
timeout 15 qemu-aarch64 $Q -M virt -cpu cortex-a57 \
    -m 256 -smp 2 -nographic -accel henge -kernel /work/probe/smp.elf 2>&1 | grep -E "CPU_ON-RET|CPU1-CONTEXT|CPU1-DONE" | head -5
echo "--- tcg 对照 ---"
timeout 15 qemu-aarch64 $Q -M virt -cpu cortex-a57 \
    -m 256 -smp 2 -nographic -accel tcg -kernel /work/probe/smp.elf 2>&1 | grep -E "CPU_ON-RET|CPU1-CONTEXT|CPU1-DONE" | head -5

echo ""
echo "=== 8) SMC：改代码页后必须执行新指令（DMA 钩子复用同一张位图）==="
timeout 10 qemu-aarch64 $Q -M virt -cpu cortex-a57 \
    -m 256 -smp 1 -nographic -accel henge -kernel /work/probe/smc.elf 2>&1 | grep -E "FIRST|SECOND" | head -3
EOS

as_root cp "$RUN" "$CT/overlay/tmp/henge-life.sh"
rm -f "$RUN"
in_ct /tmp/henge-life.sh
