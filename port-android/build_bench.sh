#!/bin/bash
# 把原项目自带的 test_bench（原生 vs 引擎 JIT，不经过 Linux 客户机）编到 Android 上。
# 意义：块转移/派发开销可以在"纯引擎"层面直接量，不受客户机内核干扰。
# EXTRA=1 时额外编入 tests/bench_extra.S 里的加长基本块程序。
set -u
H=$(cd "$(dirname "$0")" && pwd)
. "$H/config.sh"          # 提供 NDK / CC_ANDROID / ROOT
CC=$CC_ANDROID
S=$ROOT/src/WindowsiOS
T=$H/build/tests
PATCH="python3 $H/tools/patch_macho_asm.py"
EXTRA=${EXTRA:-1}
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
}

asm $S/tests/harness.S || exit 1
HS=$T/harness.o

if [ "$EXTRA" = 1 ]; then
  asm $S/tests/bench_programs.S || exit 1
  asm $H/tests/bench_extra.S || exit 1
  PROGS="$T/bench_programs.o $T/bench_extra.o"
  SRC=$H/tests/test_bench_ext.c
else
  asm $S/tests/bench_programs.S || exit 1
  PROGS=$T/bench_programs.o
  SRC=$S/tests/test_bench.c
fi

echo "== test_bench"
# patch_macho_asm.py 会去掉符号的前导下划线，所以 C 侧 TEST_PROGRAM(bench_x)
# 引用的 bench_x / bench_x_native / bench_x_end 正好对上。
$CC $CFLAGS $SRC $PROGS $HS $ENGINE -o $T/test_bench || exit 1
ls -l $T/test_bench
