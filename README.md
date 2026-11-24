# qemu-acce —— ARM64 直通翻译器（henge 引擎）的 Android/Linux 移植 + QEMU 加速器

两件交付物共用一个引擎：

1. **引擎移植（hv-linux）**：把 `src/WindowsiOS`（Apple Silicon 上跑 Windows ARM64 的
   ARM64→ARM64 直通翻译器）搬到 Android/Linux，直接跑完整 Linux aarch64 客户机
   ——不需要 KVM、不需要 root。
2. **QEMU 加速器（`-accel henge`）**：把同一引擎嫁接进 QEMU 11.1.3，作为 `-accel henge`
   运行标准 `qemu-system-aarch64` 命令行；GIC 最终由引擎作唯一所有者
   （`HENGE_GIC_AUTHORITY=1`），架构对标 KVM：vCPU 状态单所有者、PSCI 在引擎内、
   CPU_ON = reset + kick、GIC 单所有者。

性能（引擎直跑、同一台设备）：

- 相对原生：`alu` 1.01×、`call` 1.88×、`real` 3.5×（几何平均 62% 原生）。
- 相对 QEMU TCG：几何平均 **快 3.4 倍**，`real` 快 6–12 倍，冷启动 **4.2–5.1 倍**，
  到 systemd 就绪 **7.4 倍**。
- 有 root + `/dev/kvm` 时和 KVM 正面对比过：**KVM 1.002× 原生，本加速器 52% 原生，
  TCG 16% 原生**（见 [docs/KVM-VS-ENGINE.md](docs/KVM-VS-ENGINE.md)）。
- QEMU 加速器形态：UEFI-INTx 病人 time-to-GDM 69–71 s（smp2）/ 82.7 s（smp4），
  TCG 同病人 373 s；并行扩展在 4 大核设备上 P4=3.16–3.50（原生 3.33–3.44）。

## 目录

```
qemu-acce/
├── src/                     上游参考实现（子模块，内容不入库）
│   ├── qemu/                  QEMU 11.1.3（005c61c0ef）——加速器的上游，多项目共用
│   ├── qemu-henge/            QEMU+henge 的「配方」：qemu 软链接 + patches/ + apply.sh + build.sh
│   ├── WindowsiOS/            原项目：Apple Silicon 上的 iOS/Windows 版（引擎 vendored 来源）
│   └── WindowsPixel/          另一个移植（Pixel 9 / DGX Spark），libslirp 从这里借
├── labs/                    实验记录：STATE-2026-11-19.md（逐轮证据）、recon/（语料/墙/并行基准脚本）、
│                            snapshot/、logs/
├── docs/                    分析与说明：设计、判决书、性能、对比、踩坑
├── port-android/            引擎移植工程：compat/ devs/ host/ init/ tests/ tools/、
│                            termux/ 部署测试套件、内核/引擎构建脚本、README.md
├── output/                  ★ 引擎交付物：换设备只拷这一份（见 output/README.md）
└── cache/                   大件中间产物（内核源码树、Debian 镜像、下载缓存），换设备不用带
```

`cache/` 可以整个删掉，删掉后 `port-android/build_kernel.sh` 与
`output/scripts/fetch-*.sh` 会重新拉取。**`output/` 里的东西不依赖 `cache/`。**

## 快速上手

### 引擎交付物（output/）

```bash
cd output
./scripts/deploy.sh        # 推到设备
./scripts/run-alpine.sh    # 2 秒起一个 Alpine 客户机
./scripts/run-debian.sh    # 起 Debian 12 完整开机（需先 fetch-debian.sh）
./scripts/run-tests.sh     # 引擎自测
./scripts/run-bench.sh     # 三方对比
```

### QEMU 加速器（仓库只放配方，编译时再拉上游 + 打 patch）

```bash
git submodule update --init src/qemu        # 钉住的 v11.1.3，浅克隆
./src/qemu-henge/apply.sh                   # qemu/ + patches/ -> src/qemu-henge/work/src
./src/qemu-henge/build.sh --fresh           # 产物 /data/qemu-android/build-android/q-henge
port-android/termux/deploy.sh               # 推到手机（Android/bionic）
# 设备上：
q-henge -M virt,gic-version=3,its=off -cpu max -m 1024 -smp 2 \
        -kernel images/Image -append "console=ttyAMA0 rdinit=/myinit" \
        -accel henge
```

## 从源码重建（引擎部分）

```bash
cd port-android
./build_kernel.sh          # 内核 Image（含 initramfs）
./build_image_only.sh      # 只重打 initramfs + Image（改客户机内容后用这个，快）
make                       # 引擎 hv-linux（需要 NDK；CC 可用 SYS= 覆盖成 aarch64-linux-gnu-）
./build_tests.sh           # 引擎自测
./build_bench.sh           # test_bench（EXTRA=1 带上加长基本块程序）
```

依赖：NDK r29（`aarch64-linux-android30-clang`）、`aarch64-linux-gnu-gcc`、
`qemu-img`（只用于转 Debian 镜像）。

## 相关文档

| 文档 | 内容 |
|---|---|
| [docs/README.md](docs/README.md) | 文档索引（设计 / 判决 / 性能 / 对比 / 踩坑） |
| [port-android/README.md](port-android/README.md) | 引擎移植怎么做的：每个垫片、每个坑、报错与修法 |
| [docs/FINDINGS.md](docs/FINDINGS.md) | 机制层面的发现（MMU、块链、时基、SB 改写…） |
| [docs/BENCH.md](docs/BENCH.md) | 性能数据：微基准 + 开机速度 |
| [docs/BOOT-VS-TCG.md](docs/BOOT-VS-TCG.md) | 为什么比 TCG 快 5.1×/7.4×，逐项拆解 |
| [docs/KVM-VS-ENGINE.md](docs/KVM-VS-ENGINE.md) | 四方对比：原生 / **KVM** / 加速器 / TCG |
| [docs/DESIGN-degraft.md](docs/DESIGN-degraft.md) | 去嫁接设计 + census + 范围清单（authority 形态） |
| [docs/VERDICT.md](docs/VERDICT.md) | 判决书：A1–A6 / Phase B 的判据、计数器、被否决方案 |
| [output/README.md](output/README.md) | 换设备部署手册 |
