#!/bin/bash
# 枚举 A64 的原子/独占/CAS 三组编码的位域空间，用汇编器产出真值，再与
# 引擎的 hv_classify() 对拍。
#
# 为什么要"枚举 + 汇编器反解"而不是自己查手册写期望值：
#   手册表格容易抄错，而且 decode 的 bug 往往就在边界（某个 size 组合、
#   某个 o2 位）。让汇编器当裁判，它认识的编码就是合法指令，助记符就是真值。
#
# 输出：sweep.objdump（给 decode_sweep 读），以及一行统计。
set -e
OUT=${1:-/data/用户/项目/qemu-acce/work/probe}
AS=aarch64-linux-gnu-as
OD=aarch64-linux-gnu-objdump

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 三组编码，按位域收紧：
#   LDXR/STXR (size 00/01/10/11 x o2 x L x o1 x Rs/Rt/Rn)
#   LDAR/STLR
#   CAS/CASP    (含 A/L 位、size 与 o2 的组合)
#   LSE 原子 RMW (LDADD 等，aop 全组合)
#
# 每条都用真实寄存器，避免汇编器因为 XZR/SP 的歧义拒绝。
gen_asm() {
    local f=$1
    : > "$f"
    echo ".text" >> "$f"
    echo ".arch armv8.1-a+lse" >> "$f"

    # ---- 独占：LDXR / STXR / LDAXR / STLXR，size=B/H/(W/X)，o2 变体 ----
    for sz in b h ""; do
      for l in "" "a"; do
        echo "  ldxr${l}${sz} w0, [x1]" >> "$f"
        echo "  ldxr${l}${sz} x0, [x1]" >> "$f"
        echo "  stxr${l}${sz} w2, w0, [x1]" >> "$f"
        echo "  stxr${l}${sz} w2, x0, [x1]" >> "$f"
      done
    done
    # ---- 独占对：LDXP / STXP / LDAXP / STLXP ----
    for l in "" "a"; do
      echo "  ldxp${l} w0, w1, [x2]" >> "$f"
      echo "  ldxp${l} x0, x1, [x2]" >> "$f"
      echo "  stxp${l} w3, w0, w1, [x2]" >> "$f"
      echo "  stxp${l} w3, x0, x1, [x2]" >> "$f"
    done
    # ---- acquire/release 单条 ----
    for sz in b h ""; do
      echo "  ldar${sz} w0, [x1]" >> "$f"
      echo "  ldar${sz} x0, [x1]" >> "$f"
      echo "  stlr${sz} w0, [x1]" >> "$f"
      echo "  stlr${sz} x0, [x1]" >> "$f"
    done
    # ---- CAS / CASA / CASL / CASAL，size 全组合 ----
    for suf in "" a l al; do
      for sz in b h ""; do
        echo "  cas${suf}${sz} w0, w1, [x2]" >> "$f"
        echo "  cas${suf}${sz} x0, x1, [x2]" >> "$f"
      done
    done
    # ---- CASP / CASPA / CASPL / CASPAL ----
    for suf in "" a l al; do
      echo "  casp${suf} w0, w1, w2, w3, [x4]" >> "$f"
      echo "  casp${suf} x0, x1, x2, x3, [x4]" >> "$f"
    done
    # ---- LSE RMW：全部 aop × size × 顺序后缀 ----
    for aop in ldadd ldclr ldeor ldset ldsmax ldsmin ldumax ldumin swp; do
      for suf in "" a l al; do
        for sz in b h ""; do
          echo "  ${aop}${suf}${sz} w0, w1, [x2]" >> "$f"
          echo "  ${aop}${suf}${sz} x0, x1, [x2]" >> "$f"
        done
      done
    done
    # ---- 对照组：普通 load/store、pair、LDR literal、分支、屏障 ----
    for sz in b h ""; do
      echo "  ldr${sz} w0, [x1]" >> "$f"; echo "  ldr${sz} x0, [x1]" >> "$f"
      echo "  str${sz} w0, [x1]" >> "$f"; echo "  str${sz} x0, [x1]" >> "$f"
    done
    echo "  ldr x0, =0x1234" >> "$f"        # 会变成 ldr (literal)，单独处理
    echo "  ldrsw x0, 0x8" >> "$f"
    echo "  prfm pldl1keep, [x0]" >> "$f"
    echo "  ldp x0, x1, [x2]" >> "$f"
    echo "  stp x0, x1, [x2]" >> "$f"
    for c in eq ne lt ge; do echo "  b.$c 1f" >> "$f"; done
    echo "1:" >> "$f"
    echo "  b 2f" >> "$f"; echo "2:" >> "$f"
    echo "  bl 3f" >> "$f"; echo "3:" >> "$f"
    echo "  cbz x0, 4f" >> "$f"; echo "  cbnz x0, 4f" >> "$f"
    echo "  tbz x0, #3, 4f" >> "$f"; echo "  tbnz x0, #3, 4f" >> "$f"
    echo "4:" >> "$f"
    echo "  br x0" >> "$f"; echo "  blr x0" >> "$f"; echo "  ret" >> "$f"
    echo "  adr x0, ." >> "$f"; echo "  adrp x0, ." >> "$f"
    echo "  dsb sy" >> "$f"; echo "  dmb sy" >> "$f"; echo "  isb" >> "$f"
    echo "  clrex" >> "$f"; echo "  wfi" >> "$f"; echo "  wfe" >> "$f"
    echo "  svc #0" >> "$f"; echo "  hvc #0" >> "$f"; echo "  brk #0" >> "$f"
    echo "  mrs x0, tpidr_el0" >> "$f"; echo "  msr tpidr_el0, x0" >> "$f"
    echo "  eret" >> "$f"
    echo "  add x0, x1, x2" >> "$f"; echo "  mov x0, x1" >> "$f"
    echo "  nop" >> "$f"
}

gen_asm "$TMP/sweep.S"
$AS -o "$TMP/sweep.o" "$TMP/sweep.S"
$OD -d "$TMP/sweep.o" > "$OUT/sweep.objdump"

n_insn=$(grep -cE "^\s+[0-9a-f]+:\s+[0-9a-f]{8}" "$OUT/sweep.objdump" || true)
n_uniq=$(grep -E "^\s+[0-9a-f]+:\s+[0-9a-f]{8}" "$OUT/sweep.objdump" \
         | awk '{print $2}' | sort -u | wc -l)
echo "objdump: $n_insn instructions, $n_uniq unique encodings -> $OUT/sweep.objdump"
