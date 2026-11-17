# 移植层补丁（port-android/patches/）

## 这里放什么

**我们对 QEMU 的全部改动，只有这一个文件。**

```
0001-henge-port.patch    55 个文件 / 14556 行 / 672 KB
```

它包含三部分：

| 部分 | 文件数 | 内容 |
|---|---|---|
| 修改上游文件 | 13 | `accel/Kconfig`、`accel/meson.build`、`hw/arm/virt.c`、`meson.build`、`meson_options.txt`、`scripts/meson-buildoptions.sh`、`subprojects/libvhost-user/*.{c,h}`、`system/physmem.c`、`target/arm/{cpu-max.c,cpu.c,helper.c,internals.h}`、`util/oslib-posix.c` |
| 新增加速器 | 39 | `accel/henge/**`（QEMU 侧 half + vendored 引擎） |
| 新增头文件 | 2 | `include/system/henge-accel.h`、`include/system/henge-engine.h` |

## 为什么是 patch 而不是把改动提交进 submodule

| | 提交进 submodule | patch（当前做法） |
|---|---|---|
| 上游关系 | 变成"我们的 fork"，看不出基于哪个 release | 清楚：submodule 钉在 `v11.1.3` |
| 改动可见性 | 埋在 70 万行上游历史里 | `git apply --stat` 一眼看完 |
| 换 qemu 版本 | 要 rebase 一堆 commit | `git apply --3way`，冲突就地解决 |
| 主仓库 `git log` | 混入上游提交 | 只有我们的决定 |
| 改动计数 | 看不出 | 14556 行是硬数字 |

代价：打完补丁后 submodule 是 dirty 的，`git status` 会提示。
这是**正确状态**，不是问题 —— 见下面。

## 用法

```sh
cd port-android/patches

./apply.sh --check    # 只检查：未应用 / 已应用 / 冲突
./apply.sh            # 打补丁（已打过会跳过）
./apply.sh --revert   # 撤回，qemu 回到干净 v11.1.3
```

首次 clone 的完整流程：

```sh
git clone <this-repo> && cd <this-repo>
git submodule update --init --depth 1     # qemu 1.1G，--depth 1 只要快照
port-android/patches/apply.sh
cd src/qemu-mainline && meson setup build && ninja -C build qemu-system-aarch64
```

## 基线钉死在 v11.1.3

`apply.sh` 会校验 `src/qemu-mainline` 的 HEAD 必须是
`005c61c0ef6f6ae615283440b4bb7be51b2c6ddd`（`v11.1.3`）。

**为什么这么硬**：`port-android/QEMU-BACKEND.md` 里从 13.1 到 13.20 的所有测量
都是对着这个版本取的。换了版本，`target/arm/helper.c` 里
`gt_recalc_timer` / `gt_update_irq` 的位置和语义都可能变，而移植层的所有
接线都建在它们上面。悄悄跟着 upstream 走 = 拿没校准的底座测数据。

真要升级：先跑基线四件套，再 `git apply --3way`，然后重测。

## 与 vendored 引擎的关系

`accel/henge/engine/` 是 `src/WindowsiOS` 的 vendored 副本，它自己有一套嵌套机制：

```
accel/henge/engine/
├── VENDORED-FROM            # 记录 upstream repo + commit + vendored 日期
├── local-edits.patch        # 引擎相对 upstream 的 5 处本地改动（541 行）
└── sync-from-upstream.sh    # 从 upstream 刷新；--check 检测漂移
```

所以引擎的改动有**两层**记录：

1. `local-edits.patch` —— 引擎相对 WindowsiOS 的改动
2. 本目录的 `0001-henge-port.patch` —— 那时点的引擎快照（含 local-edits 已应用）

改引擎的正确顺序：

```sh
cd src/qemu-mainline/accel/henge/engine
./sync-from-upstream.sh --check      # 先确认没漂移
# ... 改 core/*.c ...
./sync-from-upstream.sh              # 重新生成 local-edits.patch
# 然后把整个移植层重新导出：
cd src/qemu-mainline && git add -N -f accel/henge include/system/henge-*.h
git diff HEAD --binary > ../../port-android/patches/0001-henge-port.patch
git reset
```

## 已知的坑

| 坑 | 说明 |
|---|---|
| `*.patch` 被 qemu 自己 ignore | `src/qemu-mainline/.gitignore:21` 有 `*.patch`，`accel/henge/engine/local-edits.patch` 会被忽略。导出时要用 `git add -N -f`（`-f` 强制） |
| `git status` 显示 submodule dirty | 正常。移植层就是 dirty 的，撤回用 `./apply.sh --revert` |
| 新增空目录不会被 patch 删除 | `--revert` 后 `accel/henge/engine/compat/{mach,libkern}` 可能残留空目录，脚本里已 `rmdir` |
