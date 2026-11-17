# 移植结果

把 `src/WindowsiOS` 的 ARM64→ARM64 直通翻译器搬到 Android 上，
**无 KVM 启动完整 Linux aarch64 内核 + 真实 Alpine 用户态**。

原树 `src/WindowsiOS` 全程只读，一个字没改。

---

## 一、结论

| 项 | 结果 |
|---|---|
| 完整 Linux 6.12 内核启动 | ✅ 到 `Freeing unused kernel memory` |
| **Debian 12 从 NVMe 启动** | ✅ GPT + ext4 + systemd 到 `multi-user.target` |
| **网络（libslirp NAT）** | ✅ DNS、curl HTTP 200、6.2 MB/s、`apt-get update` |
| **网络（passt 后端）** | ⚠️ DHCP/DNS/HTTP 200 都通，但传输收尾卡住（见第八节） |
| **开机速度对比 TCG** | ✅ 纯启动路径 4.2–5.1×，完整启动 7.4×（见 BENCH.md / KVM-VS-ENGINE.md） |
| **在客户机里装编译器并编译** | ✅ `apt install gcc` → 编译运行成功 |
| 真实用户态（Alpine 3.22.8） | ✅ musl 动态链接、fork/exec、管道、文件系统 |
| SMP | ✅ 1/2/4 vCPU 都到 `Total of N processors activated` |
| 干净关机 | ✅ PSCI `SYSTEM_OFF` → `reboot: Power down` |
| 启动时间（完整到 systemd ready） | **25–26 s**（TCG 同条件 ≥15 分钟） |
| 纯计算相对性能 | **与原生持平**（vs QEMU TCG 快 1.8×） |
| 真实混合负载 | 原生 28%，**vs QEMU TCG 快 12.3×** |
| 图形 | 未做（按要求） |

性能对比（同一个静态二进制、绑 A76 大核、冷态多次取最小）见 **[BENCH.md](BENCH.md)**。
要点：

| 负载 | 原生 | QEMU TCG（同 ISA） | 本移植 | 本移植 vs TCG |
|---|---|---|---|---|
| 纯计算 | 6.81 | 11.29 | 6.16 | 1.8× 快（与原生持平） |
| 访存 | 5.51 | 13.83 | 9.14 | 1.5× 快 |
| 函数调用 | 3.33 | 38.91 | 4.73 | 8.2× 快 |
| 分支 | 2.70 | 8.25 | 3.31 | 2.5× 快 |
| 真实混合 | 2.9 ms | 125.3 ms | 10.2 ms | **12.3× 快** |

几何平均：TCG 是原生的 27%，本移植是 62%，比 TCG 快 3.4 倍。

---

## 二、三个真正的根因（都不是"TLB 坏了"）

排查过程中先后排除了 TLB stash、分组优化、TLB 布局、RAM 大小、指令翻译正确性
（引擎自测在这台机器上全过）。真正的三个原因是：

### 1. vCPU 线程栈太小 → 随机 SIGSEGV

原项目 `host/winvm.c` 有两处 `pthread_attr_setstacksize(&attr, 8u << 20)`，
移植时漏掉了。Android 默认 pthread 栈约 1 MB，而：

- `core/translate.c` 的 `Emit` 是 `static __thread`，约 **0.36 MB**
  （hot/cold 各 128 KB、rel 96 KB、pool 40 KB、ool 56 KB、site 48 KB）
- bionic 把 TLS 放在栈区下方，这部分直接从栈里扣
- `hv_run` 还是递归入口

于是实际可用栈不到 0.6 MB。症状极具误导性：**崩溃位置随机**
（0.145 / 0.183 / 0.187 s 各不相同）、PC 落在 JIT 里、`si_addr=0`，
而且 `HV_SLOW_MEM=1` 会崩得**更早**（helper 路径栈更深）——
看起来完全像 TLB 或访存路径的 bug。

修法：所有 vCPU 线程（含 CPU0）用 16 MB 栈；CPU0 也从 main 线程搬到独立线程，
因为 main 线程的栈大小不由我们决定。

### 2. 缺少 1 ms kicker → 定时器断流、内核死锁

原项目 `host/winvm.c:215` 有一个 `kicker_thread`，每 1 ms 调 `hv_machine_kick_all`。
移植时同样漏掉了。

为什么必须有它 —— `core/dispatch.c:936` 的 tick 条件是：

```c
if (m->tick && (kicked || (++since_tick >= 64 && (since_tick = 0,
                                    next_due && mach_absolute_time() >= next_due))))
```

`next_due` 是上一次 tick 返回的下一个截止时间。**guest 把定时器关掉的那一刻它返回 0**，
此后 `next_due &&` 恒假，**再也不会调用 tick**。Linux 的 clockevent 在启动期会反复
arm/disarm（从 dummy 切到 arch_timer），于是定时器中断就此断流。

现场证据：内核停在 `lib/raid6/algos.c:177`

```c
j0 = jiffies;
while ((j1 = jiffies) == j0)
    cpu_relax();
```

`jiffies = 0xfffedb10`，正是启动后 56 个 tick（250 Hz）≈ 0.224 s，
和串口日志停下的位置完全吻合。watchdog 显示 PC 一动不动。

### 3. 引擎声明了 SB，但这台 CPU 没有 → SIGILL

`core/sysreg.c:20`：

```c
#define ID_AA64ISAR1 0x0000001100211001ull /* ... SB (no PAuth: Cortex-A76 + no-op PAC) */
```

最低 4 位是 SB 字段，值为 1，等于告诉 guest "这台机器有 ARMv8.5 的 `sb` 指令"。
原项目跑在 Apple Silicon（ARMv8.5+，真有 SB）上，所以从没暴露。

Linux 会照这个声明做 alternatives —— `arch/arm64/include/asm/barrier.h:43`：

```c
#define spec_bar() asm volatile(ALTERNATIVE("dsb nsh\nisb\n", SB_BARRIER_INSN"nop\n", ARM64_HAS_SB))
```

启动时把 KPTI trampoline（`__bp_harden_el1_vectors`）里的 `dsb nsh` 就地补丁成 `sb`。
Cortex-A76 是 ARMv8.2，执行 `sb` 直接 SIGILL。

现场证据（故障瞬间的 JIT 镜像）：

```
guest_pc=0xffff800080012c14   ; dsb nsh
jit words: ... d50330ff<--    ; 0xd50330ff = sb
```

修法：在 `hv_jit_finish`（移植层自己的文件）里，宿主没有 SB 时把
`0xd50330ff`（`sb`）改写成 `0xd503379f`（`dsb nsh`）。这正是 Linux 自己在
`HAS_SB` 为假时生成的序列，语义只会更强。宿主真有 SB 时一次都不改
（`getauxval(AT_HWCAP)` 的 HWCAP_SB）。

---

## 二·补：与 WindowsPixel 的交叉验证

`src/WindowsPixel` 是同一个引擎的 Linux/ARM64 + Android 移植（DGX Spark / Pixel 9）。
拿它当参考实现逐条对照，我踩的三个坑对得上两个：

| 问题 | 我 | WindowsPixel | 结论 |
|---|---|---|---|
| vCPU 线程 8 MB 栈 | 漏了 → 随机 SIGSEGV | 保留（`winvm.c` 两处） | 我漏抄，原项目本来有 |
| 1 ms kicker 线程 | 漏了 → 定时器断流、内核死锁 | 保留（`kicker_thread`） | 我漏抄，原项目本来有 |
| `ID_AA64ISAR1` 谎报 SB | 自己发现并修 | **未处理** | 他们跑 Windows，Windows 不用 `sb`；**这是 Linux 客户机特有的 bug** |
| Darwin commpage `0xfffffc090` | 铺零页绕过 | 直接改 `translate.c` 加 `#ifdef` | 同一处问题，两种修法 |

### 他们的两处做法比我的好

1. **计数器换算精度**：我用 32 位定点、不减基数；他们是 60 位定点、四舍五入、
   并且减去 `hv_cnt_base` 再乘，避免 `CNTVCT` 很大时丢精度：
   ```c
   mult = ((CNTFRQ << 60) + frq / 2) / frq;         /* 带舍入的定点 */
   return ((vct - hv_cnt_base) * mult) >> 60;        /* 先减基数再乘 */
   ```
2. **计数器内联**：他们让 JIT 直接吐 `mrs cntvct_el0` + `sub` + `mul/umulh`，
   不经过 helper。我的零页垫片让类型读到 0，于是每次读计数器都走一次
   通用 MRS helper —— 功能对，但有额外开销。

我保留了"原树只读"的约束（垫片方案），没采用内联那条：那需要改 `translate.c`。
代价是计数器读多一次 helper 调用；稳态基准不受影响（`bench3` 的循环里不读时钟）。
如果要极致性能，这是第一个该拿来换的点。

---

## 三、Darwin 债清单（按踩到的顺序）

1. **时基**：引擎时间域是 24 MHz（guest `CNTFRQ_EL0`、WFI 自旋、定时器比较、
   统计窗口都按它算），Darwin 的 `mach_absolute_time()` 正好是 24 MHz。
   宿主 `CNTFRQ_EL0` 是 13 MHz，垫片做定点换算
   `cntvct × (24e6<<32)/13e6 >> 32`，误差远低于 1 tick/s；宿主恰好 24 MHz 时零开销直通。

2. **commpage 读**：`core/translate.c:1519` 在**翻译时**读 `0xfffffc090` 的一个字节，
   决定 guest 计数器读指令内联展开还是走 helper。Linux 上这个地址没映射，
   读它就是 SIGSEGV —— 第一次跑内核炸的正是这里（宿主 C 代码里，不在 JIT）。
   解法：`0xfffffc000` 铺一页零页，字节读 0 → 走通用 MRS helper →
   `hv_counter()` → 换算好的 24 MHz 值。数值口径一致。

3. **JIT 内存**：`vm_remap` 双映射 → `mmap(PROT_EXEC)`；不行就 `memfd + 两块映射`。

4. **Mach-O 残留**：`enter.S` 与测试的 `.S` 是 Mach-O 语法（符号下划线前缀、
   `@PAGE`/`@PAGEOFF`）。`tools/patch_macho_asm.py` 生成 ELF 副本，原文件不动。

5. **pthread 扩展**：`pthread_cond_timedwait_relative_np`、`F_BARRIERFSYNC`
   在 Linux 上没有，`compat/hv_posix_compat.h` 给等价实现。

6. **Jetsam / TXM / Metal / CoreAudio**：全部不需要，因 `TARGET_OS_*` 全 0 自动不参与编译。

---

## 四、引擎自测（设备实测）

`./build_tests.sh` 把原项目的 7 个套件编到设备上跑（下表已更新为第六轮交付配置
`BITS=14 + WHINT 位图 + 只读 bank`）：

```
test_classify     43 cases, 0 failures
test_operands     36 cases, 0 failures
test_mmu          76 checks, 0 failures
test_exc          53 checks, 0 failures        （时基断言修好后已全过）
test_jit_region   两种映射形态都返回正确值
test_mem          mode 0/1 全 ok；mode 2（MMU on）10 项失败（移植前就存在，
                  症状是 VBAR=0 空向量页取指，见 MEASURE.md 第六轮 §6）
test_jit          除 pac 外全部 seed 通过
```

跑测试的两个前提（都踩过，必须带）：

```bash
ulimit -s 65536        # test_mem 的 main 栈帧 ~8.6 MB，设备默认栈 8 MB
HV_SKIP=atomics        # 该用例的原生对照用 ldapur/stlur（FEAT_LRCPC2），A55 会 SIGILL
```

剩下的失败都是**宿主机能力/假设**问题，不是移植缺陷：

- `test_jit` 的 `pac` 用例要先原生跑一遍作对照，而这台 CPU 没有 ARMv8.3 PAuth，
  原生执行 `paciasp` 直接 SIGILL。JIT 侧反而是对的（引擎把 PAC 当无操作）。
- `test_mem` 的 `atomics` 同上：`ldapur` 属 ARMv8.4 FEAT_LRCPC2，A55 没有。
  裸汇编三行已在设备上复现（exit=132）。

---

## 五、复现

```bash
make -j8 && ./build_kernel.sh        # → build/hv-linux + $CACHE/linux-6.12/.../Image
./run_on_device.sh --ram 1024 --cpus 4

./build_tests.sh                     # 引擎自测
adb shell 'cd /data/local/tmp; ./test_mmu'
```

用户态镜像是 Alpine 3.22.8 的 LXC rootfs（
`mirrors.tuna.tsinghua.edu.cn/lxc-images/images/alpine/3.22/arm64/default/`），
3.5 MB 解压后 15 MB，做成 initramfs 编进 Image：不需要块设备就能拿到
musl 动态链接器和完整 busybox，正好把 ELF loader / mmap / 缺页路径都过一遍。

调试开关（引擎原有）：`HV_LOG=3`、`HV_WATCHDOG=1`、`HV_TLB_AUDIT=1`、
`HV_BLOCK_DUMP=<file>`、`HV_TLBT`/`HV_GROUPS`/`HV_K2`/`HV_RECHECK`/`HV_WFI_SPIN`/`HV_SLOW_MEM`。

---

## 六、还没做的

- **块设备**：设备端 NVMe 已实现、Linux 有驱动，但没接镜像跑真文件系统。
- **网络**：`virtio-net` 设备在，`host/net_slirp.c` 依赖 libslirp，本 port 没链。
- **图形**：没做（按要求）。要图形得新写 virtio-gpu，引擎里没有。
- **SMP 压测**：4 核能起到用户态并干净关机，但没做长时间多核负载稳定性验证。

---

## 七、真实发行版：Debian 12 on NVMe

lxc-images 除了 rootfs tarball 还有 `disk.qcow2`（我一开始漏看了）。
拿 `debian/bookworm/arm64/default` 的 qcow2（348 MiB → 4 GiB 虚拟）转成 raw 当 NVMe 盘。

**布局**：GPT，`p1` 100 MB（ESP）+ `p2` 3995 MB（ext4 根）。
内核侧 `CONFIG_BLK_DEV_NVME / EFI_PARTITION / EXT4_FS` 全部 `=y` 内建——
没有模块，因为不带 initramfs 就没东西去加载模块。

**启动方式**：让 initramfs 当一级引导。`myinit` 读 cmdline 的 `root=`，
挂上根分区、`chroot`、`exec /sbin/init`。用 `chroot` 而不是 `pivot_root`，
因为不必卸载 initramfs，也不会卡在"删除 initramfs 文件"这类细节上。

**结果**：
```
[  OK  ] Started dbus.service - D-Bus System Message Bus.
[  OK  ] Started systemd-logind.service - User Login Management.
[  OK  ] Reached target multi-user.target - Multi-User System.
[  OK  ] Reached target graphical.target - Graphical Interface.
Debian GNU/Linux 12 distrobuilder-... console
```
getty 起在 ttyAMA0，`console-getty.service` 和 `getty@tty1.service` 都 active。

**系统是真的**：glibc 2.36、241 个包、`bash 5.2.15`、`systemd 252`、
`/bin/ls` 动态链接完整。

### 网络

virtio-net 接上 libslirp（从 WindowsPixel 借的 vendored v4.8.0，它已把 glib
剥成单头垫片，直接编译进来）。要点是**必须调 `hv_net_attach` 并每 tick 调
`hv_net_poll`**——只注册设备不接后端，eth0 会显示 up 但网线另一端是空的。
我第一版就是这样：ping 网关 100% 丢包。

实测：

| 指标 | 结果 |
|---|---|
| ping 网关 10.0.2.2 | 1 received |
| ping 外网 1.1.1.1 | 时通时不通（见下） |
| `curl` 清华镜像（HTTP，TCP） | **HTTP 200，149266 B，0.38 s** |
| DNS 解析 deb.debian.org | 正常 |
| 大文件吞吐（清华镜像 11 MB） | **10.6 MB/s** |
| 小请求（deb.debian.org，10 次） | 15.7 s → ~1.6 s/请求 |
| 小请求（清华镜像，5 次） | 2.5 s → **0.51 s/请求** |
| 小请求（清华镜像，按 IP 直连） | 2.2 s → **0.44 s/请求** |
| `apt-get update`（deb.debian.org） | 80 s / 691 kB |
| `apt-get update`（清华镜像） | **16.6 s** |

**ICMP 不可靠，TCP 正常**：`ping` 外网时而 1 received、时而 0 received。
slirp 的 ICMP 要宿主的 raw/ping socket，在非特权 Android 上拿不到；
TCP 走的是普通 connect，所以一直正常。**验收判据因此改用 HTTP 状态码**，
不用 ping——这不是链路故障，是用户态 NAT 的固有限制。

**逐请求延迟的归因（做了对照，结论被修正过一次）**：
按 IP 直连 0.44 s vs 按域名 0.51 s —— **DNS 只占 0.07 s，不是瓶颈**。
真正的差别是对端：同一套 virtio-net 到 `deb.debian.org` 是 1.6 s/请求，
到清华镜像 0.5 s。所以那是**海外 RTT**，不是虚拟网卡的问题。
（我一开始猜"可能是 virtio kick 与 slirp 线程的往返"，用 IP/域名对照否掉了。）

apt 慢在要发几十个独立请求，乘以单请求 RTT，不是带宽问题——
换镜像后 80 s → 16.6 s 就是证据。

### 在客户机里装编译器并编译

```
apt-get update: 16.6 s
Setting up binutils (2.40-2)
Setting up gcc-12 (12.2.0-14+deb12u1)
Setting up gcc (4:12.2.0-3)
install: 43.0 s

=== compile inside the guest ===
gcc works, sum=21065.833111
gcc: gcc (Debian 12.2.0-14+deb12u1) 12.2.0
```

一个没有 KVM、跑在手机上的翻译器里，`apt` 装出 12 MB 的 gcc 工具链并编译
运行了程序。这是目前最强的"活系统"证据。

### 这一轮我自己的两个 bug

1. **cmdline 解析死循环**：`for (char *p = line; *p; ) { ... p = e; }` 里
   当 `e` 停在行尾 `'\n'` 上时 `e == p`，`p` 不前进 → 无限循环。
   `/proc/cmdline` 恒以 `'\n'` 结尾。有 `root=`/`init=` 时提前 `break` 所以
   看不出来，一旦扫到行尾就挂死。症状极具误导：日志停在某个标记之后就没了，
   而 watchdog 显示 guest 在 **EL0**（用户态）原地打转——说明内核没问题，
   是我的 init 自己的死循环。
2. **`if (0) dprintf(...)` 把 `mount()` 一起塞进死分支**：为了静音调试输出
   加的前缀，结果 `mount("proc", ...)` 这些调用整个没执行，`/proc` 缺失。

### 与参考实现的对照

`src/WindowsPixel` 是同一引擎的 Linux/Android 移植。对照后确认：

- 8 MB 栈和 1 ms kicker **原项目本来就有**，是我移植时漏了（他们保留着）
- `ID_AA64ISAR1` 谎报 SB 他们**没处理**——他们跑的是 Windows，Windows 不用
  `sb`；这是 Linux 客户机才暴露的，属于我这边的发现
- 他们的计数器换算更严谨（60 位定点 + 舍入 + 减基数），且把
  `mrs cntvct_el0` 直接内联进 JIT；我用零页垫片让它走 helper，
  功能对但多一次调用

### 还没做

- **图形**（按要求不做）：要图形得新写 virtio-gpu，引擎里没有。
- **多核长时间压力**：4 核能起到用户态并干净关机，没做持续负载验证。
- **9p / virtio-fs 共享目录**：现在往客户机里放文件只能靠 `cp` 进 initramfs。
- **计数器内联**（见上）：要极致性能就得改 `translate.c`，会破坏"原树只读"。

### 最终验收（4 vCPU，一条命令跑完）

```
 Debian 12 arm64 — NVMe root, systemd, network, no KVM
--------------------------------------------------------------
  OS      : Debian GNU/Linux 12 (bookworm)
  kernel  : 6.12.0  (aarch64, 4 vCPU)
  rootfs  : ext4   /dev/nvme0n1p2
  disk    :   4G QEMU NVMe Ctrl
  packages: 283
  systemd : systemd 252 (252.39-1~deb12u2)
  net     : inet 10.0.2.15/24
  http    : HTTP 200 149266B in 0.382986s
--------------------------------------------------------------
 toolchain already installed by apt (previous run), verify it works:
  gcc (Debian 12.2.0-14+deb12u1) 12.2.0
  compiled and ran inside the guest: sum=21081692.746152
--------------------------------------------------------------
 translator speed measured inside this real Debian:
  alu         6.12 ns/iter
  call        5.77 ns/iter
--------------------------------------------------------------
 clean shutdown via PSCI:
[    7.044724] reboot: Power down
```

核心数 1 / 2 / 4 都验证过，用户态、网络、编译、关机一致。
`alu 6.12` 与 Alpine 环境里的 6.0 吻合——**客户机用什么发行版不影响翻译器速度**，
说明测到的是引擎本身的特性。

---

## 八、passt 后端：能做，但在这台设备上要先拆掉它三层隔离

### 结论先说

**passt 在这台无 root、无 `CONFIG_USER_NS`、SELinux enforcing 的 Android 上
跑起来了**，而且完整实现了 DHCP → DNS → HTTP 200 的链路。
但吞吐异常（详见下文），所以默认仍是 slirp，`HV_NET=passt` 可切换。

值得注意的是 **passt 不需要 `/dev/net/tun`**（那是 pasta 才要的）。
它跟 hypervisor 之间走一个已连接的 UNIX socket，帧格式是
`[4 字节大端长度][以太网帧]` —— 和我们的 virtio-net 接口正好对齐。

### 先证伪了"需要 tun/userns"

```
open /dev/net/tun      : Permission denied     (属 system:vpn, 660)
unshare(USER|NET)      : Invalid argument      (内核无 CONFIG_USER_NS)
unshare(NET) alone     : Operation not permitted
```

看上去 passt 没戏。但读它的文档才知道：**passt 用 `--fd` 接一个
socketpair，完全不碰 tun**。所以上面三条都不是死路。

### 移植 passt 到 bionic 的六处改动

| # | 位置 | 问题 | 处理 |
|---|---|---|---|
| 1 | `ip.h` | `struct ipv6hdr`/`ipv6_opt_hdr` 与 bionic 重复定义 | `#if !defined(__ANDROID__)` |
| 2 | `tcp.c` | `tcp_repair_opt` 等与 bionic `<linux/tcp.h>` 重复 | 条件里加 `!defined(__ANDROID__)` |
| 3 | `isolation.c` | `!ns_is_init() && !geteuid()` 短路顺序错，非 root 也去读 `/proc/self/uid_map` → die | 交换两个条件（语义等价） |
| 4 | `util.c` | `ns_is_init()` 读不到 uid_map 就 die | 改成返回 false |
| 5 | `conf.c` | passt 模式硬性要求 userns | 加 `HV_PASST_NO_USERNS` |
| 6 | `passt.c` / `isolation.c` | `unshare(IPC\|NS\|UTS\|PID)` 要 CAP_SYS_ADMIN | 加 `HV_PASST_NO_SANDBOX` / `HV_PASST_NO_SECCOMP` |

> **2026-11-16 修订**：上表第 1/2/5/6 条的开关名与实际代码不符，且漏了一处关键的
> SIGSYS 来源。重新打补丁后的**准确清单**见本节末「四个开关」小节 —— 之前
> `HV_PASST_NO_SECCOMP` 设了也不生效，因为 `close_range()` 更早就把进程杀了。

第 6 条里的 seccomp 是**最隐蔽的一个**：passt 装完 seccomp 后，
处理第一个 TCP SYN 时被 **SIGSYS（signal 31）** 打死。
它自己的白名单是按 glibc 的调用模式生成的，bionic 下会调到名单外。
症状是"进程静默消失，socket 变 EPIPE"。

兼容头 `work/passt-compat/android_compat.h` 补齐了 `MAXNS`、`MAXDNSRCH`、
`_PATH_LOG`、`IPV4_MIN_MTU`、`struct udphdr`、`vring_need_event`，
并把 `IN6_IS_ADDR_*` 换成带 cast 的实现（bionic 的版本不带 cast，
passt 会把这些宏用在它自己的 `union inany_addr *` 上，编不过）。

### 两个"看起来像 bug 其实是配置"的坑

1. **DNS**：Android 没有 `/etc/resolv.conf`（netd 管），passt 报
   `Couldn't get any nameserver address`，于是 DHCP 不下发 DNS，
   guest 沿用上一次 lease 里的 `10.0.2.3`（slirp 时代的地址）→ curl 卡在解析
   25 秒看着像 TCP 不通。显式 `-D 223.5.5.5` 解决。
2. **地址模板**：passt 在 shell 域读不到完整接口信息，退化成
   `169.254.2.1/8` link-local，和网关 192.168.1.1 不同网段 → DHCP 能成但包出不去。
   hv-linux 自己用 `getifaddrs()` 探一遍宿主，给 passt 传同网段地址
   （实测 `192.168.1.134/24, gw 192.168.1.1`）。

### 打通了，但吞吐有问题

```
DHCPACK of 192.168.1.134 from 192.168.1.1      ✅
dns: nameserver 223.5.5.5
resolve: mirrors.tuna.tsinghua.edu.cn          ✅
HTTP 200 11026B 25.00s                          ⚠️ 收满 25 秒超时
throughput: 914 B/s                             ⚠️
```

对照：同一个 guest、同一个 URL，**slirp 后端是 10.6 MB/s、0.38 秒**。

诊断数据（`HV_NET_STATS=1`）：

```
[net] rx=84  tx=72 sent=72 DROP=0 nobuf=10765
[net] rx=90  tx=72 sent=72 DROP=0 nobuf=10765
```

- `DROP=0`：队列没溢出
- `nobuf` 在 `rx=84` 之后就不再增长 → 那一万多次是**启动早期驱动还没就绪**
  时累积的（`hv_virtio_net_receive` 在 `DRIVER_OK` 未设时返回 0），不是传输期的问题
- `rx=90, sent=72`：90 个帧从 passt 收进来、72 个发出去，数据量约 135 KB，
  正好是 `Release` 文件的九成

也就是说**数据基本传完了，卡在收尾**（连接没有正常关闭，curl 等到超时）。
这需要进一步看 virtio-net 的 used-ring 交互——引擎的 `notify()` 在
`q != TXQ` 时直接 return（注释写着 "new receive buffers: nothing waiting to
deliver"），这个假设在"主机侧随时有帧待投递"时就站不住了。slirp 因为慢，
几乎不会让队列里积着帧，所以从没暴露。

### 2026-11-16：SIGSYS 的真正死点定位（二分法）

之前 `./passt --version` 直接 `rc=159`（128+31=SIGSYS），**零输出**，看着像
"链接或架构问题"。用 `fprintf(stderr, ...)` 在 `passt.c` 的 `main()` 里逐点打桩，
两个安全域对照跑，一次定位：

| 位置 | Termux 域 `Seccomp:2` | adb shell 域 `Seccomp:0` |
|---|---|---|
| `clock_gettime` | 过 | 过 |
| `arch_avx2_exec` | 过（aarch64 上是空实现） | 过 |
| `isolate_initial` | **过** | 过 |
| `isolate_fds` ← | **死在这里** | 过 |
| `conf_mode` / `madvise` / `epoll` / `setrlimit` | — | 全过 |

死点是 `isolate_fds()` 里的 `close_range(close_from, ~0U, CLOSE_RANGE_UNSHARE)`。
原代码只兜 `errno == ENOSYS || EINVAL`：

```c
if (close_range(...)) {
    if (errno == ENOSYS || errno == EINVAL) {
        warn("Can't use close_range() ...");   /* 兜底 */
    } else {
        die_perror("Failed to close files leaked by parent");
    }
}
```

但 Android 的 app seccomp filter 对这个 syscall 是**直接 SIGSYS 杀掉**，
进程根本没机会检查 errno —— 兜底分支永远到不了。
（在 vivo 的 adb shell 域能看到那句 `Can't use close_range()` 警告，因为那里
`Seccomp:0`，syscall 能进去并正常返回 ENOSYS。）

修法：`HV_PASST_NO_CLOSE_RANGE` 用循环 `close()` 替代。fd 表很小，
`CLOSE_RANGE_UNSHARE` 只在多线程共享表时才有意义，而 `main()` 这个阶段是单线程。

### 四个开关（准确清单）

编译必须带全四个，缺一个就是一次 SIGSYS 静默死亡：

| 宏 | 拦的是什么 | 出处 |
|---|---|---|
| `HV_PASST_NO_CAPDROP` | `capget`/`capset`/`PR_CAPBSET_DROP` 被 seccomp 杀 | `drop_caps_ep_except()` **和** `clamp_caps()`，**两处**都要关 |
| `HV_PASST_NO_USERNS` | `ns_is_init()` 读不到 `/proc/self/uid_map` 就 `die()` | `isolate_initial()` |
| `HV_PASST_NO_SECCOMP` | passt 自己的白名单按 glibc 生成，bionic 下第一个 SYN 就死 | `isolate_prefork()` |
| `HV_PASST_NO_CLOSE_RANGE` | `close_range(2)` 杀成 SIGSYS（不是 ENOSYS），兜底到不了 | `isolate_fds()` **← 本次新增，最关键** |

补丁文件在 `work/passt-android-patches/`，`work/build_passt.sh` 已带上全部四个宏。

### 验收（两个安全域都必须是 rc=0）

```
OPPO PDYT20 · Termux 域  Seccomp:2  ->  ./passt --version  rc=0  ✅
vivo V2156FA · adb shell 域 Seccomp:0 ->  ./passt --version  rc=0  ✅
```

注意**同一份二进制**在两个域都要过：`Seccomp:0` 只能证明代码能跑，
`Seccomp:2` 才证明绕开了 Android 的 app 沙箱。只测前者会漏掉这一类问题。

### 2026-11-16（续）：六开关全齐，passt 真正跑起来了，并接进 QEMU

前一节四个开关只是让 `--version` 过关。**实际运行路径还有两处 SIGSYS**，
用 `si_syscall` 直接读出号码（Android 用 `SECCOMP_RET_TRAP`，会递送 SIGSYS）：

```
[sigsys] syscall=159 arch=3221225655   -> aarch64 __NR_setgroups
[sigsys] syscall=144 arch=3221225655   -> aarch64 __NR_setgid
```

于是补上：

| 宏 | 拦的是什么 | 位置 |
|---|---|---|
| `HV_PASST_NO_SETGROUPS` | `setgroups(0, NULL)` | `isolate_user()` |
| `HV_PASST_NO_SANDBOX` | `unshare(IPC\|NS\|UTS\|PID)` 需 CAP_SYS_ADMIN；`clone(CLONE_NEWUSER)` 返回 EINVAL；`setgid`/`setuid` 被拦 | `isolate_prefork()` 整体跳过、`isolate_user()` 整段 return |

理由都是同一个：**app 上下文 `CapEff=0`，本来就是非特权 uid，
既没有权限可掉、也没有权限可切**，这些调用除了撞 seccomp 没有任何作用。

判定"真跑起来了"的判据是 `rc=124`（被 `timeout` 杀死 = 存活），不是 `rc=0`。
`--version` 只走到 `conf()` 之前，**不能用来验证运行路径**——这是本轮最大的教训。

```
UNIX domain socket bound at /data/.../passt.sock
You can now start qemu (>= 7.2, with commit 13c6be96618c):
    kvm ... -device virtio-net-pci,netdev=s \
        -netdev stream,id=s,server=off,addr.type=unix,addr.path=/data/.../passt.sock
```

### 接进 QEMU：`-netdev stream`，零改动

passt 自己把客户端命令行都打出来了，QEMU 侧不需要任何新代码：

```sh
# 1) 先在设备上常驻 passt（同网段地址，否则 DHCP 能成但包出不去）
./passt -f -q --socket ~/h/passt.sock \
    -a 192.168.1.134/24 -g 192.168.1.1 -D 223.5.5.5

# 2) QEMU 连过去
qemu-system-aarch64 ... -netdev stream,id=s,server=off,addr.type=unix,addr.path=$HOME/h/passt.sock \
    -device virtio-net-pci,netdev=s
```

Debian 12 guest 实测（`-M virt,gic-version=3 -smp 2`）：

```
cloud-init: enp0s1  192.168.1.134/24   gw 192.168.1.1   DNS 223.5.5.5
            （真实局域网地址，不是 slirp 的 10.0.2.15）
6 × curl Packages.xz(8.69 MB)，全部 http=200
  r1 295,033 B/s   r2 364,260 B/s   r3 7,602,669 B/s
  r4 264,726 B/s   r5 539,993 B/s   r6 244,333 B/s
  → 5/6 轮约 0.3 MB/s，仅 1 轮 7.6 MB/s
```

**功能通了，但吞吐仍差**（slirp 同条件是 4.9–8.5 MB/s）。归因见下节 ——
**这不是 QEMU 的问题，是我们自己引擎的 `notify()` 设计问题。**

passt 目前**可用但默认不启用**，`HV_NET=slirp` 仍是默认。

#### 归因三次更正：最终结论是「我们给了 passt 一个宿主不拥有的地址」

这里先后给过三个错误归因，全部作废，按证据重排：

| # | 当时的说法 | 为什么错 |
|---|---|---|
| 1 | "QEMU virtio-net 对高速后端的已知瓶颈" | 网卡是 QEMU 原版没错，但这不是它的毛病 |
| 2 | "我们自己引擎 `devices/virtio_net.c` 的 notify() 拉模型" | **那份代码在 QEMU 移植里根本不参与**。移植的 NIC 是 `hw/net/virtio-net.c`（QEMU 原版，零 henge 引用），我们只提供 accel 和 net backend |
| 3 | "accel 的 MMIO doorbell 往返太慢" | **被 TCG 对照否掉**，见下 |

**关键对照实验（同一个 passt、同一个 `-netdev stream`，只换加速器）：**

| 轮次 | henge + passt（真地址） | TCG + passt（真地址） |
|---|---|---|
| r1 | 295 K | 175 K |
| r2 | 364 K | 106 K |
| r3 | 7.60 M | 259 K |
| r4 | 265 K | 3.06 M |
| r5 | 540 K | 128 K |
| r6 | 244 K | 8.44 M |

**两套加速器是同一个双峰形态，TCG 甚至更差。** 加速器被彻底排除；
既然两套 accel 表现一致，QEMU 的 virtio-net 也不可能是"对某一方特别差"。

**真正的变量是 passt 的地址参数。** 把 `-a 192.168.1.134/24 -g 192.168.1.1`
去掉，让 passt 用自己默认的网段：

| passt 配置 | 6 轮吞吐 | 形态 |
|---|---|---|
| `-a 192.168.1.134/24 -g 192.168.1.1` | 295K / 364K / 7.60M / 265K / 540K / 244K | **双峰** |
| 默认（不给 `-a` / `-g`） | **6.02M / 8.82M / 7.10M / 4.85M / 8.20M / 7.68M** | **全轮正常** |

guest 侧地址从 `192.168.1.134/24` 变成 `169.254.2.1/8`（passt 的默认回退），
**双峰完全消失，且中位数比 slirp（4.9–8.5 MB/s）还略好。**

原因：`192.168.1.134` 是**宿主 wlan0 上不存在的地址**。passt 拿到一个自己不拥有的
地址后，必须为它做 ARP/邻居代理，失败的连接走超时重传——这就是"5 轮 0.1–0.5 MB/s、
1 轮 3–8 MB/s"双峰的来源。它跟加速器、跟 virtio-net、跟 doorbell 开销都无关。

这也解释了旧记录里 hv-linux 那次为什么只有 **914 B/s**：同一个参数错误，
两次踩了同一个坑。所以那个"已知且长期存在的瓶颈"**不存在**。

#### 那 doorbell 开销到底存不存在？

存在，但**不是这条路上的主要矛盾**。两套实现的对比很清楚：

| | WindowsiOS 引擎 | 我们的 QEMU 移植 |
|---|---|---|
| doorbell 从哪来 | `devices/virtio.c:141`，`common_write()` 处理 NOTIFY 偏移时**同步**调 `v->notify(v,q)` | guest 写 MMIO → accel 陷入 → 拿 BQL → `virtio_queue_notify` → `virtio_net_handle_rx` → `qemu_flush_queued_packets` |
| 往返层数 | 0（就在 MMIO 处理函数里） | 3–4 层，且跨 BQL |
| 是否可优化 | — | 可以（见下），但**优先级低** |

所以"WindowsiOS 把 doorbell 消化掉了"这个观察是对的，但**它不是当前吞吐问题的解**。
把地址参数改对之后，同一份带 BQL 往返的实现已经能跑到 8.8 MB/s。

#### 想进一步绕开，可选的路（按代价排序）

1. **`-netdev user`（slirp）**：同步路径，天然不依赖 doorbell 往返，
   实测 4.9–8.5 MB/s。**当前默认，够用。**
2. **多队列**（`mq=on,vectors=N` + `-netdev stream`）：把 doorbell 压力摊到多队列，
   不改代码，值得一试但收益有限（单流 TCP 用不上多队列）。
3. **vhost-user-net**：真·绕过 QEMU datapath，guest 直接和 passt 共享 vring。
   但**这棵树（QEMU 11.1.3）里没有 `vhost-user-net` 设备**——`hw/net/` 完整的 47 个
   文件里只有 `vhost_net.c`（内核 vhost），`grep -r vhost-user-net` 全树零命中。
   passt 侧 `--vhost-user` 是有的，但要补 QEMU 设备源码，代价远超收益。
4. **改 accel 让 doorbell 免 BQL**：技术上可行（`common_write` 那种同步语义），
   但既然 slirp 已达标、passt 在正确配置下也达标，**按决定不动**。

### 为什么还是值得留着

- 证明了**不需要 tun、不需要 userns** 也能在受限 Android 上跑 passt，
  这本来是这类移植最大的障碍
- passt 用宿主内核的 TCP socket，少一整套用户态协议栈；
  吞吐问题修好后会明显优于 slirp
- 代码是独立文件（`host/net_passt_linux.c`），`HV_NET=slirp` 一键回退，
  不影响已验证的路径

---

## 整理目录时又揪出两个真 bug

这两个都是"看起来在正常工作、其实结果一直是错的"的类型，值得记一笔。

### 1. `mach_timebase_info` 返回 1/1，所有基于它计时的地方都小了 41.67 倍

`compat/mach/mach_time.h` 里把 `mach_absolute_time()` 映射到
`hv_host_ticks_24mhz()`，但 `mach_timebase_info()` 返回的是 `numer=1, denom=1`。
于是 `mach_absolute_time() * numer / denom / 1e6` 算出来的"毫秒"
**实际是微秒**，偏差正好是 1e9/24e6 = 41.67。

怎么发现的：原项目自带的 `test_bench` 报 `bench_loop` 跑 1M 次迭代用 0.031 ms。
1M 次两指令循环在 2.2 GHz 上不可能只花 3 万周期 —— 差了两个数量级，
顺着 `now_ms()` 查下去就找到了。

修法：`numer=125, denom=3`（= 1e9/24e6 的精确分数）。
修好后 `bench_loop` native = 1.083 ms，和手算的 1M 周期一致。

**教训**：跨平台垫片里的"常数"必须验证量纲，不能看着能跑就放过。
这个坑只在统计/基准路径上显现，功能路径一切正常，所以很容易带进结论里。

### 2. Mach-O→ELF 转换器把 C 宏里的 `##_` 也当成符号前缀删了

`tools/patch_macho_asm.py` 的任务是去掉 Mach-O 符号的前导下划线
（`_foo` → `foo`）。它的正则会把任意 `_identifier` 的前导下划线吃掉，
于是 `harness.h` 里的

```c
#define DECLARE_PROGRAM(n) extern const char n##_native[], n[], n##_end[]
```

被改成 `n##native` / `n##end`，`DECLARE_PROGRAM(bench_calls)` 展开成
`bench_callsnative` —— 链接期报"undefined symbol: bench_callsend"。

之前没暴露是因为 `build_tests.sh` 编的 .c 文件在 `src/tests/` 里，
`#include "harness.h"` 先命中**源文件同目录**的未打补丁版本；
而新加的 `tests/test_bench_ext.c` 在 `port-android/tests/` 里，
才第一次用到打补丁后的那份。

修法：在做通用替换前先把 `##_` 保护起来（和已有的 `\()_` 同一种手法）。

**教训**：文本级改写代码的工具，必须把"语法上下文"列全。
只保护了汇编宏的 `\()_`，漏了 C 的 `##_`，就是漏了一种上下文。
