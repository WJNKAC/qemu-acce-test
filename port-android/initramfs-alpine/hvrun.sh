#!/bin/sh
echo "=== net backend regression ==="
echo "  backend: $(grep -o 'HV_NET=[a-z]*' /proc/cmdline || echo default)"
ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null
ip route add default via 10.0.2.2 dev eth0 2>/dev/null
rm -f /etc/resolv.conf; printf 'nameserver 10.0.2.3\n' > /etc/resolv.conf
echo "  http: $(curl -s -m 25 -o /dev/null -w '%{http_code} %{size_download}B %{time_total}s' http://mirrors.tuna.tsinghua.edu.cn/debian/dists/bookworm/Release 2>&1)"
echo "  dl  : $(curl -s -m 40 -o /dev/null -w '%{size_download}B in %{time_total}s = %{speed_download}B/s' http://mirrors.tuna.tsinghua.edu.cn/debian/dists/bookworm/main/binary-arm64/Packages.gz 2>&1)"
sync; poweroff -f
