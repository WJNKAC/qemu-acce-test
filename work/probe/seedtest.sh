#!/system/bin/sh
# seedtest.sh - seed v2 的 reboot 循环：host 侧守株待兔
#
# 与 nrun2.sh 的根本区别：**reset 由 guest 自己发起**（netprobe 里 systemctl reboot
# → PSCI SYSTEM_RESET），host 侧只起一次进程、只读 serial。
#
# 这才是"guest 内 reboot"形态 —— system_reset 是 QEMU 侧硬复位，设备被拉到
# 冷态、驱动从头初始化，与 guest 内 reboot 走的 warm reset 路径不是一回事。
#
# 判据（全部在 serial 上，不需要登录）：
#   NETPROBE-BEGIN/END round=N   每轮探针完成（缺 END = 半途死）
#   NETPROBE-ADDR                地址拿到没有
#   NETPROBE-TCP-GW53/GW22       guest→slirp 数据面（TCP，不用 ping）
#   NETPROBE-CURL                full path（host 侧要起 10080 监听）
#   ci-info 网卡表               cloud-init 侧旁证（13.40）
#
# 断链检测：连续 3×OnBootSec(60s)=180s 没有新的 NETPROBE-BEGIN 就报警。
#
# 用法: seedtest.sh <tag> <bin> <max_rounds> [timeout_s] [smp] [seed.iso]
set -u
# say 必须在最前面：第 82 行的监听者分支就要用它，
# 它原先定义在第 183 行 —— 那段代码是"只在端口被占时才走"的分支，
# 平时不执行，所以一直没人发现它是未定义引用。
say() { echo "$@"; }
TAG=${1:?tag}
BIN=${2:?bin}
MAXR=${3:-4}
TMO=${4:-360}
SMP=${5:-2}
SEED=${6:-/data/local/tmp/seed-v2.iso}
H=/data/local/tmp
BIOS=$H/henge/bios
LOG=$H/st-$TAG.serial.log
ERR=$H/st-$TAG.err
VARS=$H/st-$TAG.img
DISK=$H/st-$TAG.qcow2
MPORT=${MPORT:-4460}
# 网络后端：slirp（默认，向后兼容）或 passt（走 passtlaunch + socketpair）
NET=${NET:-slirp}
# passt 的必须项：三个运行时开关 + DNS。缺一个就是 SIGSYS 或取不到 nameserver。
export HV_PASST_NO_SECCOMP=1 HV_PASST_NO_SANDBOX=1 HV_PASST_NO_USERNS=1
PASST_DNS=${PASST_DNS:-223.5.5.5}
# 13.55：打过 0002 的二进制（q-p0a9+）读这个变量补上上游 DNS。
# 老二进制（q-p0a8-）根本不 getenv 它，所以默认给值对它们零影响。
SLIRP_DNS_SERVER=${SLIRP_DNS_SERVER-223.5.5.5}
[ -n "$SLIRP_DNS_SERVER" ] && export SLIRP_DNS_SERVER

[ -x "$BIN" ] || { echo "MISSING $BIN"; exit 3; }
[ -f "$SEED" ] || { echo "MISSING $SEED"; exit 3; }
[ -x "$H/vclk" ] || { echo "MISSING vclk"; exit 3; }

# VARS_SRC 可指向一个"已被 UEFI 写过"的 varstore，用来做对照实验。
# 13.59 就是靠它隔离出"UEFI 引导项累积 -> 掉菜单 -> 不再进 Linux"的。
VARS_SRC=${VARS_SRC:-$H/vars0.img}
cp -f "$VARS_SRC" "$VARS" 2>/dev/null; chmod 644 "$VARS" 2>/dev/null
# 磁盘必须用副本。直接挂 deb12.qcow2 会把 netprobe 三件套写进基线 ——
# 第一次试跑就是这么污染的：之后所有基于它的 overlay 都会自动 reboot。
# 基线 deb12-clean.qcow2 是 444，副本显式放开写权限（toybox 的 cp -f 保留源权限）。
cp -f ${DISK_SRC:-$H/deb12-clean.qcow2} "$DISK" 2>/dev/null; chmod 644 "$DISK" 2>/dev/null
rm -f "$LOG" "$ERR"

# 公共参数抽出来，两种后端只有 -netdev 一行不同。
# %QFD% 只在 passt 模式下有意义（launcher 会替换成 socketpair 那端的 fd）。
QEMU_ARGS="-L $BIOS -M virt,gic-version=3 -cpu max -m 2048
  -display none -smp $SMP -accel henge
  -drive if=pflash,format=raw,unit=0,file=$BIOS/edk2-aarch64-code.fd,readonly=on
  -drive if=pflash,format=raw,unit=1,file=$VARS
  -drive if=none,id=d0,format=qcow2,file=$DISK -device virtio-blk-pci,drive=d0
  -drive if=none,id=sd,format=raw,file=$SEED -device virtio-blk-pci,drive=sd
  -serial file:$LOG -monitor tcp:127.0.0.1:$MPORT,server,nowait"

# QEMU_ARGS 是靠无引号展开传参的（shell 没有数组），所以任何一个含空格的
# 路径都会被拆成两个参数。实测过：file:/tmp/my log.txt 会变成
# [2] file:/tmp/my  [3] log.txt。这里提前断言，别等到 QEMU 报奇怪的错。
for v in "$LOG" "$VARS" "$DISK" "$SEED" "$BIN" "$BIOS"; do
    case "$v" in
      *" "*) echo "ABORT: 路径含空格，QEMU_ARGS 展开会拆断: $v"; exit 2 ;;
    esac
done

case "$NET" in
  slirp)
    # host 侧监听：CURL-GW 打的是 10.0.2.2:10080，需要有人在听。
    # 之前靠外面手动起 listen.sh，它挂掉后没人发现 —— 结果 20 轮 curl 全 000，
    # 差点读成"外网全不通"。现在由脚本自己管生命周期。
    # 端口号别手写十六进制：10080 = 0x2760。这里原来写的是 ':2768'（=10088）。
    # 而且 toybox 的 nc **监听在 IPv6**（记录在 /proc/net/tcp6，local 全是 0），
    # 只查 /proc/net/tcp 永远查不到。两个错叠加的结果是：守卫恒判"没人听"，
    # 每轮再起一个监听者，而收尾又收不掉（见下面 pidfile 那段）。
    LHEX=$(printf '%04X' 10080)
    LPFILE=$H/st-$TAG.listen.pid
    if awk 'NR>1 && $4=="0A" {print $2}' /proc/net/tcp /proc/net/tcp6 2>/dev/null \
         | grep -qi ":${LHEX}$"; then
        LREUSE=1
        say "!! 10080(0x$LHEX) 已被占用 —— 沿用现有监听者。"
        say "   本轮 curl-GW 的读数不由本脚本担保（可能是上一轮泄漏的 nc）。"
    else
        LREUSE=0
        # ⚠ pidfile 必须由**父进程**写，内容用 `$!`。
        # 原来是在子 shell 里写 `echo $$` —— 而 POSIX sh 里子 shell 的 `$$`
        # 是**父进程**的 PID（实测：外层 29509，`( echo $$ )` 也是 29509）。
        # 于是 pidfile 存的是本脚本自己的 PID，cleanup 里
        # `kill -9 $(cat pidfile)` 就是**自杀**，后面的 `rm -f $LPFILE`
        # 永远执行不到 —— 现场就是"端口放了，pidfile 还在"。
        # 这是第四次同类（前三次：清理循环自杀、"*abtest*" 匹配自身、pgrep -f 自匹配）。
        ( while true; do
            printf 'HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK' \
              | timeout 30 nc -l -p 10080 -q1 >/dev/null 2>&1
            sleep 1
          done ) >/dev/null 2>&1 &
        LPID=$!
        echo "$LPID" > "$LPFILE"
        sleep 1
    fi
    # shellcheck disable=SC2086
    $BIN $QEMU_ARGS -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
        >/dev/null 2>"$ERR" &
    QP=$!
    ;;
  passt)
    # passt 侧不能 bind（SELinux 拒），所以用 socketpair + --fd 两侧都不 bind。
    # 详见 work/probe/passtlaunch.c 与 work/seed/passt/README.md。
    [ -x "$H/passtlaunch" ] || { echo "MISSING $H/passtlaunch"; exit 3; }
    [ -x "$H/passt" ]       || { echo "MISSING $H/passt"; exit 3; }
    # shellcheck disable=SC2086
    $H/passtlaunch \
        $H/passt -f -q -F %PFD% -D "$PASST_DNS" \
        -- \
        $BIN $QEMU_ARGS -netdev socket,id=n0,fd=%QFD% -device virtio-net-pci,netdev=n0 \
        >/dev/null 2>"$ERR" &
    QP=$!
    ;;
  *)
    echo "bad NET=$NET (slirp|passt)"; exit 2 ;;
esac
# 递归杀子进程。passtlaunch 会 fork 出 passt + qemu；监听者是
# subshell + timeout + nc 三层 —— `kill -9 父` 只掉最外面那层，
# nc 会活到自己的 `timeout 30` 到期为止（实测：收尾后还剩 1 个 nc）。
killtree() {
    # 用位置参数，不用临时变量：POSIX sh 没有 `local`，
    # 递归时内层会把外层的 `_p` 覆盖掉，最后那行 `kill -9` 就杀错了进程。
    # （写了第一版就是这个错，靠读自己的代码发现，不是靠跑出来。）
    for _k in $(pgrep -P "$1" 2>/dev/null); do killtree "$_k"; done
    kill -9 "$1" 2>/dev/null
}

cleanup() {
    killtree "$QP"
    # slirp 模式下我们自己起的 host 监听，退出时一并收掉
    # 只按 pidfile 杀，绝不按名字匹配。实测：pgrep -f "nc -l -p 10080" 在
    # 设备上返回 3 个进程 —— 因为外层 sh -c 的命令行里也含这个串，
    # 连 [n]c 字符类都挡不住（整条 sh -c 的命令行是字面量）。
    # 这是第三次同类陷阱（前两次：清理循环自杀、"*abtest*" 匹配到自身）。
    if [ -n "${LPID:-}" ]; then killtree "$LPID"; fi
    if [ -f "${LPFILE:-/nonexistent}" ]; then
        _lp=$(cat "$LPFILE" 2>/dev/null)
        # 绝不杀自己：pidfile 一旦被写错（本 bug 就是），这条会静默自杀，
        # 而"自杀"在现场看起来是"脚本正常结束、只是没清干净"。
        if [ -n "$_lp" ] && [ "$_lp" != "$$" ] && [ "$_lp" != "1" ]; then
            killtree "$_lp"
        elif [ "$_lp" = "$$" ]; then
            say "!! pidfile 里是本脚本自己的 PID（$_lp）—— 跳过，不自杀"
        fi
        rm -f "$LPFILE"
    fi
}
trap cleanup EXIT HUP INT TERM

mon() { printf '%s\n' "$1" | timeout 3 nc 127.0.0.1 $MPORT 2>/dev/null; }

# 日志滚动。soak 一夜几百轮 × ~200KB 会写满 /data/local/tmp；
# 而 Android 的配额失败是静默的（df 显示有空间也可能已达媒体配额）。
# 策略：超过 MAXLOG 字节就把前半截掉，只留最近一轮的完整记录。
MAXLOG=${MAXLOG:-4000000}
roll_log() {
    sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "$sz" -le "$MAXLOG" ] && return
    cut=$((sz - MAXLOG / 2))
    tail -c +$cut "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
    echo "## LOG-ROLLED at ${sz}B (kept last $((sz - cut))B)" >> "$LOG"
}
cnt() { n=$(grep -ac "$1" "$LOG" 2>/dev/null); echo "${n:-0}"; }
# 去 ANSI 后的日志副本：systemd 的 [  OK  ] 行带颜色码。
#
# ⚠ 13.56 实测：toybox 的 sed **不认 `\x1b`**。原来那句
#   sed -E 's/\x1b\[[0-9;]*m//g'
# 在设备上是 no-op —— 360734 B 进，360734 B 出，一个字节都没动。
# 它一直没被发现，是因为所有判据的 pattern 里都带 `.*`，而 `.*` 能把
# 颜色码一起吃掉，所以读数是"碰巧对"的。哪天真写一个带锚点（$ 结尾）的
# 判据，就会静默失效。
#
# 可移植写法：用 printf 现造 ESC 再塞进 sed（POSIX，GNU/BSD/toybox 都吃）。
NOANSI=$LOG.noansi
strip_ansi() {
    _esc=$(printf '\033')
    sed "s/${_esc}\[[0-9;]*m//g" "$LOG" > "$NOANSI" 2>/dev/null
    # 自检用**正对照**，不是查残留：非 SGR 的转义序列（光标、清行）本来就该留着，
    # 查残留必然误报，而误报会训练人忽略告警。这里喂一段已知带色码的样本，
    # 看同一个 sed 剥不剥得掉。
    # 注意：剥不掉时探针**打印出来照样像 "AB"**（ESC 序列在终端里不可见），
    # 所以必须比字节，不能看屏幕。
    _probe=$(printf 'A%s[0;1mB' "$_esc" | sed "s/${_esc}\[[0-9;]*m//g")
    if [ "$_probe" != "AB" ]; then
        say "!! strip_ansi 自检失败：这个 sed 不认 ESC 转义 —— 依赖 $NOANSI 的判据全部作废"
    fi
}

# ---- boot_id 哨兵 ----
# 唯一能区分"QEMU 崩了"和"整机被重启/关机"的手段。
# 两者的现象完全一样（进程消失、serial 停止），但结论完全相反。
# ColorOS 有定时开关机（com.android.BBKCrontab），shell 权限禁不掉
# （pm disable-user 报 no root permission），所以不靠"关掉它"，靠"认出它"。
BID0=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
say_bid() { echo "$BID0"; }

set -- $($H/vclk); M0=$1; B0=$2
SUSP=0

say "=== seedtest tag=$TAG smp=$SMP max_rounds=$MAXR timeout=${TMO}s ==="
say "（reset 由 guest 内 systemctl reboot 发起，host 只读 serial）"

ELAPSED=0
LAST_ROUND=0
STALL=0
while [ $ELAPSED -lt $TMO ]; do
    RN=$(cnt 'NETPROBE-BEGIN')
    if [ "$RN" -gt "$LAST_ROUND" ]; then
        LAST_ROUND=$RN
        STALL=0
        say "--- round $RN (t=${ELAPSED}s) ---"
        # 取该轮 BEGIN 到 END 之间的段落。
        # 第一版用 `grep 'NETPROBE-.*round=N'`，只有 BEGIN/END 两行带 round=N，
        # 所以摘要只打出两行 BEGIN —— 判据全丢。改成 awk 按轮次切段。
        awk -v r="$RN" '
            /NETPROBE-BEGIN round=/ { if (match($0, /round=[0-9]+/)) cur = substr($0, RSTART+6, RLENGTH-6) }
            cur == r { if (match($0, /NETPROBE-[A-Z0-9-]+.*/)) print "  " substr($0, RSTART, RLENGTH) }
            /NETPROBE-END round=/ && cur == r { exit }
        ' "$LOG" 2>/dev/null | head -20
    fi
    # 到轮数后不能立刻走：最后一轮可能刚 BEGIN、还没 END。
    # 这个形态已经出现三次（13.47 的 18/20、13.51 的 2 轮、13.52 的 20 轮），
    # 根因是 rounds 与 timeout 是两个独立上限，而"末轮的 END"没被算进 timeout。
    # 现在：达到轮数后，额外等 END 追上 BEGIN（最多 120s），再退出。
    if [ "$RN" -ge "$MAXR" ]; then
        EW=0
        while [ "$EW" -lt 120 ]; do
            ENDN=$(cnt 'NETPROBE-END')
            [ "$ENDN" -ge "$RN" ] && break
            kill -0 $QP 2>/dev/null || break
            sleep 2; EW=$((EW + 2))
        done
        [ "$EW" -ge 120 ] && say "!! 末轮 END 未追平（BEGIN=$RN END=$(cnt 'NETPROBE-END')），等满 120s 退出"
        break
    fi
    kill -0 $QP 2>/dev/null || { say "!! QEMU 退出（t=${ELAPSED}s）"; break; }

    # 断链检测：180s 无新轮次 = 卡住
    if [ "$RN" -ge 1 ] && [ "$STALL" -ge 180 ]; then
        say "!! STALL: ${STALL}s 无新 NETPROBE-BEGIN（最后是 round $RN）"
        say "   最后 5 行 serial："
        tail -5 "$LOG" 2>/dev/null | sed 's/^/   /'
        break
    fi

    # 整机重启检测：boot_id 变了 = 不是 QEMU 的问题
    BIDN=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    if [ -n "$BIDN" ] && [ "$BIDN" != "$BID0" ]; then
        say "!! DEVICE-REBOOTED: boot_id 变了（$BID0 -> $BIDN）"
        say "   这不是 QEMU crash —— 是整机重启/关机（ColorOS 定时开关机？）"
        say "   最后 5 行 serial："
        tail -5 "$LOG" 2>/dev/null | sed 's/^/   /'
        DEVREBOOT=1
        break
    fi
    sleep 5
    ELAPSED=$((ELAPSED + 5))
    STALL=$((STALL + 5))
done

sleep 2
# 正常退出也要走 cleanup：原来这里是 `kill -9 $QP` + `trap - EXIT`，
# 把 QEMU 杀了却把 cleanup 摘掉了 —— 监听者永远不会被收。
# 收尾比启动更容易漏，因为它不出现在"跑通"的那条路上。
cleanup
sleep 1
trap - EXIT HUP INT TERM

# ---- 汇总 ----
set -- $($H/vclk); M1=$1; B1=$2
# vclk 在 QEMU 已退出后调用，M/B 仍有效；但若读失败会给 -1，兜底成 0
DS=$(( (B1 - B0) - (M1 - M0) ))
[ "$DS" -lt 0 ] && DS=0

BEG=$(cnt 'NETPROBE-BEGIN'); END=$(cnt 'NETPROBE-END')
ADDR=$(cnt 'NETPROBE-ADDR')
# 先把日志剥一遍 ANSI 生成最新副本。必须放在所有 cnt() 之前：
# 否则 CEXTCODES 那类直接读 $NOANSI 的地方会拿到上一轮的旧副本
# （实测：passt 那次 分布显示"无"，但非000=2 —— 就是读到了过期文件）。
strip_ansi

# grep -c 零命中时同时打印 0 并返回 1，`|| echo 0` 会变成两行 —— 用 cnt()。
# 每个判据分开数，不合并。合并会丢掉"是哪一条失败"这个信息。
GW22REF=$(cnt 'TCP-GW22 state=refused')
EXT_OK=$(cnt 'TCP-EXT state=ok')
EXT_BAD=$(cnt 'TCP-EXT state=timeout')
GW22BAD=$(cnt 'TCP-GW22 state=timeout')
TIMEOUT_ALL=$(cnt 'state=timeout')
DNSFAIL=$(cnt 'DNS-RESOLVE result=fail')
DNSDONE=$(cnt 'NETPROBE-DNS-RESOLVE')
DNSOK=$((DNSDONE - DNSFAIL))
CGW200=$(cnt 'CURL-GW code=200')
CGWN=$(cnt 'NETPROBE-CURL-GW')
# curl-EXT 的目标是 223.5.5.5（AliDNS），它对 "/" 正常返回 404 ——
# 只数 200 会让 404 完全隐形（实测：2 轮都拿到 404，汇总却显示 200=0 000=0）。
# 只要不是 000，就说明"TCP+HTTP 都通了"，具体码只作参考。
CEXTN=$(cnt 'NETPROBE-CURL-EXT')
CEXT000=$(cnt 'CURL-EXT code=000')
CEXTCODES=$(grep -a 'NETPROBE-CURL-EXT code=' "$NOANSI" 2>/dev/null | sed -E 's/.*code=//' | tr -d '\r' | sort | uniq -c | tr '\n' ' ')
CEXTOK=$((CEXTN - CEXT000))
# 探针自身异常：只看 tcp_state 的 "err:<Type>"。
# 不能把 DNS 的 "fail:gaierror" 算进来 —— 那是**真实的 DNS 失败**（结果），
# 不是探针坏了。混在一起会让"DNS 不工作"被读成"探针有 bug"。
# （更早的版本数的是 'PROBE-ERR'，而探针从不打这个串 —— 等于永远 0，空仪器。）
PERR=$(cnt 'state=err:')
CI=$(cnt 'ci-info: | Device')
# ⚠ MU 是**参考值，不是判据**（13.56 实测两侧）：
#   st-e   ：3/3 轮读到 "Reached target multi-user.target"
#   fix6   ：0/6 轮读得到 —— 整份日志里 multi-user 只以 "Stopped target" 出现
#             5 次，而同一轮 DNS 6/6 通、curl 200 6/6、timeout 0。
# 也就是说这轮完全健康却读 0。凡是"健康但读 0"的东西都不能当门禁用。
# 保留它只为出问题时能一眼看出 systemd 走到哪一步。
MU=$(grep -ac 'Reached target.*multi-user' "$NOANSI" 2>/dev/null); MU=${MU:-0}
SEEDINST=$(cnt 'HENGE-SEED-V2-INSTALLED')

say
say "=== 汇总 (net=$NET) ==="
say "轮次: BEGIN=$BEG  END=$END   ci-info=$CI   multi-user=$MU(参考)   seed=$SEEDINST"
say "TCP 网关: refused=$GW22REF(路径通)  timeout=$GW22BAD"
say "TCP 外网: ok=$EXT_OK  timeout=$EXT_BAD   (223.5.5.5:80，不依赖 DNS)"
say "DNS 解析: ok=$DNSOK  fail=$DNSFAIL / 共$DNSDONE"
# passt 下 10.0.2.2/网关是**真实路由器**，它不可能有我们的 10080 监听，
# 所以这一列在 passt 下永远 0/20。照原样打出来会被读成"curl 全坏"。
# 仪器读不出来的量，就不要摆成一个像结果的数。
if [ "$NET" = passt ]; then
    say "curl-GW(host监听): 不适用（passt 下 GW 是真实路由器，无 10080；见 13.53）"
else
    say "curl-GW(host监听): 200=$CGW200/$CGWN"
fi
say "curl-EXT(公网IP): 非000=$CEXTOK 000=$CEXT000 / 共$CEXTN   分布: ${CEXTCODES:-无}（404 属正常：AliDNS 无 / 页面）"
say "任意 timeout 总数: $TIMEOUT_ALL   ← 唯一可疑信号"
say "探针异常: $PERR（数的是 err:* 与 PROBE-ERR，不是 refused/timeout）"
say "dsusp_ms=$DS  verdict=$( [ $DS -lt 1000 ] && echo VALID || echo INVALID )"
if [ "$BEG" -eq "$END" ] && [ "$BEG" -gt 0 ]; then
    say "完整性: 每轮都有 END —— 无半途死"
else
    say "完整性: BEGIN=$BEG != END=$END  ⚠ 有轮次中断"
fi
# set -u 下未赋值变量会直接 FATAL，而这两个只在 passt 模式下有意义。
# 第一次写这段时赋值语句被漏掉了（replace 只插了注释和 if），
# 结果整个汇总在这里断掉 —— 所以先给默认值，再在 passt 分支里覆盖。
PASST_ADDR=n/a; PASST_GW=n/a
if [ "$NET" = passt ]; then
    PASST_ADDR=$(grep -a 'NETPROBE-ADDR' "$LOG" 2>/dev/null | tail -1 | sed -E 's/.*NETPROBE-ADDR //' | tr -d '\r')
    PASST_GW=$(grep -a 'NETPROBE-GW' "$LOG" 2>/dev/null | tail -1 | sed -E 's/.*gw=//' | tr -d '\r')
    say "passt: 地址=${PASST_ADDR:-n/a}  网关=${PASST_GW:-n/a}  （应分别为 169.254.x/8 与宿主真实网关）"
fi
say "boot_id: 起始 $BID0   结束 $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
[ "${DEVREBOOT:-0}" = 1 ] && say "!! 判定: 整机重启过（不是 QEMU 的问题）"
if [ "$BEG" -gt 1 ]; then
    say "★ per-instance 坑已绕过：第 $BEG 轮仍在跑（cloud-init 模块早已失效）"
else
    say "⚠ 只跑到 $BEG 轮 —— 无法证明 per-instance 已绕过"
fi
