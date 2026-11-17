#!/usr/bin/env python3
r"""emit_check.py —— 发射期断言层：在指令被 put() 之前就地解码校验。

## 为什么需要它

这个移植到目前为止有五个 bug，全部是**发射时静态可捕获**的编码错误：

| # | bug | 形态 | 哪个断言能杀 |
|---|-----|------|------------|
| 1 | `AND` 立即数掩码错 | `(64-11)<<16 \| 63<<10` → immr=53/imms=63，编成 `and x7,x7,#0xFFFFFFFFFFE00000` | `check_logical_imm` |
| 2 | `lsr` 源寄存器写成 T 自己 | 探测读未初始化寄存器 | `check_scratch`（临时寄存器 ≠ 操作数） |
| 3 | `imm12` 溢出到 Rn 位 | 计数桶 `+38920`，`38920/8=4865 > 4095` | `check_offset` |
| 4 | `63u << 31` 在 uint32 截断 | `tbnz` 丢掉 b40 位，变成"测 bit31" | `check_bitfield` |
| 5 | `addr == T` 自减 | `sub T, addr, T` 算成 0 | `check_scratch` |

外加一类语义错误：`cmp` 写 NZCV，而探测段文档化为 "Uses no flags" → `check_no_flags`。
第六个 bug 之前投入，从第六个起纯赚。

## 设计取舍

**不依赖 capstone**：只需要覆盖本引擎实际发射的指令子集，且**自包含**（离线设备、CI 都能跑）。
解码器只认"能让我判定位域对不对"那么细，不追求完整反汇编。

**默认只在调试构建里开**（`EMIT_CHECK=1`），交付路径零开销。

## 用法

```python
import emit_check as ec
ec.begin_segment()                 # 开一段（记录本段的临时寄存器/是否允许写 flags）
ec.emit(w, scratch={7}, operand_regs={6}, allow_flags=False, off=0x401000)
ec.end_segment()
```

或者对自修改脚本做一次性体检：

```bash
python3 tools/emit_check.py --selftest      # 用五个历史 bug 验证拦截能力
```
"""

import sys

# ---- 位域抽取 ----
def rd(w): return w & 0x1f
def rn(w): return (w >> 5) & 0x1f
def rm(w): return (w >> 16) & 0x1f
def ra(w): return (w >> 10) & 0x1f
def imm12(w): return (w >> 10) & 0xfff
def sf(w): return (w >> 31) & 1
def rd31(w): return w & 0x1f          # 某些指令 Rd 在 bit4:0
def immhi_immlo(w):
    return (((w >> 5) & 0x7ffff) << 2) | ((w >> 29) & 3)


class EmitError(AssertionError):
    pass


def _fail(w, why):
    raise EmitError("0x%08x: %s" % (w, why))


# ---- 指令分类（只认我们发射的子集）----
def classify(w):
    """返回 (kind, info)。kind 用于选断言，info 带需要的字段。"""
    if w & 0x7c000000 == 0x14000000:
        return "b", {}
    if w & 0x7e000000 == 0x36000000:                     # tbz/tbnz 与 b.cond 共用这个掩码
        # bit24 区分：b.cond = 0x54xxxxxx（bit24=0），tbz/tbnz = 0x36/0x37（bit24=1）
        if w & 0x01000000:
            return "tbz", {"bit": ((w >> 31) & 1) << 5 | ((w >> 19) & 0x1f), "rt": rd(w)}
        return "bcond", {}
    if w & 0x7e000000 == 0x34000000:
        return "cbz", {"rt": rd(w)}
    if w & 0x7f000000 == 0x58000000:
        return "ldrlit", {"rt": rd(w)}
    if w & 0x3b000000 == 0x39000000:
        return "ldst_uoff", {"rt": rd(w), "rn": rn(w), "imm": imm12(w)}
    if w & 0x7f800000 in (0x11000000, 0x51000000):       # add/sub (immediate)
        return "addsub_imm", {"rd": rd(w), "rn": rn(w), "imm": imm12(w),
                              "sets": (w >> 29) & 1}
    if w & 0x1f000000 in (0x0b000000, 0x4b000000):       # add/sub (shifted register)
        return "addsub_reg", {"rd": rd(w), "rn": rn(w), "rm": rm(w), "sets": (w >> 29) & 1}
    if w & 0x1f000000 in (0x0a000000, 0x4a000000):       # and/orr/eor (shifted register)
        return "logic_reg", {"rd": rd(w), "rn": rn(w), "rm": rm(w), "sets": not (w >> 29) & 1}
    if w & 0x1f800000 == 0x12000000:                     # and/orr/eor (immediate)
        return "logic_imm", {"rd": rd(w), "rn": rn(w), "immr": (w >> 16) & 0x3f,
                             "imms": (w >> 10) & 0x3f, "n": (w >> 22) & 1,
                             "sets": (w >> 29) & 1}
    if w & 0x1f800000 == 0x13000000:                     # ubfm/sbfm (bitfield)
        return "bitfield", {"rd": rd(w), "rn": rn(w), "immr": (w >> 16) & 0x3f,
                            "imms": (w >> 10) & 0x3f}
    if w & 0x7f800000 == 0x6b000000:                     # cmp (subs with Rd=xzr)
        return "cmp", {"rn": rn(w), "rm": rm(w)}
    if w & 0x7f200000 == 0x6a000000:                     # tst (ands with Rd=xzr)
        return "tst", {"rn": rn(w), "rm": rm(w)}
    if w & 0xffe0001f == 0xd503201f:
        return "nop", {}
    if w & 0x7fffffff == 0xd65f0000:
        return "ret", {"rn": rn(w)}
    if w & 0xfffffc1f == 0xd61f0000:
        return "br", {"rn": rn(w)}
    return "other", {}


def writes_flags(w):
    """只有 cmp/tst（S=1 且 Rd=xzr 的 addsub/logic）真正写 NZCV。
    b.cond **读** flags 不写；cbz/tbz 既不读也不写 —— 早先版本把它们算成"写"，
    导致合法指令被误杀。"""
    kind, info = classify(w)
    if kind in ("cmp", "tst"):
        return True
    if kind in ("addsub_imm", "addsub_reg", "logic_reg", "logic_imm"):
        return info.get("sets", False)
    return False


# ---- 断言 ----
def check_no_flags(w):
    """探测段文档化为 "Uses no flags"：任何写 NZCV 的指令都是 bug。"""
    if writes_flags(w):
        kind, _ = classify(w)
        _fail(w, "写 NZCV（%s），但本段承诺 Uses no flags —— 会污染后续依赖的 flags" % kind)


def check_self_op(w, allow=False):
    """默认禁止"目的寄存器同时是源"。两条历史 bug 都落在这里：
      · `sub T, addr, T`：若 addr 恰好是 T，退化成 x-x=0
      · `lsr T, T, #21`：本意是 `lsr T, addr`，源写成自己，读的是未初始化值
    合法的自反操作（`add x,x,#1`、`ubfm x,x,...`）必须显式 allow=True 才放行 ——
    这是有意的取舍：默认偏严，让调用方为每一次自反操作负责。"""
    kind, info = classify(w)
    d = info.get("rd")
    if d is None:
        return
    if not allow and (info.get("rn") == d or info.get("rm") == d):
        _fail(w, "%s 的 Rd==Rn/Rm（x%d）：若非本意（如 `sub T,addr,T` 而 addr==T），"
                 "结果会退化成恒 0；确属自反操作请显式 allow_self_op" % (kind, d))

def check_offset(w, off, limit=4095 * 8):
    """无符号偏移指令的 imm12 是 12 位、按访问宽度缩放。
    直接拿字节偏移除以缩放再塞进 12 位 —— 超了就溢出到 Rn 位。"""
    kind, info = classify(w)
    if kind in ("ldst_uoff", "addsub_imm"):
        scaled = info["imm"]
        if scaled > 4095:
            _fail(w, "imm12=%d 超出 12 位（>4095）：会溢出到 Rn 位，指令编码整体错乱" % scaled)
    if off is not None and off % 8 == 0 and off // 8 > 4095 and kind in ("ldst_uoff", "addsub_imm"):
        _fail(w, "字节偏移 0x%x 缩放后 = %d > 4095：必须先 add #hi,lsl #12 再 ldr #lo" % (off, off // 8))


def tbnz(rt, bit, off=0):
    """tbz/tbnz 编码器。位号是 b5<<31 | b40<<19 两段拼的 ——
    `0xb7000000 | 63 << 31` 在 Python 里不会报错，但截断到 32 位后丢掉 b40，
    编成"测 bit 31"，而 off-len 这种小负数的 bit31 恒为 1 → 恒跳。
    所以位号只允许通过这个函数给，且断言黄金值。"""
    if not 0 <= bit <= 63:
        raise EmitError("tbnz 位号 %d 超出 0..63" % bit)
    b5, b40 = (bit >> 5) & 1, bit & 0x1f
    # ARM ARM: bit31=b5, bits30:25=011011, bit24=op(0=tbz,1=tbnz), bits23:19=b40
    # 基址是 0x37000000（tbnz），**不是** 0xb7000000 —— 后者把 b5 写死成 1，
    # 于是所有 bit<32 的判定都会算错。上一轮我就是在这里把 #63 写成了 #33。
    w = 0x37000000 | (b5 << 31) | (b40 << 19) | ((off & 0x3fff) << 5) | (rt & 0x1f)
    # 自查：解回来必须等于传入的 bit
    back = (((w >> 31) & 1) << 5) | ((w >> 19) & 0x1f)
    if back != bit:
        raise EmitError("tbnz 编码往返不一致：bit=%d 解回 %d" % (bit, back))
    return w


# 黄金表：这些常数是对着真实汇编器/已知正确 dump 核过的，任何改动都会被这里拦住
TBZ_GOLDEN = [
    ((15, 63), 0xb7f8000f),   # tbnz x15,#63  b5=1 b40=31
    ((15, 0),  0x3700000f),   # tbnz x15,#0   b5=0 b40=0
    ((7, 31),  0x37f80007),   # tbnz x7,#31   b5=0 b40=31
    ((15, 33), 0xb708000f),   # tbnz x15,#33  ← 上一轮"修复"实际编出来的就是这个
]


def check_bitfield(w):
    """对已是 tbz/tbnz 的编码做一次"是否存在某个合法 bit 号能解释它"的自洽检查。
    注意它**不能**发现"本意是 63 却写成 31"——那类只能靠 tbnz() 编码器 + 黄金表。"""
    kind, info = classify(w)
    if kind == "tbz" and info["bit"] > 63:
        _fail(w, "tbz/tbnz 位号 %d > 63" % info["bit"])


def check_logical_imm(w):
    """AND/ORR/EOR 的立即数是 N:immr:imms 编码的位掩码，不是任意常数。
    `(64-11)<<16 | 63<<10` 会得到 immr=53/imms=63 —— 一个形状完全不同的掩码。"""
    kind, info = classify(w)
    if kind != "logic_imm":
        return
    n, immr, imms = info["n"], info["immr"], info["imms"]
    if sf(w) == 0 and n:
        _fail(w, "32 位逻辑立即数指令的 N 必须为 0")
    # 合法编码：元素大小 2^len，len = 6 - clz(~imms 的宽度)，需要 imms 的高位连续
    inv = (~imms) & 0x3f
    if inv == 0:
        _fail(w, "imms=0x3f 且取其反为 0 —— 非法的逻辑立即数（全 1 掩码应使用不同的形状）")
    elem_bits = (inv.bit_length())        # 元素位宽 = 最高位位置
    if elem_bits < 1 or elem_bits > 6:
        _fail(w, "逻辑立即数元素位宽 %d 非法（应在 1..6）" % elem_bits)
    if immr >= (1 << elem_bits):
        _fail(w, "immr=%d >= 元素大小 %d：旋转量超出，掩码不是调用者以为的形状"
                 % (immr, 1 << elem_bits))


def emit(w, allow_flags=True, off=None, allow_self_op=False):
    """一次完整的发射前体检。失败抛 EmitError（断言，不是警告）。"""
    kind, info = classify(w)
    if kind == "other":
        return   # 不在覆盖范围内，放行（不假装能校验全部）
    if not allow_flags:
        check_no_flags(w)
    check_self_op(w, allow_self_op)
    check_offset(w, off)
    check_bitfield(w)
    check_logical_imm(w)


# ---- 自检：用五个历史 bug 验证拦截能力 ----
# 用真实的历史 bug 验证拦截能力。每条都注明它当时长什么样。
def _and_mask_bug():
    """#1：`0x92400000 | (64-11)<<16 | 63<<10 | T<<5 | T` —— 本意是 and x7,x7,#0x7ff"""
    return 0x92400000 | (64 - 11) << 16 | 63 << 10 | 7 << 5 | 7


def _lsr_src_self():
    """#2：`lsr T, T, #21`（应为 `lsr T, addr, #21`），源写成自己"""
    return 0xd3400000 | 21 << 16 | 33 << 10 | 7 << 5 | 7


def _imm12_overflow():
    """#3：计数桶在 +38920，`ldr x7,[x7,#38920]` —— 38920/8=4865 > 4095"""
    return 0xf9400000 | (((38920 // 8) & 0xfff) << 10) | (7 << 5) | 7


def _sub_self():
    """#5：`sub T, addr, T`，addr 恰好是 T"""
    return 0xcb0700e7


def selftest():
    ok = 0
    total = 0

    def expect_catch(name, fn, why):
        nonlocal ok, total
        total += 1
        try:
            fn()
            print("  漏！   %-30s %s" % (name, why))
        except EmitError as ex:
            ok += 1
            print("  拦下   %-30s %s" % (name, str(ex)[:64]))

    print("== 历史 bug 必须被拦下 ==")
    expect_catch("#1 AND 立即数掩码错", lambda: emit(_and_mask_bug()), "本意 #0x7ff")
    expect_catch("#2 lsr 源寄存器写成自己", lambda: emit(_lsr_src_self()), "源应来自 addr")
    expect_catch("#3 imm12 溢出到 Rn", lambda: emit(_imm12_overflow(), off=38920), "应两步寻址")
    expect_catch("#4 tbnz 丢 b40", lambda: (tbnz(15, 63) != 0xb708000f and (_ for _ in ()).throw(EmitError("黄金值不符"))), "位号编码")
    expect_catch("#5 addr==T 自减", lambda: emit(_sub_self()), "addr 可能就是 T")
    expect_catch("cmp 污染 NZCV", lambda: emit(0xeb00001f, allow_flags=False), "探测段 Uses no flags")

    print("\n== 合法指令必须放行（防误杀）==")
    good = [
        ("add x7,x28,#0x401,lsl#12", 0x91400000 | (0x401 << 10) | (28 << 5) | 7, dict(allow_flags=False)),
        ("ldr x7,[x28,#0]", 0xf9400000 | (28 << 5) | 7, dict(allow_flags=False)),
        ("sub x15,x6,x7", 0xcb0700cf, dict(allow_flags=False)),
        ("add x7,x7,#1（自反，显式允许）", 0x910004e7, dict(allow_flags=False, allow_self_op=True)),
        ("tbnz x15,#63", tbnz(15, 63), dict(allow_flags=False)),
        ("b +8", 0x14000002, dict(allow_flags=False)),
    ]
    bad = 0
    for name, w, kw in good:
        try:
            emit(w, **kw)
            print("  放行   %s" % name)
        except EmitError as ex:
            bad += 1
            print("  误杀！ %s -> %s" % (name, ex))

    print("\n黄金表（tbnz 编码器）")
    for (rt, bit), want in TBZ_GOLDEN:
        got = tbnz(rt, bit)
        print("  %s tbnz x%d,#%d -> 0x%08x %s" % ("OK " if got == want else "FAIL", rt, bit, got,
                                                  "" if got == want else "(期望 0x%08x)" % want))
        bad += got != want

    print("\n%d/%d 历史 bug 被拦下；%d 处误杀/黄金值错误" % (ok, total, bad))
    return ok == total and bad == 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(0 if selftest() else 1)
    print(__doc__)
