# 对比 Termux 的 QEMU：我们还差什么

**日期**：2026-11-18
**方法**：把 Termux 的 `qemu-system-aarch64` 连同 69 个依赖库推到设备上跑起来，
直接对比两边的能力清单。**不是看文档，是两份二进制互相对照。**

## 前提：两边的 QEMU 版本完全相同

```
$ LD_LIBRARY_PATH=/data/local/tmp/tlib ./tqemu --version
QEMU emulator version 11.1.3
$ ./q-vnc --version
QEMU emulator version 11.1.3      ← 同一个版本
```

所以下面的差异**全部来自 configure 选项**，不是版本差异。

## 一、我们多出来的（这是我们的价值）

```
$ ./tqemu -accel help          # Termux
nitro
kvm
tcg

$ ./q-vnc -accel help          # 我们
henge                          ← ★
nitro
kvm
tcg
```

**`henge` 是我们唯一的、但也是决定性的优势。** 其余三项两边都有，
而且 `kvm` 在普通 Android 设备上基本不可用（无 `/dev/kvm` 或被 SELinux 拦），
`tcg` 是 Termux 实际能用的那个 —— 慢。

## 二、我们缺的（按实际影响排序）

### 1. 音频：我们一个能出声的后端都没有 ⚠️⚠️

```
$ ./tqemu -audiodev help
none alsa dbus jack pa spice wav

$ ./q-vnc -audiodev help
none wav
```

我们只有 `wav`（写文件）和 `none`。**没有任何能出声的后端。**

```
config-host.h:
#undef CONFIG_AUDIO_ALSA
#undef CONFIG_AUDIO_PA
#undef CONFIG_AUDIO_JACK
#undef CONFIG_AUDIO_SDL
```

这是最影响"当桌面用"的一项。修法：在 NDK 下重新编 QEMU，
开 `--enable-alsa`（Android 有 libasound 的 bionic 移植）或走 AAudio
（需要自己写一个 audio backend，Limbo 用 `dlopen` libaaudio 的方式，见 13.67 记录）。

### 2. 共享目录：`virtio-9p` 被我关掉了 ⚠️⚠️

```
$ comm -23 dev-termux.txt dev-ours.txt | grep 9p
virtio-9p-device
virtio-9p-pci
virtio-9p-pci-non-transitional
virtio-9p-pci-transitional
```

**这是我为了"能编过"主动 `--disable-virtfs` 的**（13.64 记录：
9p 的 `packed` 属性在 clang 下报 `expected ';'`）。

后果：客机和宿主之间**没法共享目录**。这在实际使用里是硬需求
（传文件、改代码、挂 ISO）。Termux 有。

两条修法：
- 修 `fsdev/9p-marshal.h` 的 packed 写法（clang 兼容），把 virtfs 开回来
- 或用 `virtiofs`（更现代），但两边都**没有** `virtio-fs` 设备，只有
  `vhost-user-fs`（需要外部进程），所以不是现成替代

### 3. USB 直通：`usb-host` / `usb-redir` 都没有 ⚠️

```
usb-host        ← 把宿主真实 USB 设备直通给客机
usb-redir       ← USB 重定向协议（Termux 靠 libusbredirparser）
```

我们两个都没有。含义：**插在手机上的 U 盘/键盘/加密狗没法给客机用。**
我们自己加的 `usb-kbd`/`usb-tablet` 是"模拟的" HID，和这个不是一回事。

### 4. 网络：缺 `passt` 后端 ⚠️

```
$ ./tqemu -M none -netdev help
socket stream dgram hubport tap passt user l2tpv3 bridge vhost-user vhost-vdpa

$ ./q-vnc -M none -netdev help
socket stream dgram hubport tap user bridge vhost-user
```

缺 **`passt`**（用户态网络，比 slirp 少一整套协议栈）和 `l2tpv3`。

注意：我们之前在另一条线（hv-linux）上验证过 passt，但那是**独立的 passt 进程**；
QEMU 内建的 `-netdev passt` 这个二进制里没有。

### 5. VNC 加密：`CONFIG_GNUTLS` 是 `#undef`

```
#undef CONFIG_GNUTLS
#undef CONFIG_VNC_VNC_TLS
```

`-vnc help` 里两边都列出 `tls-creds`/`sasl` 选项，**但那是文档，不代表编了**
（13.x 记过这个坑：help 文本是硬编码的）。实际用 `-vnc ...,tls-creds=x`
会报错。

对我们现在影响不大（VNC 只绑 127.0.0.1 + adb forward），但如果哪天要
远程连接就必须补。

### 6. 显示后端：只有 `none`

```
$ ./tqemu -display help
none curses spice-app dbus

$ ./q-vnc -display help
none
```

我们少了 **curses**（终端里直接显示，Termux 场景很实用）、`spice-app`、`dbus`。
不过 VNC 是通过 `-vnc` 参数提供的，不在这个列表里 —— **我们的 VNC 是好用的**。
所以这项实际影响小，除非想要"在 adb shell 里直接看画面"。

### 7. 其他缺的小项

- `tpm-tis-device` / `tpm-tis-i2c`：TPM，Windows 11 客机需要，Linux 用不上
- `vhost-vsock`：宿主↔客机的 socket 通道，可替代部分 9p 用途
- `vhost-vdpa`：虚拟 DPAA，Android 上无意义
- **用户态模拟器**：Termux 还有 `qemu-aarch64`（4.5 MB，跑单进程跨架构），
  我们只编了 `-softmmu`。我们不需要它（同架构），但值得知道

## 三、我们多出来的"垃圾"（应该关掉）

设备数我们 401 > Termux 385，但多出来的**几乎都是 Android 上无用的**：

```
vhost-user-blk / vhost-user-fs / vhost-user-gpu / vhost-user-input
vhost-user-scsi / vhost-user-snd / vhost-user-vsock / ivshmem-*
```

这些都需要**外部进程配合**（vhost-user 协议），在手机上没有意义，
只增加二进制体积和受攻击面。13.64 我 disable 了 `vhost-crypto/kernel/vdpa`，
**漏了 `vhost-user`**。

## 四、汇总表

| 维度 | Termux | 我们 | 性质 |
|---|---|---|---|
| QEMU 版本 | 11.1.3 | 11.1.3 | 相同 |
| **加速器** | tcg（实际能用） | **henge** + tcg | ✅ **我们强** |
| 音频 | alsa/pa/jack/dbus/spice/wav | 仅 wav | ❌ **缺，影响大** |
| 共享目录 | virtio-9p 全系列 | **无** | ❌ 缺，影响大 |
| USB 直通 | usb-host + usb-redir | 无 | ❌ 缺 |
| 网络 | +passt +l2tpv3 | 少这两 | ⚠ 缺 passt |
| VNC 加密 | GNUTLS | `#undef` | ⚠ 缺（当前不影响） |
| 显示后端 | curses/spice/dbus | 只有 none | ⚠ 影响小（VNC 可用） |
| TPM / vsock | 有 | 无 | ⚠ 小众 |
| 体积 | 31 个动态依赖，需 91 MB 库 | **单文件 117 MB，零外部依赖** | ✅ **我们强** |
| 部署 | 只能在 Termux 里跑（RUNPATH 硬编码） | **任意路径可跑** | ✅ **我们强** |

## 五、部署形态的差异（这条容易被忽略但很重要）

Termux 的 QEMU **出不了 Termux**：

```
RUNPATH: /data/data/com.termux/files/usr/lib     ← 硬编码
31 个 NEEDED，需要 91 MB 的库目录
```

我实测把它推出来单独跑，必须：
1. 递归解析 69 个库（含 glib 全家桶、gnutls、spice、pulse、jack…）
2. 手动推上去（38 MB）
3. `LD_LIBRARY_PATH` 覆盖 RUNPATH

**这就是为什么我们必须自己编** —— 不是重复劳动，是打包形态的要求。
我们的单文件 117 MB、零外部依赖（只 NEEDED libz/libm/libdl/libc），
扔到任何 Android 上都能跑。

## 六、如果要补齐，优先级

| 优先级 | 项 | 成本 | 收益 |
|---|---|---|---|
| **P0** | **共享目录**（修 9p 的 clang 兼容） | 小（改一个头文件 + 重开 virtfs） | 高（传文件是刚需） |
| **P0** | **音频**（AAudio 后端） | 中（要写 backend，或编 alsa） | 高（当桌面用必备） |
| P1 | `passt` 网络后端 | 小（重编时开） | 中（性能） |
| P1 | 关掉无用的 `vhost-user-*` | 极小（configure 加一行） | 中（减体积/攻击面） |
| P2 | USB 直通 | 中（要 libusb + 权限） | 中（小众但有用） |
| P3 | VNC TLS | 小（开 gnutls） | 低（现在只绑回环） |

**P0 两项的共同点：它们都不是"引擎的问题"，是 configure 和一个小 patch 的问题。**
也就是说，我们缺的东西**本质上是打包口径问题，不是能力问题**。
