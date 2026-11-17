#!/bin/sh
# 在真实根里跑：等 systemd 完成启动，打出时间点，然后关机。
# 这样宿主侧的墙钟就是"开机到可用"的完整时间。
while [ ! -d /run/systemd/system ]; do sleep 0.1; done
for i in $(seq 600); do
    st=$(systemctl is-system-running 2>/dev/null)
    case "$st" in running|degraded) break;; esac
    sleep 0.1
done
echo "SYSTEM_READY at uptime $(cut -d' ' -f1 /proc/uptime)"
sync; poweroff -f
