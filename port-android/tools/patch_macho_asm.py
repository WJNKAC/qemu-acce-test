#!/usr/bin/env python3
"""把原项目的 tests/harness.h 与 *.S 从 Mach-O 语法改写成 ELF 语法。
   只做三件事：
     1. 去掉符号的前导下划线（Mach-O 用 _name，ELF 用 name）——宏里写的是
        反斜杠拼接的 \\name，所以只能按文本替换，正则摸不到。
     2. sym@PAGEOFF  → :lo12:sym
     3. sym@PAGE     → sym
   注意顺序：必须先把 @PAGEOFF 换掉，否则 @PAGE 会被先删掉、留下一个 OFF。
"""
import re
import sys


def convert(text: str) -> str:
    text = re.sub(r',(\s*)([A-Za-z_][A-Za-z_0-9]*)@PAGEOFF', r',\1:lo12:\2', text)
    text = text.replace('@PAGE', '')
    # 宏参数：_\name 与 _\name\()_suffix。
    # 先把 \()_ 里的下划线保护起来——它是名字的一部分，不能被下面那条
    # "去掉前导下划线"的规则吃掉（那样会得到 \name\()end）。
    text = text.replace('\\()_', '\\()__KEEP__')
    # C 侧 token 拼接 n##_native 里的下划线同理必须保留，
    # 否则 DECLARE_PROGRAM() 展开成 bench_callsnative，链接期找不到符号。
    text = text.replace('##_', '##__KEEP__')
    text = re.sub(r'_\\(name)', r'\\\1', text)
    # 普通符号：行首 / .globl / 引用处的 _foo
    text = re.sub(r'(?<![\w$])_([A-Za-z][A-Za-z0-9_]*)(?![\w$])', r'\1', text)
    text = text.replace('__KEEP__', '_')
    return text


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, 'r', encoding='utf-8') as f:
        text = f.read()
    with open(dst, 'w', encoding='utf-8') as f:
        f.write(convert(text))
    return 0


if __name__ == '__main__':
    sys.exit(main())
