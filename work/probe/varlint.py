#!/usr/bin/env python3
"""
varlint - 检查 shell 脚本里"未赋值就被引用"的大写变量

为什么需要：这些脚本都是 `set -u`，未赋值变量会直接 FATAL 并打断后续逻辑。
而且它**不会在 dash -n 阶段暴露** —— dash -n 只查语法，不查变量。
本项目已经因此栽过三次：
  1. seedtest.sh 的 PASST_ADDR（补丁只插了注释漏了赋值）
  2. seedtest.sh 的 MILE（从 nrun2.sh 抄过来的变量，本脚本根本没有）
  3. （同类的）END < BEGIN 被误读成"探针半途死"

检查方法：把所有 `$VAR` / `${VAR}` 引用与所有赋值点（`VAR=`、`for VAR`、
`${VAR:-默认}`）做差集。`${VAR:-x}` 形式视为已赋值。

用法：varlint.py [文件...]        默认检查同目录 *.sh
"""
import re
import sys
import glob
import os

ENV_OK = {"HOME", "PATH", "IFS", "PPID", "RANDOM", "UID", "PWD", "LINENO", "OPTARG"}

REF_RE = re.compile(r"\$\{?([A-Z][A-Z0-9_]*)\}?")
DEFAULT_RE = re.compile(r"\$\{([A-Z][A-Z0-9_]*)(:?[-=+?])")
ASSIGN_RE = re.compile(r"(?:^|[;\s])([A-Z][A-Z0-9_]*)(?:\+|:)?=")
FOR_RE = re.compile(r"\s*for\s+([A-Z][A-Z0-9_]*)\s")
READ_RE = re.compile(r"\s*read\s+(?:-\w+\s+)*([A-Z][A-Z0-9_]*)")


def check(path):
    src = open(path, encoding="utf-8", errors="replace").read()
    used, assigned = {}, set()
    for i, ln in enumerate(src.split("\n"), 1):
        stripped = ln.strip()
        if stripped.startswith("#"):
            continue
        # ${VAR:-default} / ${VAR:=...} 算已赋值
        for m in DEFAULT_RE.finditer(ln):
            assigned.add(m.group(1))
        for m in REF_RE.finditer(ln):
            used.setdefault(m.group(1), []).append(i)
        for m in ASSIGN_RE.finditer(ln):
            assigned.add(m.group(1))
        m = FOR_RE.match(ln)
        if m:
            assigned.add(m.group(1))
        m = READ_RE.match(ln)
        if m:
            assigned.add(m.group(1))
    return {k: v for k, v in used.items() if k not in assigned and k not in ENV_OK}


def main(argv):
    files = argv[1:]
    if not files:
        files = sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), "*.sh")))
    bad = 0
    for f in files:
        miss = check(f)
        if miss:
            bad += 1
            print(f"{f}:")
            for k, v in sorted(miss.items()):
                print(f"   ${k}  行 {v[:6]}")
        else:
            print(f"{os.path.basename(f)}: OK")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
