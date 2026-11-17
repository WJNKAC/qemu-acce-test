#!/usr/bin/env python3
"""Exact accounting of QEMU -d in_asm / -d out_asm logs (OBJD hex-dump format).

in_asm  :  OBJD-T lines = guest code words (LE 32-bit)
out_asm :  OBJD-H lines = host code words, grouped into regions by the
           "-- guest addr X" / "-- tb slow paths" / "data:" comments.

Goal: separate the *per-TB fixed cost* (prologue + slow paths + padding)
from the *per-guest-instruction variable cost*.
"""
import re
import sys
import collections

WORD_RE = re.compile(r"^[0-9a-fA-F]{8}$")


def words(line):
    h = line.rstrip("\n").split(":", 1)[1].strip()
    if len(h) % 8:
        raise SystemExit("odd hex length: %r" % h[:40])
    return [h[i:i + 8] for i in range(0, len(h), 8)]


def parse_inasm(path):
    tb = 0
    guest_insns = 0
    tb_sizes = []
    cur = 0
    with open(path, "r", errors="replace") as f:
        for line in f:
            if line.startswith("IN:"):
                if tb:
                    tb_sizes.append(cur)
                tb += 1
                cur = 0
            elif line.startswith("OBJD-T:"):
                n = len(words(line))
                cur += n
                guest_insns += n
    if tb:
        tb_sizes.append(cur)
    return tb, guest_insns, tb_sizes


def parse_outasm(path):
    """Returns counters split by region + per-TB list."""
    region = None            # 'prologue' | 'body' | 'slow' | 'data'
    n_tb = 0
    acc = collections.Counter()   # region -> host words
    per_tb = []                   # list of dict(region->words)
    cur = None
    with open(path, "r", errors="replace") as f:
        for line in f:
            if line.startswith("OUT:") or line.startswith("PROLOGUE:"):
                if cur is not None:
                    per_tb.append(cur)
                cur = collections.Counter()
                n_tb += 1
                region = "prologue"
            elif line.lstrip().startswith("-- guest addr"):
                region = "body"
            elif line.lstrip().startswith("-- tb slow paths"):
                region = "slow"
            elif line.lstrip().startswith("data:"):
                region = "data"
            elif line.startswith("OBJD-H:"):
                n = len(words(line))
                if cur is None:
                    cur = collections.Counter()
                cur[region or "prologue"] += n
                acc[region or "prologue"] += n
    if cur is not None:
        per_tb.append(cur)
    return n_tb, acc, per_tb


def stats(nums):
    s = sorted(nums)
    n = len(s)
    if not n:
        return (0, 0, 0, 0, 0, 0)
    mean = sum(s) / n
    def pct(p):
        return s[min(n - 1, int(p * n))]
    return (n, s[0], mean, pct(0.5), pct(0.9), s[-1])


def main():
    inpath, outpath = sys.argv[1], sys.argv[2]

    tb, ginsns, sizes = parse_inasm(inpath)
    print("=== in_asm ===")
    print("TB count                 : %d" % tb)
    print("guest instructions       : %d" % ginsns)
    print("guest insns / TB         : %.3f" % (ginsns / tb))
    n, mn, mean, med, p90, mx = stats(sizes)
    print("TB size min/mean/med/p90/max : %d / %.2f / %d / %d / %d" % (mn, mean, med, p90, mx))
    dist = collections.Counter(sizes)
    print("TB size histogram (size:count, cumulative %):")
    cum = 0
    for k in sorted(dist):
        cum += dist[k]
        print("   %2d : %6d  (%5.1f%%)" % (k, dist[k], 100.0 * cum / tb))
    print("mean guest insns/TB = %.3f  ->  TB entries per 1M guest insns = %.0f"
          % (ginsns / tb, 1e6 / (ginsns / tb)))

    print()
    print("=== out_asm ===")
    n_tb2, acc, per_tb = parse_outasm(outpath)
    print("emitted code chunks      : %d" % n_tb2)
    for k in ("prologue", "body", "slow", "data"):
        print("  %-9s host words : %8d  (%.1f%%)" % (k, acc[k], 100.0 * acc[k] / max(1, sum(acc.values()))))
    host_insns = acc["prologue"] + acc["body"] + acc["slow"]
    print("host instructions total  : %d" % host_insns)
    print("host / guest (static)    : %.2f" % (host_insns / ginsns))

    # per-TB fixed cost = prologue + slow paths (+ alignment nops inside slow)
    fixed = [c["prologue"] + c["slow"] for c in per_tb]
    body = [c["body"] for c in per_tb]
    n, mn, mean, med, p90, mx = stats(fixed)
    print()
    print("--- per-TB FIXED cost (prologue + slow paths) ---")
    print("count %d  min %d  mean %.2f  median %d  p90 %d  max %d" % (n, mn, mean, med, p90, mx))
    n2, bmn, bmean, bmed, bp90, bmx = stats(body)
    print("--- per-TB BODY  (translated guest code)       ---")
    print("count %d  min %d  mean %.2f  median %d  p90 %d  max %d" % (n2, bmn, bmean, bmed, bp90, bmx))

    # What fraction of *executed* host instructions is fixed cost, if the code
    # is assumed to run uniformly proportional to its static size?
    tot_fixed = sum(fixed)
    tot_body = sum(body)
    print()
    print("aggregate: fixed=%d body=%d -> fixed share of static host code = %.1f%%"
          % (tot_fixed, tot_body, 100.0 * tot_fixed / (tot_fixed + tot_body)))
    gpt = ginsns / n_tb2 if n_tb2 else 0
    if gpt:
        print("fixed host insns per guest insn = %.2f  (%.1f host insns fixed per TB / %.2f guest insns per TB)"
              % (mean / gpt, mean, gpt))


if __name__ == "__main__":
    main()
