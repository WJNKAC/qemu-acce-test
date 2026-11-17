#!/bin/bash
# 构建一个 core 变体，并保证 ABI 一致。
#
# 为什么不能只靠 make 的依赖：cpu.h 变了但 .o 的依赖链里少一环，
# 就会留下"半新半旧"的 .o —— 结果是 sizeof(HvCpu) 对不上，
# 表现为段错误或莫名变慢（踩过两次，一次 34MB vs 82MB）。
# 变体切换这么便宜（全量 15 秒），不值得为省这几秒冒险。
#
#   ./tools/build_variant.sh 14        # 基线
#   ./tools/build_variant.sh 16        # TLB 256 MB
#   ./tools/build_variant.sh 16 1      # 16 位 TLB + PMD bank
#   ./tools/build_variant.sh 16 0 1    # + refill 分段计时（PROF）
#   ./tools/build_variant.sh 14 0 0 0 1        # BITS=14 + whint 位图
#   ./tools/build_variant.sh 14 0 0 0 1 1      # + 2 MB bank
#
#   BANK_RD=1  ./tools/build_variant.sh 14 0 0 0 1 1   # 交付配置：bank 只服务读
#   BANK_RD=0  ...（默认）                            # 实验：读写都走 bank（SMC 不安全，
#                                                      # 仅用于量"写侧值不值得修"，见 MEASURE.md 第六轮）
#
# 注意：BANK_RD 只改 translate.c 的探测，不动 HvCpu 布局；BANK 会加 32 KB 数组，
#       切 BANK 必须全量重编（下面已经强制 rm -f build/*.o）。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
B=${1:?usage: build_variant.sh <TLB_BITS> [PMD_BANK]}
P=${2:-0}
R=${3:-0}
A=${4:-0}
W=${5:-0}
K=${6:-0}
K=${6:-0}
W=${5:-0}
K=${6:-0}
K=${6:-0}
A=${4:-0}
W=${5:-0}
K=${6:-0}
K=${6:-0}
W=${5:-0}
K=${6:-0}
K=${6:-0}
cd "$H"
make -s TLB_BITS="$B" PMD_BANK="$P" PROF="$R" ABL="$A" WHINT="$W" BANK="$K" build/core/variant.txt >/dev/null 2>&1 || true
# translate_patched.c 也必须删：BANK_SEEN / BANK_RD / BANK_EL / RET_MODE / HASH 都是
# **环境变量**驱动的，改它们不会让 build/translate_patched.c 的 mtime 变化，make 就会
# 复用上一个变体的副本 —— 症状是"改了开关但行为没变"或"头文件对不上直接编不过"。
# translate_patched.c 也必须删：BANK_SEEN / BANK_RD / BANK_EL / RET_MODE / HASH 都是
# **环境变量**驱动的，改它们不会让 build/translate_patched.c 的 mtime 变化，make 就会
# 复用上一个变体的副本 —— 症状是"改了开关但行为没变"或"头文件对不上直接编不过"。
python3 -c "import os,glob; [os.remove(f) for f in glob.glob('build/*.o')+glob.glob('build/hv-linux')+['build/translate_patched.c'] if os.path.exists(f)]"
make -s TLB_BITS="$B" PMD_BANK="$P" PROF="$R" ABL="$A" WHINT="$W" BANK="$K" 2>&1 | grep -E "error" | head -3 || true
[ -x build/hv-linux ] || { echo "构建失败" >&2; exit 1; }
# 自检：sizeof(HvCpu) 必须和变体一致（每 CPU = 表数 × 槽数 × 32 + 2 MB 返回表）
sz=$(aarch64-linux-gnu-nm -S build/main_android.o 2>/dev/null | awk '$4=="cpus"{print strtonum("0x"$2)}')
echo "variant TLB_BITS=$B PMD_BANK=$P PROF=$R ABL=$A WHINT=$W BANK=$K  cpus=$((sz/1048576)) MB  hv=$(stat -c %s build/hv-linux) B"
