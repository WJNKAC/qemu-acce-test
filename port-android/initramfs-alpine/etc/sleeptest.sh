#!/bin/sh
echo "sleeping 5 (guest seconds)..."
a=$(cut -d' ' -f1 /proc/uptime)
sleep 5
b=$(cut -d' ' -f1 /proc/uptime)
echo "guest uptime $a -> $b"
poweroff -f
