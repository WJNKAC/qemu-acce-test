#!/usr/bin/env python3
"""分析 HV_DUMP 导出文件：每个已翻译块的 (guest VA, guest 指令数, 宿主字数)。

test_bench / test_bench_ext 在 HV_DUMP=file 时按下面的格式写：
    uint64 hdr[3] = { guest_va, guest_insns, host_words };
    uint32 guest[guest_insns];
    uint32 host[host_words];

输出：
  - 总放大比（宿主字 / 客机指令）
  - 每个块的放大比分布，按块内是否含 bl / ret 分类
  - 有名字的块（如果给了符号表）可以定位到具体函数

用法： analyze_jit_dump.py dump.bin [--top N]
"""
import struct
import sys
import collections

# AArch64 指令类别粗判（只看我们关心的几个）
def is_bl(w):
    return (w & 0xFC000000) == 0x94000000

def is_b(w):
    return (w & 0xFC000000) == 0x14000000

def is_ret(w):
    return w == 0xD65F03C0 or (w & 0xFFFFFC1F) == 0xD65F0000

def is_ldp_stp(w):
    return (w & 0x3A000000) == 0x28000000

def is_ldr_str(w):
    return (w & 0x3A000000) == 0x38000000


def main():
    path = sys.argv[1]
    topn = 20
    if "--top" in sys.argv:
        topn = int(sys.argv[sys.argv.index("--top") + 1])

    data = open(path, "rb").read()
    off = 0
    blocks = []
    while off + 24 <= len(data):
        va, ninsns, nwords = struct.unpack_from("<QQQ", data, off)
        off += 24
        if ninsns > 4096 or nwords > 100000:
            print("解析失步 @%d: ninsns=%d nwords=%d" % (off, ninsns, nwords))
            break
        g = struct.unpack_from("<%dI" % ninsns, data, off) if ninsns else ()
        off += 4 * ninsns
        off += 4 * nwords
        blocks.append((va, ninsns, nwords, g))

    tg = sum(b[1] for b in blocks)
    th = sum(b[2] for b in blocks)
    print("块数 %d  客机指令 %d  宿主字 %d  放大比 %.2f" % (len(blocks), tg, th, th / max(1, tg)))

    # 分类统计
    cat = collections.defaultdict(lambda: [0, 0, 0])  # 名字 -> [块数, 客机指令, 宿主字]
    for va, ninsns, nwords, g in blocks:
        has_bl = any(is_bl(w) for w in g)
        has_ret = any(is_ret(w) for w in g)
        has_mem = any(is_ldp_stp(w) or is_ldr_str(w) for w in g)
        if has_bl and has_ret:
            k = "含 bl+ret"
        elif has_bl:
            k = "含 bl"
        elif has_ret:
            k = "含 ret"
        elif has_mem:
            k = "纯访存"
        else:
            k = "纯计算/分支"
        c = cat[k]
        c[0] += 1; c[1] += ninsns; c[2] += nwords

    print("\n%-14s %8s %10s %10s %8s" % ("类别", "块数", "客机指令", "宿主字", "放大比"))
    for k, (n, gi, hw) in sorted(cat.items(), key=lambda x: -x[1][2]):
        print("%-14s %8d %10d %10d %8.2f" % (k, n, gi, hw, hw / max(1, gi)))

    print("\n最膨胀的 %d 个块：" % topn)
    print("%-18s %8s %8s %8s" % ("guest VA", "客机", "宿主", "放大"))
    for va, ninsns, nwords, g in sorted(blocks, key=lambda b: -b[2] / max(1, b[1]))[:topn]:
        tags = []
        if any(is_bl(w) for w in g): tags.append("bl")
        if any(is_ret(w) for w in g): tags.append("ret")
        if any(is_ldp_stp(w) or is_ldr_str(w) for w in g): tags.append("mem")
        print("%-18x %8d %8d %8.2f  %s" % (va, ninsns, nwords, nwords / max(1, ninsns), ",".join(tags)))

    print("\n最大的 %d 个块：" % min(topn, 10))
    for va, ninsns, nwords, g in sorted(blocks, key=lambda b: -b[1])[:10]:
        print("%-18x %8d %8d %8.2f" % (va, ninsns, nwords, nwords / max(1, ninsns)))


if __name__ == "__main__":
    main()
