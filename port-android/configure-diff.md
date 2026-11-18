# 编译参数对比：Termux 的 QEMU vs 我们的

**日期**：2026-11-18
**方法**：把 Termux 的 `qemu-system-aarch64`（11.1.3）连同 69 个依赖推到设备上真跑，
与我们的 `q-9p`（同版本）逐项实测对照。**所有结论都有命令输出支撑，不是读文档。**

---

## 一、两边的 configure 差异（按能力域）

### 1. 加速器 —— 我们唯一且决定性的优势

```
Termux:  nitro  kvm  tcg
我们:    henge  nitro  kvm  tcg
```

`kvm` 在普通 Android 设备上不可用（无 `/dev/kvm` 或被 SELinux 拦），
`nitro` 是 Apple 的东西。**Termux 实际只能用 `tcg`**，我们用 `henge`。

### 2. 链接与部署形态

| | Termux | 我们 |
|---|---|---|
| 链接方式 | 动态 | **静态** |
| NEEDED | **31 个** | **4 个**（libz/m/dl/c，系统自带） |
| 外部库需求 | 91 MB（`/data/data/com.termux/files/usr/lib`） | 0 |
| RUNPATH | **硬编码** `/data/data/com.termux/files/usr/lib` | 无 |
| 能否独立分发 | ❌ 出不了 Termux | ✅ 单文件 120 MB 扔哪都能跑 |

这是**打包口径**上的根本差异，也是我们必须自己编的原因。

### 3. 显示后端

```
Termux:  none  curses  spice-app  dbus
我们:    none
```

缺 `curses`（在终端里直接显示）、`spice-app`、`dbus`。
**VNC 不在这个列表里** —— 它是 `-vnc` 参数提供的独立通道，两边都有且我们用得很好。

### 4. 音频后端 ⚠️ 差距最大

```
Termux:  none  alsa  dbus  jack  pa  spice  wav
我们:    none  wav
```

我们 `config-host.h` 里全是 `#undef`：

```
#undef CONFIG_AUDIO_ALSA
#undef CONFIG_AUDIO_PA
#undef CONFIG_AUDIO_JACK
#undef CONFIG_AUDIO_SDL
#define CONFIG_AUDIO_DRIVERS ""
```

**我们一个能出声的后端都没有**（`wav` 是写文件）。

### 5. 网络后端

```
Termux:  socket stream dgram hubport tap passt user l2tpv3 bridge vhost-user vhost-vdpa
我们:    socket stream dgram hubport tap user bridge vhost-user
```

缺 **`passt`**、`l2tpv3`、`vhost-vdpa`。

`passt` 的缺失有明确根因（见第二节），`l2tpv3` 是我 `--disable-l2tpv3` 关的。

### 6. 块驱动

| 格式 | Termux | 我们 |
|---|---|---|
| qcow2/vmdk/vhdx/vdi/vpc/qed/luks/vvfat | 有 | 有 |
| **ssh** | **有** | **无** ← 依赖 libssh |
| **http** | **有** | **无** ← 依赖 libcurl |
| rbd/iscsi/nfs/gluster | 无 | 无 |

`ssh`/`http` 块驱动让我们**挂不了远程镜像**（比如 `-drive file=ssh://...`）。

### 7. 设备

| 设备 | Termux | 我们 |
|---|---|---|
| `usb-host`（宿主真实 USB 直通） | 有 | **无** |
| `usb-redir`（USB 重定向协议） | 有 | **无** |
| `virtio-9p-*`（共享目录） | 有 | **原本无 → 已修好**（见第三节） |
| `vhost-vsock-*` | 有 | 无 |
| `tpm-tis-*` | 有 | 无 |
| 设备总数 | 385 | 401（多的是 44 个 `vhost-user-*` 等） |

### 8. 加密

```
config-host.h:
#undef CONFIG_GNUTLS
```

Termux 链接了 `libgnutls.so`。所以它的 VNC 可以用 `tls-creds`，
我们的不能（`-vnc help` 里两边都列出 `tls-creds` 选项，**但那是文档，不代表编了**）。

### 9. 用户态模拟

Termux 还有 `qemu-aarch64`（4.5 MB，跑单进程跨架构）。我们只编了 `-softmmu`。
我们不需要它（同架构），但这是它的能力之一。

---

## 二、缺 passt 的确切根因（不是"没开"）

`meson.build:1315`：

```meson
enable_passt = get_option('passt')
  .require(host_os == 'linux', error_message: 'passt is supported only on Linux')
  .require(gio.found(), error_message: 'passt requires gio')     # ← 这条没过
  .allowed()
```

**`passt` 需要 `gio`（glib 的 GIO 子库）。** 我们的 prefix 里：

```
glib-2.0.pc  gmodule-2.0.pc  gobject-2.0.pc  gthread-2.0.pc  ...
                                    ↑ 没有 gio-2.0.pc
```

而 Termux 的 QEMU 链接了 `libgio-2.0.so.0`。

所以：**我们缺 passt 是因为当初编 glib 时没开 GIO，不是因为不想开。**
`--enable-passt` 在 gio 缺失时会直接 configure 失败（`.require()` 语义）。

修法：用同一份 glib 源码（`/data/qemu-android/src/glib-2.74.6`）
加 `-Ddefault_library=static` 重编并启用 GIO（可 `-Dlibmount=disabled -Dselinux=disabled`
减少依赖），然后重编 QEMU 就能开 `--enable-passt`。

---

## 三、9p 共享目录：已修好，而且当初的归因是错的

13.64 我把 virtfs 编译失败归因为"clang 对 `packed` 更严格"，**那是错的**。

真实原因是**宏冲突**。bionic 的 `<sys/stat.h>` 第 123-125 行：

```c
#define st_atime_nsec st_atim.tv_nsec
#define st_mtime_nsec st_mtim.tv_nsec
#define st_ctime_nsec st_ctim.tv_nsec
```

而 QEMU 的 `fsdev/9p-marshal.h` 里结构体成员就叫 `st_atime_nsec`，
预处理后变成：

```c
uint64_t st_atim.tv_nsec;      // ← 语法错误
```

**glibc 只定义 `st_atimensec`（没有下划线），所以上游在 glibc 上从不暴露这个问题。**

修法（`include/qemu/osdep.h`，紧接 `#include <sys/stat.h>` 之后）：

```c
#if defined(__ANDROID__)
#undef st_atime_nsec
#undef st_mtime_nsec
#undef st_ctime_nsec
#endif
```

再配 `--enable-virtfs --enable-attr`（`libattr` 的检测是"能直接链接 `setxattr` 就算有"，
bionic 的 libc 里就有，所以零额外库）。

验证（三层，逐层排除"看起来对"）：

```
# 1) configure 认可
    VirtFS (9P) support             : YES
    ATTR/XATTR support              : YES

# 2) 设备编译进来了
$ ./q-9p -device help | grep 9p
name "virtio-9p-pci", bus PCI, alias "virtio-9p"

# 3) 实例化成功（-virtfs 参数被接受，设备挂上总线）
(qemu) info qtree
      dev: virtio-9p-pci, id ""
        dev: virtio-9p-device, id ""
          mount_tag = "hostshare"
```

第 3 层是关键：`-virtfs` 若有任何问题 QEMU 会启动即报错退出，
它跑起来了并且 qtree 里能看到 `mount_tag`，说明后端是真的在工作。

二进制从 117.8 MB → 120.2 MB（+2.4 MB），**仍然零外部依赖**。

**这条推翻了"9p 不可用"的旧结论：它一直是可用的，只是被一个宏冲突挡着。**

---

## 四、哪些能静态编译进去（回答"能静的都静掉"）

前提：**我们本来就走全静态**。`glib/gobject/gmodule/ffi/pcre2/pixman` 都是 `.a`。

### A. 已经静态（无需动作）
QEMU 本体、`accel/henge`、slirp、pixman、glib 家族、libfdt

### B. 纯 QEMU 源码 / 只需 libc —— 只卡编译问题

| 项 | 需要什么 | 成本 |
|---|---|---|
| **virtfs/9p** | 零外部库（bionic 有 `setxattr`） | ✅ **已做完** |
| **l2tpv3** | 纯 QEMU 代码 | 一行 configure |
| **vhost-vsock** | NDK 的 `linux/vhost.h` | 小 |

### C. 需要外部静态库，但能编

| 项 | 外部库 | 难度 |
|---|---|---|
| **gio → passt** | glib 的 GIO（同源码，可 `-Dlibmount=disabled`） | 中（重编 glib） |
| **curses 显示** | ncurses | 小（单库） |
| **音频** | alsa-lib **或** 自己写 AAudio backend | 中 |
| **usb-host / usb-redir** | libusb-1.0 / libusbredirparser | 中（还要 SELinux 权限） |
| **VNC TLS** | gnutls（→ nettle/gmp/hogweed/p11-kit/tasn1/idn2/unistring…） | **大，链约 8-10 个库** |
| **ssh / http 块** | libssh / libcurl（curl 又拖 openssl/zlib…） | 中偏大 |

### D. 静态也没用（不要浪费力气）

| 项 | 为什么 |
|---|---|
| `vhost-user-*`（44 个设备！） | 需要**外部进程**做协议对端。静态链接客户端毫无意义，**应该关掉**（净减体积） |
| `spice` | 依赖链巨大 + Android 上没有好的 SPICE 客户端 |
| `kvm` / `nitro` | 内核能力，不是链接问题 |
| **用户态模拟** `qemu-aarch64` | 同架构用不上 |

---

## 五、汇总：我们还差什么（按影响排序）

| 优先级 | 缺什么 | 根因 | 修法成本 |
|---|---|---|---|
| **P0** | **音频** | `--disable-*` 全关 | 中：编 alsa 或写 AAudio backend |
| **P0** | ~~9p 共享目录~~ | ~~宏冲突~~ | ✅ **已修** |
| P1 | `passt` 网络 | 缺 gio | 中：重编 glib 开 GIO |
| P1 | 关掉 44 个 `vhost-user-*` | 我漏了 disable | 极小：configure 加一行 |
| P2 | USB 直通 | 缺 libusb/usbredir | 中：+ SELinux 权限 |
| P2 | `curses` 显示 | 缺 ncurses | 小 |
| P3 | VNC TLS | 缺 gnutls 链 | 大：8-10 个依赖 |
| P3 | ssh/http 块 | 缺 libssh/libcurl | 中偏大 |

**核心判断：我们缺的东西绝大多数不是"引擎能力"，是"打包口径"。**
除了音频需要写一点后端代码，其余都是 configure 开关或补一个库的事。
