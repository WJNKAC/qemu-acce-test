# 跨设备对比工具

两台设备的差异决定了工具必须分开：

| | OPPO PDYT20 | vivo V2156FA |
|---|---|---|
| SoC / Android | mt6853 / 12 | MT6833V/ZA / 11 |
| root | ✅ Magisk（`a72`） | ❌ |
| Termux SSH | ✅ 8022 | ✅ 8022（`y76s`，用户 `u0_a343`） |
| `/proc/uptime` | ❌ 读不到 | ✅ |
| `python3` | ✅ | ❌（adb shell 里没有） |
| 时钟连续性 | 需 `/sys/power/wake_lock`（root） | 天然（USB 常亮） |

**计时手段必须按平台选**：PDYT20 用 python3，vivo 用 `/proc/uptime`。

## 脚本

| 文件 | 设备 | 用途 |
|---|---|---|
| `vivo-boot.sh` | vivo | 到 `Shell>` 的墙钟时间，n 轮。`adb shell sh vivo-boot.sh` |
| `pdyt20-boot.sh` | PDYT20 | 同上（用 python3 计时） |
| `vivo-disk.sh` | vivo | 带盘到 kernel@ / userspace@ |
| `cntfrq/cntfrq.c` | 两者 | 读 `CNTFRQ_EL0` + 实测速率 |

## 已测结果（2026-11-17）

无盘 → UEFI Shell（秒，各 3–4 轮）：

| 设备 | q-p0a（含 epoch 修复） | b-old（未修复） |
|---|---|---|
| PDYT20 | 14.3 / 14.2 / 14.6 | 14.6 / 14.6 / 14.7 |
| vivo | 13.4 / 13.5 / 13.5 / 13.5 | 13.4 / 13.6 / 13.5 / 13.6 |

带盘 → Linux（vivo）：`kernel@13.6s  userspace@25.3s  lines=617`

CNTFRQ：两台都是 **13000000 Hz（13 MHz）**，实测 ratio=1.0000。

## 传输

vivo 的 QEMU 二进制只依赖 Android 系统库
（`INTERP=/system/bin/linker64`，`NEEDED=libz/libm/libdl/libc`），
所以直接 `adb push` 到 `/data/local/tmp/` 就能跑，不需要 Termux 环境：

```sh
adb push qemu-system-aarch64 /data/local/tmp/q-p0a
adb shell chmod 755 /data/local/tmp/q-p0a
```

需要一并推的：`henge/bios/edk2-aarch64-code.fd`（64 MB）、
`henge/bios/efi-virtio.rom`（缺了会报 `failed to find romfile`）、
`vars0.img`（64 MB 零文件）、带盘时加 `deb12.qcow2` + 可选 `seed.iso`。
