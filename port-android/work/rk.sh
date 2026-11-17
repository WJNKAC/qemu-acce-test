#!/system/bin/sh
# 在设备上跑一档 knee（guest 内测量）。用法：rk.sh <engine> <KiB> [guestMB]
# 条件固定：绑 cpu0、HV_SUM 汇总、无 --stats（分类计数器不带也不影响 knee 行）。
BIN=$1
KIB=$2
RAM=${3:-2560}
DEV=/data/local/tmp
# 注意：不能用 pkill -f hv- —— 本脚本自己的命令行里就有 "hv-bank"，
# 会把自己 SIGTERM 掉（症状：exit 143、零输出）。按进程名精确匹配。
for n in hv-linux hv-bank hv hv-tcg; do pkill -x "$n" 2>/dev/null; done
sleep 0.3
timeout 300 env HV_SUM=1 \
  HV_BOOTARGS="console=ttyAMA0 rdinit=/myinit loglevel=0 HVB=knee KNEE=$KIB" \
  taskset c0 "$BIN" --kernel $DEV/Image --ram "$RAM" --cpus 1
