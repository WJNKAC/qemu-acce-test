#!/bin/bash
# 从清华镜像取 Termux 的 qemu-user-aarch64（Android/aarch64 原生构建），
# 递归解析依赖、全部下载解包。之所以用 Termux 的包：它是同 ISA 的 TCG
# （aarch64 宿主上跑 aarch64 客户机），而宿主 x86_64 上的 qemu 是跨 ISA，不可比。
set -e
B="https://mirrors.tuna.tsinghua.edu.cn/termux/apt/termux-main"
W="$(dirname "$0")"
cd "$W"
[ -f pk.Packages ] || curl -sSL -o pk.Packages "$B/dists/stable/main/binary-aarch64/Packages"
python3 - <<'PY'
import re, json
pkgs = {}
for b in re.split(r'\n\n', open('pk.Packages').read()):
    m = re.match(r'Package: (\S+)', b)
    if not m: continue
    d = {'name': m.group(1)}
    for line in b.split('\n'):
        if line.startswith('Filename: '): d['file'] = line[10:]
        elif line.startswith('Depends: '):
            d['deps'] = [x.split('(')[0].split('|')[0].strip() for x in line[9:].split(',') if x.strip()]
    pkgs[d['name']] = d
need, todo = set(), ['qemu-user-aarch64']
while todo:
    n = todo.pop()
    if n in need or n not in pkgs: continue
    need.add(n); todo += [x for x in pkgs[n].get('deps', []) if x not in need]
open('files.txt','w').write('\n'.join(pkgs[n]['file'] for n in sorted(need)) + '\n')
print(len(need), 'packages')
PY
mkdir -p debs root
while read -r f; do
  d="debs/$(basename "$f")"
  [ -f "$d" ] || curl -sSL -m 90 -o "$d" "$B/$f"
done < files.txt
for d in debs/*.deb; do dpkg-deb -x "$d" root 2>/dev/null || true; done
echo "qemu: $(ls -l root/data/data/com.termux/files/usr/bin/qemu-aarch64 | awk '{print $5}') bytes"
