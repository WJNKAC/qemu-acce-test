# 在 Termux 里测试：环境、用例与判据

> 目标：所有功能验证与 A/B 都在**手机上的 Termux** 里完成，而不是 `adb shell`。
> 理由不是方便，是**保真**：Termux 跑在 `u0_a343` / `untrusted_app_27`，
> 和将来的 APK 同一个沙箱——SELinux、execmem、内存压力、没有 adb 特权。
> 在 `shell` 域里测得通，不代表装成 App 还通。

参考对象：Termux 包 `qemu-system-aarch64-headless 1:11.1.3`（`qemu-utils` 同版本）。
我们只多一个 `-accel henge`，其余命令行应当逐字通用。

---

## 1. 对齐口径（Tier A/B/C）

「对齐」按**能在 `untrusted_app` 里真正工作**划，不按「列表里有」划。

### Tier A —— 必须对齐（验收面）

QEMU 版本 / `aarch64-softmmu` / `virt` 机器集（113 个）、VNC + pixman、
**virtfs/9p + attr**、TPM 设备、slirp、fdt。

### Tier B —— 应对齐（可后置）

`ssh` / `http(s)` 块驱动（libssh2 + libcurl 静态）、`curses` 显示（ncurses 静态）。

**音频（`pa`）与 USB 也在这档，不是不做，是留了位子：**

| 项 | 为什么能对齐 | TODO |
|---|---|---|
| `pa` 音频 | Termux 自带 **PulseAudio 守护进程**，sink 走 Android 音频栈（OpenSL/AAudio），所以 QEMU 的 `pa` 后端在应用域里是**真能出声**的——它不碰 `/dev/snd` | 静态编 libpulse-simple 链，configure 打开 `--enable-pa`；验收：客机 `aplay` 出声 |
| `usb-host` / `usb-redir` | Termux:API 的 `termux-usb` 把 Android USB Host 的设备 fd 交给本地进程，libusb 走 `libusb_wrap_sys_device()`，不需要 `/dev/bus/usb` | 先确认 QEMU `usb-host` 能否接 fd（`hostdevice=`/`hostfd=`），不行就补一层小中间件；验收：客机认到 U 盘 |

两者都留了显式 TODO 标记（`build-android.sh` 与本文末尾），实现时不用重新做设计。

### Tier C —— 明确不对齐

| 项 | 为什么 |
|---|---|
| `alsa` / `jack` / `dbus` / `spice` 音频 | `alsa` 直接开 `/dev/snd`，应用域读不到（实测 `ls: Permission denied`）；`jack`/`dbus`/`spice` 在 Android 上没有对应服务。**注意 `pa` 不在此列**，见 Tier B |
| （无——`usb-host`/`usb-redir` 已移到 Tier B，走 Termux:API） |
| `vhost-scsi` / `vhost-vdpa` / `vhost-vsock` | 无 `/dev/vhost-*` |
| `-netdev passt` | 应用 seccomp 直接 SIGSYS（13.9 已测）；已有 `stream` + Magisk 域 passt 的路子 |
| `l2tpv3` | 需 CAP_NET_RAW |
| `spice` / `gtk` / `sdl` | Android 无对应后端 |
| `gnutls`（VNC TLS） | 依赖链 8–10 个库，等有暴露到不可信网络的需求再说 |
| `qemu-aarch64` 用户态 | 同架构，用不上 |

判据：`conformance.sh` 的差集，除 Tier C 与 `henge`/`ivshmem` 外必须为空。

---

## 2. 目录布局（手机侧）

```
~/qa/
├── bin/q-henge        我们的（build-android.sh 产物，sha256 固定）
├── bin/q-qemu   ->    /data/data/com.termux/files/usr/bin/qemu-system-aarch64
├── bios/edk2-aarch64-code.fd
├── bios/vars.base     64 MiB 全 0xFF（全新 NVRAM 基底）
├── images/Image       Alpine（initramfs 已编进内核）
├── images/debian12.qcow2   Debian 12 cloud（352 MB）
├── share/             9p 宿主目录
├── runs/<ts>-<profile>-<accel>/{serial.log,stdout.log,stderr.log,meta.txt}
└── scripts/{cmdline,run,ab,conformance}.sh
```

镜像用 **qcow2 不用 raw**：352 MB vs 4 GB，走 Wi-Fi 传 4 GB 没意义。

---

## 3. 一次性准备

### 3.1 sshd（已知会卡死，先看这里）

现象：端口通、TCP 能连，但**不回 banner**，客户端报
`kex_exchange_identification: read: Connection reset by peer`；
手机上 `ps` 能看到 sshd 与卡住的 `sshd-session`。

修法（在 Termux 里执行）：

```bash
pkill -f sshd
nohup sshd > ~/sshd.log 2>&1 &
termux-wake-lock
```

`nohup ... > 文件` 是关键：sshd 的 stdio 如果挂在已经无人读的终端上，
写满缓冲区后它就不再 accept，表现正是「进程在、端口在、无 banner」。

### 3.2 部署

```bash
cd port-android
SSH_PASS=*** ./build-android.sh            # 产物 /data/qemu-android/build-android/q-henge
SSH_PASS=*** termux/deploy.sh              # 二进制 + 脚本 -> ~/qa
SSH_PASS=*** termux/setup-images.sh        # 镜像 + BIOS
SSH_PASS=*** termux/preflight.sh           # 环境门禁
```

---

## 4. 用例

| 编号 | 命令 | 判据 |
|---|---|---|
| T0 | `scripts/run.sh henge alpine` | 能起客机（JIT 在 `untrusted_app` 下可用）；失败先试 `HV_JIT_SPLIT=1` |
| T1 | `scripts/conformance.sh` | 差集 == 登记集（Tier C + henge） |
| T2 | `scripts/run.sh tcg alpine` / `henge alpine` | 两者都跑完 `/myinit` 自检并 PSCI 关机 |
| T3 | `scripts/run.sh {tcg,henge} debian12` | 都出现 `Reached target multi-user.target`；henge 的 `marker_at` ≤ 基线 ×1.05 |
| T4 | `scripts/run.sh {tcg,henge} debian12-9p` | 客机内 `mount -t 9p` 成功，100 MB 双向 `dd` + sha256 一致 |
| T5 | `scripts/run.sh henge debian12-vnc` | 笔记本连 `192.168.1.34:5900` 出画面 |
| T6 | 在 T3 的会话里 `system_reset` / 暂停恢复 | 不丢设备、能回到系统 |
| T7 | `scripts/ab.sh debian12 3` | 交错三轮；看 `marker_median` 比值 |

### 读数

每个 run 的 `meta.txt` 里有：

```
accel / profile / exit / wall / marker / marker_at / timeout / args
serial_lines / wfi_lines
```

`marker_at` 是串口日志里第一次出现「到点标志」的秒数（Alpine 是 `END`，
Debian 是 `Reached target multi-user.target`），比 `wall` 更接近真实启动时间。

### 已知故障 B 的记账

中断活锁（CPU 100% + `A` 疯涨 + `slept` 冻结）是**已知问题**，不是回归。
判定三件套：

| 信号 | 含义 |
|---|---|
| CPU 100% + `A` 疯涨 + `slept` 冻结 | 活锁（故障 B） |
| CPU 0% + `in-park ≥ 1` 冻结 | park 死锁 |
| `sendkey` 无响应 + `wake` 冻结 | 客机卡死 |

---

## 5. 排障

| 症状 | 处置 |
|---|---|
| `kex_exchange_identification` | 3.1 的三行 |
| `run.sh` 报 `找不到可执行` | `deploy.sh`；确认 `~/qa/bin/q-henge` 可执行 |
| henge 起不来、`mmap RWX` 失败 | `HV_JIT_SPLIT=1`；仍失败则记录为「应用域 JIT 不可用」，回 adb shell 域跑 henge，Termux 只跑 TCG 参考 |
| 磁盘不足 | `df -m ~`；只保留 debian12.qcow2，Alpine 用 initramfs 不落盘 |
| 长测中途断 | `termux-wake-lock`；T7 限 30 分钟；用 `collect.sh` 先收已有 runs |

---

## 6. 待办占位（不是「不做」，是「排在后面」）

| 位置 | TODO |
|---|---|
| `build-android.sh` | `--enable-pa`：需要先把 libpulse-simple 静态编进 `$DEPS`（链：libpulse → libpulsecommon → libsndfile/speexdsp/dbus-1） |
| `build-android.sh` | USB：先验证 QEMU `usb-host` 的 `hostdevice=`/`hostfd=` 路径，再决定要不要写 `termux-usb` 中间层 |
| `conformance.sh` | 上述两项实现后，从期望差集里删掉对应条目 |

---

## 7. 首跑结果（2026-11-19 12:32，V2156FA / Termux `u0_a353`）

环境：Termux 重装为 debug 版后 sshd 恢复（`SSH-2.0-OpenSSH_10.6`），
`run-as com.termux` 同时可用；`~/qa` 87.9 GB 可用。

| 用例 | 结果 | 证据 |
|---|---|---|
| G0 门禁 | ✅ | banner/ssh/wake-lock/磁盘/二进制/镜像全绿 |
| **T0 henge JIT** | ✅ | `-accel henge` 起机后 5 s 内 utime=472（≈94% 单核），vCPU 线程在跑；会话 SELinux 域确认为 `u:r:untrusted_app_27`，不是 `runas_app` |
| **T1 六面一致** | ✅ | `conformance.sh --check` 与基线一致；**9p 与 tpm 已不在差集** |
| T2 `-kernel` Alpine | ❌ henge | 同一条命令：TCG 打出完整启动日志；henge 串口 **0 字节** |
| T3 Debian 12 UEFI | ❌ henge | UEFI→GRUB→EFI stub 全过（`-serial` 有 23 行），内核接手后无输出；TCG 同一镜像 46 s 进 systemd |
| T4 9p（设备层） | ✅（TCG） | 客机内核打出 `9p: Installing v9fs`、`9pnet: Installing 9P2000`，virtio-pci 设备绑定 MSI-X |

### henge 侧的确切形状

45 秒 UEFI 采样：

```
310951  hv_run returned 4    ← HV_EXIT_WFI
 83174  hv_run returned 10   ← HV_EXIT_SYSREG_EXT
     9  hv_run returned 11   ← HV_EXIT_PSCI_EXT
```

`hv_run returned 4` 是 `HV_EXIT_WFI`：WFI 立刻返回、CPU 打满，正是
`labs/STATE-2026-11-19.md` 里的**故障 B**（线真高但不降，EOI/投递语义）。
`-kernel` 路径更早停：PC 落在 `__arm_smccc_hvc`，PSCI v1.1/`MIGRATE_INFO_TYPE`
都正常返回，随后进入 WFI 循环。

**结论：不是这次构建引入的回归，是已知故障 B。** 测试套件本身已经能把它
稳定复现出来（TCG 同命令通过，形成对照）。T2/T3 要等故障 B 修掉；
T1/T4 现在就能用。

### 已知差异（基线已登记）

`ivshmem-doorbell` / `ivshmem-plain` 是我们多出来的（构建带 `CONFIG_IVSHMEM`）。
对客机无影响；想抹平可加 `--disable-ivshmem`，不影响验收。

### 首跑的补救：读穿透被回退（B3）

首跑暴露出 henge 在 `smp=2` 下卡在 EFI stub 之后。用设备上留着的旧二进制做 A/B：

| 二进制 | 构建时间 | `smp=2` |
|---|---|---|
| `q-fix3` | 11-18 22:51（读穿透前） | ✅ 522 行到 systemd |
| `q-p1` | 11-19 08:57（读穿透前） | ✅ 522 行到 systemd |
| `q-rt` | 11-19 10:04（读穿透后） | ❌ 23 行 |
| `q-henge` | 11-19 11:49 | ❌ 23 行；`smp=1` ✅ 301 行 |

诊断证据（`HV_WFI_LOG=1`）：

```
henge: wfi spin bailout cpu0 pc=ffff800008c5e9cc daif=c0 irq=1 fiq=0 el=1
```

`daif=0xc0` 表示 PSTATE.I=1（guest 在 `cpu_do_idle` 里关中断执行 WFI），
而读穿透看到的是**真实电平**，于是 WFI 每次都立刻返回 → 同一 PC 每秒约 7k 次 → 双核启动卡死。
旧的"拷贝线"是**陈旧**的，恰好在这里是 0，所以能睡下去——它的正确性一直是巧合。

尝试过并**否决**的两条：

- **B1**：hook 改读 `env.irq_line_state`（电平）。仍卡死 → 不是 latch/level 的问题。
- **B2**：WFI 对"高电平但被屏蔽"不再快返回。仍 74% CPU、仍卡死 → 不是 WFI 快返回的问题。

**B3（当前方案，已验证）**：把一期读穿透整体回退到改造前语义——
引擎重新读自己的 `HvPerCpu.irq_line`，加速器在"每次重入前 / kick / MMIO 回调后"
重新发布电平（`henge_irq_push()`）。结果：

```
henge debian12 smp=2: marker_at=31.06s  serial_lines=536   ← 到 systemd 首批 target
```

### 还没做

- `smp=1 / 4`、9p、VNC、30 min soak 的回归（用例已就绪，一条命令）；
- 读穿透真正的修复：它暴露的是**线在 EOI 之后仍然为高**这个底层 bug（1056 次 IAR/EOIR 成对出现，
  说明 guest 在正常 ack），回退只是把问题盖回去。下一步应从这里继续，而不是重新打开读穿透。
