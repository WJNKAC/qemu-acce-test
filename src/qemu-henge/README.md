# src/qemu-henge —— QEMU + henge 的「配方」目录

这里**不放**完整改好的源码（那样仓库里会多出一份 194 MB 的树 + 470 MB 的 .git），
只放三样东西：

| 件 | 作用 |
|---|---|
| `../qemu/` | 上游 QEMU **子模块**，钉在 **v11.1.3（`005c61c0ef`）**，干净检出、不含本地提交。放在 `src/` 顶层是为了让其它加速项目（mvisor/ApplevM/limbo…）共用同一份上游检出 |
| `qemu` | 指向 `../qemu` 的**软链接**（不是目录）。脚本一律用 `$HERE/qemu`，换布局只改这一处 |
| `patches/` | 移植层（4 个 patch，约 880 KB）：`0001` engine、`0002` accel 层、`0003` 上游钩子、`0004` libslirp |
| `apply.sh` | 把 `qemu/` + `patches/` 生成 `work/src`（幂等；patch 序列哈希不变就跳过） |
| `build.sh` | 唯一的 Android/bionic 构建脚本（原 `port-android/build-android.sh` 的实体，那边只是 wrapper） |
| `work/` | 派生树，**gitignore**，可随时删掉重建 |

## 从零复现

```bash
git submodule update --init src/qemu                 # 只拉钉住的提交（浅克隆）；qemu-henge/qemu 是软链接
./apply.sh                                           # qemu/ + patches/ -> work/src
./build.sh --fresh                                   # 产物 /data/qemu-android/build-android/q-henge
```

`apply.sh` 会核对两件事：`qemu/`（经软链接到 `../qemu`）HEAD 必须等于 `005c61c0ef`；patch 序列必须能干净应用
（它把 `0004` 单独打进 `subprojects/slirp`，因为那个 patch 的路径前缀是 slirp 子项目的根）。

## 改代码的正确姿势

1. 改 `work/src/`（派生树），编、测；
2. `./export-patches.sh`（TODO：`git diff` 出增量后并入对应 patch，见下）；
3. 提交 `patches/` 的变化。

当前 4 个 patch 的划分（按路径集合，互不重叠，可任意顺序应用）：

```
0001-henge-engine.patch          accel/henge/engine/**            vendored 引擎（含本地编辑）
0002-henge-accel.patch           accel/henge/*.c、include/system/henge-*.h、meson/Kconfig
0003-henge-upstream-hooks.patch  target/arm/**、system/**、hw/intc/**、hw/arm/virt.c、ui/**、util/** 等
0004-libslirp-dns-env.patch      subprojects/slirp/src/slirp.c（相对 slirp 根，-p1）
```

等价性验证（2026-11-24 做过一次）：把 `0001..0003` 应用到 `005c61c0ef` 的干净 worktree 后
`git write-tree` 的结果 = 原移植树 `fd373e5c5e^{tree}`（`f1e7843b89…`），逐字节一致。
