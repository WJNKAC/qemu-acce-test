#!/usr/bin/env python3
"""soakreport.py —— 从 soak 的 TSV 出一份可复核的报告。

为什么单独一个工具：这套分析我已经用 heredoc 手写过五六次，每次都要重新
想"哪个列是哪一列""滚动后 round 会回退怎么算累计""RSS 该看哪一列"。
手写就意味着每次都可能有细微差别，而**判据有差别就不是同一把尺**。

用法:
    python3 soakreport.py runs/soak-night2.tsv
    python3 soakreport.py runs/soak-night2.tsv --json

列序（脚本 soak.sh 里是契约，只往后加）：
    1 t_s   2 round   3 rss_statm_kb   4 dsusp_cum
    5 ok    6 refused 7 timeout        8 curl200   9 curl000  10 err
    11 lines 12 df_avail_kb  13 rss_smaps_kb  14 anon_kb  15 threads

关于两种 RSS：第 3 列走 /proc/pid/statm（内核 per-mm 缓存计数器，会漂），
第 13 列走 /proc/pid/smaps_rollup（走页表重算，地面真值）。
13.59 实测同一瞬间两者差 250–300 MB。所以**报告里两个斜率都给**，
并且给出 gap 的斜率 —— gap 涨而 smaps 平，就说明"泄漏"其实是计数器漂移。
"""
import sys
import statistics


def load(path):
    rows = []
    with open(path) as f:
        for ln in f:
            p = ln.split()
            # 老 TSV 只有 12 列（13.59 之前），新的是 15 列。两者都要能读，
            # 否则"用同一把尺量前后两次"这件事做不到。
            if len(p) < 12 or not p[0].isdigit():
                continue
            r = {
                "t": int(p[0]), "rnd": int(p[1]), "statm": int(p[2]),
                "dsusp": int(p[3]), "ok": int(p[4]), "ref": int(p[5]),
                "to": int(p[6]), "c200": int(p[7]), "c000": int(p[8]),
                "err": int(p[9]), "lines": int(p[10]), "df": int(p[11]),
            }
            # 13 列之后是 13.59 才加的，老 TSV 没有 —— 缺就是 None，不要补 0
            r["smaps"] = int(p[12]) if len(p) > 12 and p[12].isdigit() else None
            r["anon"] = int(p[13]) if len(p) > 13 and p[13].isdigit() else None
            r["thr"] = int(p[14]) if len(p) > 14 and p[14].isdigit() else None
            rows.append(r)
    return rows


def cumulative_rounds(rows):
    """round 列是窗口局部的（日志滚动后从 0 重数），不是累计。
    每次回退都是滚动：累计 = 回退前峰值 + 回退后的增量。"""
    if not rows:
        return 0, []
    drops = []
    for i in range(1, len(rows)):
        if rows[i]["rnd"] < rows[i - 1]["rnd"]:
            drops.append((rows[i - 1]["rnd"], rows[i]["rnd"], rows[i]["t"]))
    if not drops:
        return rows[-1]["rnd"], drops
    peak, after, _ = drops[-1]
    return peak + (rows[-1]["rnd"] - after), drops


def slope(pts):
    """最小二乘，返回 (斜率, 标准误, t 值)。pts = [(x, y)]"""
    n = len(pts)
    if n < 3:
        return None
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return None
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    b = sxy / sxx
    resid = [y - (my + b * (x - mx)) for x, y in zip(xs, ys)]
    s = (sum(r * r for r in resid) / (n - 2)) ** 0.5
    se = s / (sxx ** 0.5)
    return b, se, (b / se if se else 0.0)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    rows = load(path)
    if not rows:
        print("没有可解析的行")
        return 1

    total, drops = cumulative_rounds(rows)
    dur = rows[-1]["t"] / 3600.0
    print("=== soak 报告 %s ===" % path)
    print("样本 %d，时长 %.2f h，累计轮次 %d（平均轮间隔 %.1f s）"
          % (len(rows), dur, total, rows[-1]["t"] / max(total, 1)))
    if drops:
        print("日志滚动 %d 次：" % len(drops))
        for p, a, t in drops:
            print("  t=%6ds  round %d -> %d" % (t, p, a))

    # 判据：取每列的最大值（它们是单调计数器，窗口局部滚动见上）
    def mx(k):
        return max(r[k] for r in rows)
    print("\n=== 判据（全程最大值，含滚动前窗口） ===")
    print("  ok=%d  refused=%d  timeout=%d  curl200=%d  curl000=%d  err=%d"
          % (mx("ok"), mx("ref"), mx("to"), mx("c200"), mx("c000"), mx("err")))
    print("  dsusp_cum=%d ms  %s" % (rows[-1]["dsusp"],
                                    "VALID" if rows[-1]["dsusp"] < 1000 else "INVALID"))
    if mx("to"):
        print("  ⚠ 有 timeout：按 round 分布定性（前段=warm-up / 分散=竞态 / 后段=累积）")
        bad = [r["rnd"] for r in rows if r["to"] > 0][:10]
        print("    首次出现的轮次样本：", bad)

    # RSS：稳态段（跳过起始阶跃）分别给 statm / smaps / gap 的斜率
    print("\n=== RSS（稳态 t>%.1f h） ===" % 0.5)
    st = [r for r in rows if r["t"] > 1800]
    if len(st) < 10:
        print("  稳态样本不足（%d），跳过" % len(st))
    else:
        for name, key in (("statm（soak 第3列）", "statm"),
                          ("smaps（地面真值）", "smaps"),
                          ("anon", "anon"),
                          ("threads", "thr")):
            pts = [(r["t"] / 3600.0, r[key] / 1024.0) for r in st if r[key] is not None]
            res = slope(pts)
            if not res:
                print("  %-18s 无数据" % name)
                continue
            b, se, t = res
            vals = [y for _, y in pts]
            print("  %-18s 均值 %7.1f MB  极差 %5.2f%%  斜率 %+6.2f MB/h (SE %.2f, t=%+.1f)"
                  % (name, statistics.mean(vals),
                     (max(vals) - min(vals)) / statistics.mean(vals) * 100, b, se, t))
        # gap = statm - smaps
        gpts = [(r["t"] / 3600.0, (r["statm"] - r["smaps"]) / 1024.0)
                for r in st if r["smaps"] is not None]
        res = slope(gpts)
        if res:
            b, se, t = res
            gv = [y for _, y in gpts]
            print("  %-18s 均值 %7.1f MB  极差 %5.2f%%  斜率 %+6.2f MB/h (SE %.2f, t=%+.1f)"
                  % ("gap=statm-smaps", statistics.mean(gv),
                     (max(gv) - min(gv)) / max(abs(statistics.mean(gv)), 1e-9) * 100, b, se, t))
            print("\n  读法：若 gap 斜率 ≈ statm 斜率 且 smaps 斜率 ≈ 0，")
            print("        则所谓的'RSS 增长'是 statm 计数器漂移，不是真实占用。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
