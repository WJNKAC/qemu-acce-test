#!/bin/bash
# 把原项目的自测套件编到 Android 上跑：先证明"翻译器本身在这台设备上是对的"，
# 再去怀疑 Linux 客户机的特殊路径。
set -u
H=$(cd "$(dirname "$0")" && pwd)
. "$H/config.sh"          # 提供 NDK / CC_ANDROID / ROOT
CC=$CC_ANDROID
S=$ROOT/src/WindowsiOS
T=$H/build/tests
PATCH="python3 $H/tools/patch_macho_asm.py"
mkdir -p $T

INC="-I$T -I$H/compat -I$H/devs -I$S/core -I$S/host -I$S/devices -I$S/tests"

# core 变体：和被测引擎用同一套头，否则 sizeof(HvCpu) 对不上 → 段错误（踩过）
TLB_BITS=${TLB_BITS:-14}
PMD_BANK=${PMD_BANK:-0}
WHINT=${WHINT:-0}
BANK=${BANK:-0}
# 条件必须覆盖所有会改 HvCpu 布局的开关，否则测试按旧布局编译 → ABI 不一致 → 段错误
if [ "$TLB_BITS$PMD_BANK$WHINT$BANK" != "14000" ]; then
  TLB_BITS=$TLB_BITS PMD_BANK=$PMD_BANK WHINT=$WHINT BANK=$BANK python3 "$H/tools/patch_core.py" "$S/core" "$H/build/core" >/dev/null
  CORE_HDR="-include $H/build/core/cpu.h -include $H/build/core/machine.h"
  MMU_O="$H/build/core/mmu.c"
  [ -f "$H/build/mmu.o" ] || { echo "先 make TLB_BITS=$TLB_BITS PMD_BANK=$PMD_BANK WHINT=$WHINT BANK=$BANK" >&2; exit 1; }
else
  CORE_HDR=""
fi
CFLAGS="-include $H/compat/hv_posix_compat.h -std=c11 -O2 -g -w $INC -D_GNU_SOURCE $CORE_HDR"
ASFLAGS="-g -w -march=armv8.5-a+crypto+lse"

ENGINE="$H/build/classify.o $H/build/operands.o $H/build/translate.o $H/build/dispatch.o \
        $H/build/mmu.o $H/build/memop.o $H/build/exception.o $H/build/sysreg.o $H/build/machine.o \
        $H/build/jit_region_linux.o $H/build/plat_linux.o $H/build/enter_elf.o $H/build/fdt_linux.o \
        $H/build/gicv3.o $H/build/pcie.o $H/build/pl011.o $H/build/pl031.o $H/build/pl061.o \
        $H/build/timer.o $H/build/virtio.o $H/build/virtio_net.o $H/build/nvme.o $H/build/disk.o"

$PATCH $S/tests/harness.h $T/harness.h

asm() {
  local src=$1 out=$T/$(basename "${1%.S}").o
  $PATCH "$src" "$out.S" || return 1
  $CC $ASFLAGS -c "$out.S" -o "$out" || return 1
  echo "$out"
}

echo "== test_classify"
A=$(asm $S/tests/classify_cases.s) && \
  $CC $CFLAGS $S/tests/test_classify.c $H/build/classify.o $A -o $T/test_classify || echo "  FAILED"

echo "== test_operands"
B=$(asm $S/tests/operand_cases.s) && \
  $CC $CFLAGS $S/tests/test_operands.c $H/build/operands.o $B -o $T/test_operands || echo "  FAILED"

echo "== test_jit_region"
$CC $CFLAGS $S/tests/test_jit_region.c $H/build/jit_region_linux.o $H/build/plat_linux.o \
  -o $T/test_jit_region || echo "  FAILED"

HS=$(asm $S/tests/harness.S)
MEM_P=
for t in jit mem exc; do
  echo "== test_$t"
  P=$(asm $S/tests/${t}_programs.S)
  [ "$t" = mem ] && MEM_P=$P
  $CC $CFLAGS $S/tests/test_$t.c $P $HS $ENGINE -o $T/test_$t || echo "  FAILED"
done

# test_mmu 不需要 *_programs.S（上游 Makefile 里它是单独一条规则，没有汇编部分）
echo "== test_mmu"
$CC $CFLAGS $S/tests/test_mmu.c $ENGINE -o $T/test_mmu || echo "  FAILED"

# test_mem：打上 HV_SKIP 开关（宿主缺指令时跳过个别用例，别让整个套件中断）
mkdir -p $H/build/tsrc
python3 $H/tools/patch_tests.py $S/tests/test_mem.c $H/build/tsrc/test_mem.c
echo "== test_mem (HV_SKIP)"
$CC $CFLAGS $H/build/tsrc/test_mem.c $MEM_P $HS $ENGINE -o $T/test_mem || echo "  FAILED"

# test_smc_mp：跨 vCPU 的自修改代码作废（正确性安全门，BANK=0/1 对照）
echo "== test_smc_mp"
$CC $CFLAGS $H/tests/test_smc_mp.c $ENGINE -o $T/test_smc_mp || echo "  FAILED"

# test_smc_mp：跨 vCPU 的自修改代码作废（正确性安全门，BANK=0/1 对照）
echo "== test_smc_mp"
$CC $CFLAGS $H/tests/test_smc_mp.c $ENGINE -o $T/test_smc_mp || echo "  FAILED"

rm -f $T/*.o.S
ls -l $T | grep -vE '\.(o|S)$'
