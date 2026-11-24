# qemu-acce / port-android

把 `src/WindowsiOS` 那套 **ARM64→ARM64 直通式翻译器**搬到 Android/Linux 宿主上，
用它启动一个**完整 Linux aarch64 内核**——没有 KVM，没有硬件虚拟化。

`src/WindowsiOS` 保持只读，一个字没改。

## 为什么这台机器上做得成

原项目跑在 iOS 上，且要跟 Darwin 的一堆限制搏斗。Android 上这些限制大半不存在：

| 约束 | iOS / Darwin | 本 port（Android 11, MT6833） |
|---|---|---|
| 客机 4 KB 页 vs 宿主 | 宿主 16 KB，要 granule 适配层 | 宿主就是 4 KB，零适配 |
| JIT 可执行内存 | TXM 页签名，要靠调试器加持 | `mmap(PROT_EXEC)` 直接可用 |
| JIT 地址窗口 | 必须 < `0x7000000000` | 无限制 |
| 客机 RAM | 计入 Jetsam，要 ledger 豁免 | 普通匿名映射 |
| 时基 | `mach_absolute_time()` 24 MHz | `CNTVCT_EL0` 13 MHz → 定点换算到 24 MHz |

实测（`probe_android.c`，见工作区）：`mmap RW→RX` 通过、128-bit `CASPAL` 通过、
`LDAPUR` 未对齐 **SIGILL**（无 FEAT_LRCPC2；引擎对此本来就有软件 helper 分支）。

## 目录

```
port-android/
├── config.sh               所有脚本共用的路径与环境（不写死绝对路径、不写死设备序列号）
├── Makefile                引擎 hv-linux（NDK clang，输出到 build/）
├── compat/                 冒充 Darwin 的头，让原树不改一行就能编
│   ├── TargetConditionals.h      TARGET_OS_OSX/iPhone 全 0
│   ├── mach/mach_time.h          mach_absolute_time → CNTVCT 换算到 24 MHz
│   ├── mach/mach.h               只够 dispatch.c 统计段编过（thread_info 恒失败）
│   ├── libkern/OSCacheControl.h  sys_icache_invalidate
│   ├── hv_posix_compat.h         pthread_cond_timedwait_relative_np、F_BARRIERFSYNC
│   └── plat_linux.c              时基与 I-cache 维护的实现
├── devs/fdt_linux.c        裁剪版设备树：去掉 fw-cfg 与 pflash，支持 HV_BOOTARGS
├── jit_region_linux.c      替换 host/jit_region.c（vm_remap → mmap RWX / memfd 双映射）
├── linuxvirt.c             替换 devices/winvirt.c 的启动语义：UEFI → 直接 Image
├── main_android.c          替换 host/main_mac.m + winvm.c 的 UI/音频/显示那半
├── host/net_slirp_linux.c  用户态网络：libslirp 后端
├── host/net_passt_linux.c  用户态网络：passt 后端（--fd + UNIX socket 二层帧）
├── init/init.c             客户机的 /myinit（静态 PID 1：挂根、chroot、跑自检、PSCI 关机）
├── initramfs-alpine/       客户机用的 Alpine rootfs（会被编进 Image）
├── initramfs/              最小 initramfs（只有 /myinit，早期调试用）
├── tests/                  追加的受控基准程序（bench_extra.S）与 bench 驱动
├── tools/                  patch_macho_asm.py（Mach-O 汇编→ELF）、analyze_tcg_log.py
├── work/                   小工具源码：bench3.c、loops.c、clkprobe.c、build_passt.sh
├── build/                  编译产物（.o、hv-linux、自测与基准二进制）
├── build_kernel.sh         构建自包含内核（initramfs + cmdline 编进 Image）
├── build_image_only.sh     只重打 initramfs + Image（改客户机内容后用这个）
├── build_tests.sh          引擎自测套件
├── build_bench.sh          test_bench（EXTRA=1 带上加长基本块程序）
├── run_on_device.sh        推送并运行 hv-linux
├── run_bench.sh            转发到 ../output/scripts/run-bench.sh
├── run_debian.sh           转发到 ../output/scripts/run-debian.sh
├── README.md / FINDINGS.md / BENCH.md / BOOT-VS-TCG.md
└── （大件产物在 ../cache/：内核源码树、磁盘镜像、日志、Termux qemu）
```

四个替换文件的边界很清楚：**引擎（core/ + devices/）完全复用，只在宿主侧和
启动语义上分叉**。

## 构建

core 变体（原树只读，补丁落在 build/core）：

```bash
./tools/build_variant.sh 14      # 基线：每 EL 16384 槽，覆盖 64 MB
./tools/build_variant.sh 16      # 每 EL 65536 槽，覆盖 256 MB（出货版）
./tools/build_variant.sh 16 2    # 同上 + PMD 桶计数（不改行为）
```

切换变体会**全量重编**并打印 `cpus=?? MB` 自检 —— 半新半旧的 `.o` 会让
`sizeof(HvCpu)` 不一致，表现为段错误（踩过两次，见 MEASURE.md）。

```bash
make -j8                      # → build/hv-linux（约 200 KB）
./build_kernel.sh             # → $CACHE/linux-6.12/arch/arm64/boot/Image（路径见 config.sh）
```

`Makefile` 默认用 NDK 的 `aarch64-linux-android30-clang`；换系统交叉编译器：

```bash
make CC=aarch64-linux-gnu-gcc STRIP=aarch64-linux-gnu-strip
```

## 运行

### 真实发行版（Debian 12，NVMe 根 + systemd + 网络）

```bash
./run_debian.sh              # 首次会自动抓 lxc-images 的 qcow2 并转 raw
./run_debian.sh hvrun=1      # 跑验收脚本（系统信息/网络/编译/基准）后自动关机
CPUS=4 RAM=4096 ./run_debian.sh
```

lxc-images 除了 rootfs tarball，每个构建目录里还有 **`disk.qcow2`** ——
`debian/bookworm/arm64/default/<时间戳>/disk.qcow2`，348 MiB → 4 GiB 虚拟，
GPT + `p1` ESP + `p2` ext4 根。`run_debian.sh` 自动取最新时间戳并转换。

### 轻量自检（Alpine initramfs）

```bash
adb push build/hv-linux /data/local/tmp/
adb push ../cache/linux-6.12/arch/arm64/boot/Image /data/local/tmp/
adb shell /data/local/tmp/hv-linux --kernel /data/local/tmp/Image --ram 2048 --cpus 1
```

参数：`--kernel` 裸 arm64 Image（不是 ELF，不是 vmlinuz 压缩包）、`--ram MB`、
`--cpus N`、`--disk PATH`（挂到 NVMe）、`--jit MB`、`--stats`。

### 网络后端：passt 或 slirp

```bash
# 默认 slirp（纯用户态协议栈，已验证：10.6 MB/s、apt 装 gcc 成功）
# 用 passt：宿主机跑一个 passt 进程，guest 的帧经 socketpair 交给它，
#           对外是宿主内核的原生 TCP socket，少一整套用户态协议栈
adb push ../cache/tools/passt/passt /data/local/tmp/passt
HV_NET=passt ./run_debian.sh
```

passt 需要 `--fd`（不需要 `/dev/net/tun`、不需要 userns）。
这台设备上它要关掉三层自我隔离才能跑：`HV_PASST_NO_USERNS`、
`HV_PASST_NO_SANDBOX`、`HV_PASST_NO_SECCOMP`（由 hv-linux 自动设置）。
实测能完成 DHCP/DNS/HTTP 200，但吞吐异常，默认仍是 slirp。
细节与六处 bionic 兼容改动见 [`FINDINGS.md`](../docs/FINDINGS.md) 第八节。

### 客户机行为（内核命令行）

客户机行为由内核命令行控制，经 DTB 的 `/chosen/bootargs` 传入
（`HV_BOOTARGS` 环境变量，见 `devs/fdt_linux.c`），所以改参数不用重建内核：

| 参数 | 作用 |
|---|---|
| `root=/dev/nvme0n1p2` | 挂真实根分区并 chroot 过去（不给则停在 initramfs 自检） |
| `init=/bin/sh` | 换掉 `/sbin/init` |
| `hvrun=1` | 跑 `/tmp/hvrun.sh`（验收脚本）而不是普通 init |
| `HVB=alu\|mem\|call\|branch\|real\|u1\|u8\|u32` | 只跑某一项基准（`run_bench.sh` 用） |
| `hvrun=boot` | 等 systemd 完全就绪后自动关机（量开机时间用） |
| `fastboot=1` | 挂上根分区就关机（量纯启动路径） |

调试开关沿用引擎原有的环境变量：`HV_LOG=3` 打 MMIO 记录，`HV_PSCI_LOG=1` 打 PSCI 调用，
`HV_JIT_SPLIT=1` 强制走 memfd 双映射那条路。

## 引导路径

QEMU 用 `-kernel` 时干的事，这里照做：

1. Image 铺到 `RAM + 0x80000`（arm64 `text_offset`）
2. `pc = RAM + 0x80000`，`x0 = DTB 物理地址`
3. CPU 复位状态：EL1h、MMU/缓存关、DAIF 全屏蔽（`hv_cpu_reset_index` 本来就是这么设的，
   UEFI 和 Linux 要的启动态一致）
4. DTB 放 `RAM + 128 MB`——比内核 Image 高，不会被它盖掉
5. 内核起来后 PSCI 走 `hvc`，从 CPU 用 PSCI `CPU_ON` 拉起（引擎已实现）

设备树与 QEMU `-M virt` 同构：GICv3 + ITS、PL011、PL031、PL061、
PCIe `pci-host-ecam-generic`、`arm,armv8-timer`、`linux,dummy-virt`。

## 和原项目的差别

| | 原 project（Windows） | 本 port（Linux） |
|---|---|---|
| 固件 | pflash0 里的 EDK2 UEFI | 无，直接 Image |
| 平台描述 | 程序生成的 ACPI 6.3 + ITS | 裁剪版 FDT |
| 控制台 | ramfb + Metal 120 Hz | PL011 → stderr |
| 音频 | ICH6 HDA + CoreAudio | 未接 |
| 网络 | virtio-net + libslirp + WebDAV | virtio-net（未接 slirp，无 host 后端） |
| 存储 | NVMe + hvsparse | NVMe（raw 镜像） |
| 加密 | Windows Prism 的 LRCPC2 | 不涉及（Linux 原生 ARM64，无二层翻译） |

## 当前状态：跑起来了

**两条用户态路线都通，无 KVM：**

1. **Alpine 3.22（initramfs）** — 轻量自检环境，启动 4.3 s
2. **Debian 12 bookworm（NVMe 上的 ext4 根）** — 真实发行版，`systemd` 起到
   `multi-user.target`，getty 起在 ttyAMA0，**网络通**（libslirp NAT，
   大文件 10.6 MB/s，`curl` deb.debian.org 返回 HTTP 200，`apt-get update` 成功）

详见 [`FINDINGS.md`](../docs/FINDINGS.md)。

```
[    1.453077] Run /sbin/init as init process
  Alpine Linux v3.22
  libc.musl-aarch64.so.1 => /lib/ld-musl-aarch64.so.1 (0xffffb59a0000)
   11:  524  GICv3  27 Level  arch_timer
  uptime went 2.08 -> 3.12  (delta 1.04)
  SHELL PIPELINE WORKS
[    4.304917] reboot: Power down
```

1/2/4 vCPU 都验证过。**性能对比见 [BENCH.md](../docs/BENCH.md)**：同一台设备、同一个静态
二进制，与 QEMU TCG（Termux 的 aarch64 原生构建，同 ISA）比：

| 负载 | 原生 | QEMU TCG | 本移植 | 本移植 vs TCG |
|---|---|---|---|---|
| 纯计算 `alu` | 6.81 | 11.29 | 6.16 | **1.8× 快**（与原生持平） |
| 访存 `mem` | 5.51 | 13.83 | 9.14 | **1.5× 快** |
| 函数调用 `call` | 3.33 | 38.91 | 4.73 | **8.2× 快** |
| 分支 `branch` | 2.70 | 8.25 | 3.31 | **2.5× 快** |
| 真实混合 `real` | 2.9 ms | 125.3 ms | 10.2 ms | **12.3× 快** |

几何平均：TCG 是原生的 27%，本移植是原生的 62%，本移植比 TCG **快 3.4 倍**。
真实负载上 TCG 只剩原生的 2.3%，本移植是 28%——**这套方案的价值是"真实程序
比 TCG 快一个数量级"，不是"接近原生"。**

## 已知限制

- **多核已验证到 4 路**（`Total of 4 processors activated` + 完整用户态 + 干净关机），
  但没做长时间多核压力验证。
- **无网络**：`host/net_slirp.c` 依赖 libslirp，本 port 没链它；`virtio-net`
  设备在，但没有 NAT 后端，Linux 里网卡会起来而发不出包。
- **无显示**：Linux 客户机只有串口。要图形得接 virtio-gpu（引擎里没有，得新写）。
- **13 MHz → 24 MHz 时基换算**按定点乘做，误差远低于 1 tick/s；若宿主
  `CNTFRQ_EL0` 恰好 24 MHz（Apple Silicon 就是），走的是零开销直通。
