#!/usr/bin/env python3
"""从 QEMU 外侧改写 guest 代码页，验证 henge 的 DMA->SMC 钩子。

    gdbstub 的 M 包 -> cpu_memory_rw_debug -> address_space_rw
                    -> flatview_write      ← 引擎的钩子在这里

用法: dma-inject.py <qmp-socket> <gdb-socket> <fn_addr> <mailbox_addr>

三步，每一步的坑都踩过：

  1. QMP `stop`        gdbstub 只在 VM 停下时处理包；运行中它完全不响应
                       （实测：`m` 返回空）。guest 的 `brk #0` 也不能用 ——
                       引擎把它当普通 BRK 异常，QEMU 根本不知道，gdbstub
                       收不到 stop reply。
  2. gdbstub 写内存    连上后必须先 `?` 拿 stop reply，否则 `m`/`M` 无响应。
                       先写代码页（要失效），再写 mailbox（数据页，不失效）。
  3. QMP `cont`        放行，guest 自己会继续。
"""
import json
import socket
import sys
import time


def csum(payload: str) -> str:
    return "%02x" % (sum(payload.encode()) & 0xFF)


class Qmp:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for _ in range(60):
            try:
                self.s.connect(path)
                break
            except OSError:
                time.sleep(0.2)
        else:
            raise SystemExit("cannot connect to QMP at %s" % path)
        self.f = self.s.makefile("rwb")
        self.f.readline()
        self.f.write(b'{"execute":"qmp_capabilities"}\n')
        self.f.flush()
        time.sleep(0.3)

    def run(self, cmd, wait=0.6):
        self.f.write((json.dumps({"execute": cmd}) + "\n").encode())
        self.f.flush()
        time.sleep(wait)
        self.s.settimeout(0.4)
        try:
            while True:
                if not self.f.readline():
                    break
        except Exception:
            pass


class Gdb:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        for _ in range(60):
            try:
                self.s.connect(path)
                break
            except OSError:
                time.sleep(0.2)
        else:
            raise SystemExit("cannot connect to gdbstub at %s" % path)
        self.s.settimeout(2.5)

    def _ack(self):
        try:
            while True:
                d = self.s.recv(1)
                if not d or d in (b"+", b"-"):
                    return
        except socket.timeout:
            return

    def send(self, payload: str):
        self.s.sendall(("$%s#%s" % (payload, csum(payload))).encode())
        self._ack()

    def cmd(self, payload: str) -> str:
        self.send(payload)
        buf = b""
        end = time.time() + 2.5
        while time.time() < end:
            try:
                d = self.s.recv(4096)
            except socket.timeout:
                break
            if not d:
                break
            buf += d
            if b"$" in buf and b"#" in buf:
                body = buf.split(b"$", 1)[1]
                if len(body) >= 3:
                    return body.split(b"#", 1)[0].decode(errors="replace")
        return ""

    def read_mem(self, addr: int, length: int) -> bytes:
        try:
            return bytes.fromhex(self.cmd("m%x,%x" % (addr, length)))
        except ValueError:
            return b""

    def write_mem(self, addr: int, data: bytes):
        self.send("M%x,%x:%s" % (addr, len(data), data.hex()))


def main():
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    qpath, gpath = sys.argv[1], sys.argv[2]
    fn, mb = int(sys.argv[3], 16), int(sys.argv[4], 16)

    q = Qmp(qpath)
    print("QMP stop")
    q.run("stop", wait=1.2)

    # gdbstub 只在 VM 真正停下之后才处理包。QMP stop 是同步的，但 gdbstub
    # 自己的状态机还要一点时间；连上后立刻发 `?` 会拿到空响应，看起来像
    # "读不到内存"，其实是包在 VM 停下之前就到了。
    g = Gdb(gpath)
    reply = ""
    for attempt in range(10):
        reply = g.cmd("?")
        if reply.startswith(("T", "S", "W")):
            break
        time.sleep(0.4)
    print("gdb stop reply: %r (attempt %d)" % (reply[:30], attempt + 1))
    if not reply.startswith(("T", "S", "W")):
        print("inject: gdbstub never answered", file=sys.stderr)
        return 1

    before = g.read_mem(fn, 4)
    print("before: fn[%#x] = %s" % (fn, before.hex() if before else "?"))
    if not before:
        print("inject: cannot read target memory", file=sys.stderr)
        return 1

    patch = bytes.fromhex("40448452")          # movz w0, #0x2222
    g.write_mem(fn, patch)
    after = g.read_mem(fn, 4)
    print("after : fn[%#x] = %s" % (fn, after.hex() if after else "?"))
    if after != patch:
        print("inject: CODE WRITE DID NOT LAND", file=sys.stderr)
        return 1

    # 数据页的写：必须落地，但不需要失效 —— 钩子只看 code_pages 位图
    g.write_mem(mb, b"\x01\x00\x00\x00")
    chk = g.read_mem(mb, 4)
    print("mailbox[%#x] = %s" % (mb, chk.hex() if chk else "?"))
    if chk != b"\x01\x00\x00\x00":
        print("inject: MAILBOX WRITE DID NOT LAND", file=sys.stderr)
        return 1

    print("QMP cont")
    q.run("cont")
    return 0


if __name__ == "__main__":
    sys.exit(main())
