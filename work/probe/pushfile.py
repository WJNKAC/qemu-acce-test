#!/usr/bin/env python3
"""pushfile.py —— 通过 QEMU 串口把本地文件送进客机。

为什么不用 HTTP：设备上只有 toybox 的 `nc`，用它拼 HTTP 服务时
发送端会在 `cat` 结束后立刻退出，socket 缓冲里剩下的字节被丢掉，
curl 报 `(18) transfer closed with N bytes remaining`，且缺多少每次都不一样
（实测缺 513 / 532 字节）。加 `sleep` 也治不住。

而串口这条路是**已经在用**的（serialctl.py），并且是字符流、天然有界，
所以改成：base64 编码 -> 按块 echo 追加 -> 最后 base64 -d + sha256 核对。

分块大小的取舍：
  太小 -> 命令条数多，每轮都有往返开销
  太大 -> 超过 tty 的行缓冲（agetty 默认 4096），会被截断
  选 180 个 base64 字符（=135 字节原始数据）留足余量。

用法：
  python3 pushfile.py --port 4491 --src ./bench --dst /root/bench
"""
import argparse
import base64
import hashlib
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from serialctl import Serial  # noqa: E402

CHUNK = 180  # base64 字符数


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4491)
    ap.add_argument("--src", required=True)
    ap.add_argument("--dst", required=True)
    ap.add_argument("--chunk", type=int, default=CHUNK)
    a = ap.parse_args()

    raw = open(a.src, "rb").read()
    b64 = base64.b64encode(raw).decode()
    want_sha = hashlib.sha256(raw).hexdigest()

    s = Serial(port=a.port, timeout=0.5)
    s.send("")            # 唤醒提示符
    s.read(1.0)

    tmp = a.dst + ".b64"
    s.send("rm -f %s" % tmp)
    s.read(0.6)

    n = 0
    total = (len(b64) + a.chunk - 1) // a.chunk
    t0 = time.time()
    for i in range(0, len(b64), a.chunk):
        piece = b64[i:i + a.chunk]
        # 单引号包裹：base64 字母表里没有单引号，安全
        s.send("echo -n '%s' >> %s" % (piece, tmp))
        n += 1
        # 不给每块都等完整回显（太慢），只每 10 块同步一次
        if n % 10 == 0 or n == total:
            s.read(0.35)
    s.read(1.0)

    print("已发 %d 块 / 共 %d 块，用时 %.1fs" % (n, total, time.time() - t0))

    # 解码 + 校验。校验用 sha256sum，失败就是传输不完整，不猜。
    s.send("base64 -d %s > %s && chmod +x %s && echo DECODED-OK" % (tmp, a.dst, a.dst))
    out = s.read(3)
    if "DECODED-OK" not in out:
        print("!! 解码失败")
        print(out[-800:])
        s.close()
        return 1

    s.send("sha256sum %s" % a.dst)
    out = s.read(3)
    got = ""
    for tok in out.split():
        if len(tok) == 64 and all(c in "0123456789abcdef" for c in tok):
            got = tok
            break

    print("期望 sha256: %s" % want_sha)
    print("实际 sha256: %s" % (got or "(未取到)"))
    if got == want_sha:
        print("✅ 逐字节一致")
        s.send("rm -f %s" % tmp)
        s.read(0.5)
        s.close()
        return 0

    print("❌ 校验不符")
    s.close()
    return 2


if __name__ == "__main__":
    sys.exit(main())
