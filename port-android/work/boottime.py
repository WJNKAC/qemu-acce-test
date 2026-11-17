#!/usr/bin/env python3
"""量"从启动到 systemd 达到某个 target"的宿主墙钟。
逐行读子进程输出，命中关键字就记时间——systemd 的 [ OK ] 行没有内核时间戳，
只能靠宿主侧打点。"""
import subprocess, sys, time

cmd = sys.argv[1:]
t0 = time.monotonic()
marks = {"Reached target multi-user.target": "multi-user",
         "Reached target basic.target": "basic",
         "Run /myinit": "initramfs init",
         "chrooted": "real root"}
done = {}
p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
for raw in iter(p.stdout.readline, b""):
    line = raw.decode("utf-8", "replace")
    for k, name in marks.items():
        if k in line and name not in done:
            done[name] = time.monotonic() - t0
            print(f"  {name:16s} {done[name]:6.2f} s", flush=True)
    if "multi-user" in done:
        p.terminate(); break
p.wait()
if not done:
    print("  (no marks seen)")
