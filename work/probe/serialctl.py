#!/usr/bin/env python3
"""serialctl.py —— 通过 QEMU 的 `-serial tcp:...` 与客机 console 交互。

为什么需要它：`-serial file:` 只能写不能读，`-serial tcp:` 是**独占的流**——
一旦连上，之前已经打出去的字节就永远看不到了。每次用 shell 一行命令连一下就断，
结果就是"永远只看到最后几行"。

这个工具维持一个长连接，可以做三件事：
  send  "命令"    发一行回车结尾的文本
  read  [秒]      读指定秒数的输出
  login           发换行等 login 提示，root/henge 登入

用法：
  python3 serialctl.py --port 4491 login
  python3 serialctl.py --port 4491 send "uname -r" --read 3
  python3 serialctl.py --port 4491 read 5
"""
import argparse
import socket
import sys
import time


class Serial:
    def __init__(self, host="127.0.0.1", port=4491, timeout=1.0):
        self.s = socket.create_connection((host, port), timeout=10)
        self.s.settimeout(timeout)

    def read(self, seconds=3.0):
        buf = b""
        t0 = time.time()
        while time.time() - t0 < seconds:
            try:
                d = self.s.recv(65536)
                if not d:
                    break
                buf += d
            except socket.timeout:
                continue
        return buf.decode("utf-8", "replace")

    def send(self, text, cr=True):
        # 客机 console 要 \r 才会当回车（\n 在某些 termios 设置下不动光标）
        self.s.sendall(text.encode() + (b"\r" if cr else b""))

    def read_until(self, needle, seconds=20.0):
        # needle 可能是 str 也可能是 bytes —— 统一编码后在 bytes 里找。
        # 第一版忘了这一步，直接 `str in bytes` 抛 TypeError（踩过）。
        nb = needle.encode() if isinstance(needle, str) else needle
        buf = b""
        t0 = time.time()
        while time.time() - t0 < seconds:
            try:
                d = self.s.recv(65536)
                if not d:
                    break
                buf += d
                if nb in buf:
                    break
            except socket.timeout:
                continue
        return buf.decode("utf-8", "replace")

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=4491)
    ap.add_argument("--host", default="127.0.0.1")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("read").add_argument("seconds", nargs="?", type=float, default=4.0)

    p_send = sub.add_parser("send")
    p_send.add_argument("text")
    p_send.add_argument("--read", type=float, default=3.0)
    p_send.add_argument("--no-cr", action="store_true")

    p_login = sub.add_parser("login")
    p_login.add_argument("--user", default="root")
    p_login.add_argument("--password", default="henge")
    p_login.add_argument("--wait", type=float, default=25.0)

    a = ap.parse_args()
    ser = Serial(a.host, a.port)

    if a.cmd == "read":
        sys.stdout.write(ser.read(a.seconds))

    elif a.cmd == "send":
        ser.send(a.text, cr=not a.no_cr)
        sys.stdout.write(ser.read(a.read))

    elif a.cmd == "login":
        # 先醒一下，看有没有 login: 提示
        ser.send("")
        out = ser.read(3)
        sys.stdout.write(out)
        if "login:" in out:
            ser.send(a.user)
            out2 = ser.read_until("assword", 10)
            sys.stdout.write(out2)
            ser.send(a.password)
            out3 = ser.read(a.wait)
            sys.stdout.write(out3)
        else:
            # 可能已经在 shell 里
            ser.send("echo SERIAL-ALIVE-$(id -u)")
            sys.stdout.write(ser.read(3))

    ser.close()


if __name__ == "__main__":
    main()
