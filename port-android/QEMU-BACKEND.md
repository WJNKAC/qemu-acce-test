# QEMU 后端移植方案（针对 qemu-mainline v11.1.3）

> 结论先行：**技术路径通畅，且我们的软件 MMU 可以原样保留**。
> 因为 `AccelOpsClass` 只接管"vCPU 怎么跑"，不碰 guest 页表 —— 我们的
> `hv_mmu_walk` 读的是 guest RAM 里 guest 自己建的页表，在 QEMU 下同样成立。
> 真正要换的只有一件事：**"guest PA → host 指针"由谁提供**。
>
> 成本集中在**设备模型下线**（`devices/` 几乎全部让位，GIC 最难），
> 而这恰好是接入 QEMU 唯一真正买到的东西（生态）。所以这是个**产品化决策**，
> 不是性能决策 —— 与 linear map / whint 主线正交。

## 1. 接口清单：QEMU 要什么，我们有什么

### 1.1 `AccelClass`（`include/accel/accel-ops.h`）

| 钩子 | 必需 | 我们的对应物 | 工作量 |
|---|---|---|---|
| `name` | 是 | `"Henge"` / `"Hv"` | 1 行 |
| `init_machine(as, ms)` | 是 | 建 `HvMachine`（但不建 RAM，见 §2.2） | 小 |
| `setup_post(as)` | 否 | 启动 vCPU 线程前的一次性动作 | 小 |
| `cpu_common_realize/unrealize` | 否 | 每 vCPU 初始化 `HvCpu` | 小 |
| `allowed` | 是 | `-accel hv` 的许可位 | 1 行 |
| `has_memory` | 否 | 直接返回 true（我们用 QEMU 的 RAM） | 无 |

### 1.2 `AccelOpsClass`（`include/accel/accel-cpu-ops.h`）

| 钩子 | 必需 | 我们的对应物 | 状态 |
|---|---|---|---|
| `create_vcpu_thread` | **强制** | 自建线程跑 `hv_run(cpu)` | **要写**，模板见 §2.1 |
| `kick_vcpu_thread` | 否 | `hv_cpu_wake()`（`exit_req=1; sev`） | **现成** |
| `handle_interrupt` | **强制** | `generic_handle_interrupt` + 上面那个 kick | **现成** |
| `cpu_thread_is_idle` | 否 | `cpu->halted`（我们有 `wfi` 计数） | 1 行 |
| `synchronize_state` | 否* | `HvCpu` → `CPUARMState` 回写 | **要写**，见 §2.4 |
| `synchronize_post_reset/init` | 否* | `CPUARMState` → `HvCpu` 写入 | **要写** |
| `cpu_target_realize` | 否 | 校验 target 是 aarch64 | 小 |
| `get_virtual_clock` | 否 | `cntvct_el0` 已是我们的时基 | 现成 |

\* 单跑可以用空实现；但要 monitor / gdbstub / `info registers` 就必须实现。

### 1.3 别的后端怎么做（三种形态，我们属于第二种）

| 后端 | vCPU 由谁跑 | 对我们的参考价值 |
|---|---|---|
| `nitro`（284 行，最新） | 内核（`dummy_start_vcpu_thread`） | 只参考 `AccelClass` 的骨架，vCPU 部分不适用 |
| `whpx`（113 行 ops） | QEMU 线程里调 `whpx_vcpu_exec` | **最接近**：结构就是 `do { cpu_can_run → exec } while` |
| `mttcg` | QEMU 线程，**执行期放掉 BQL** | **必读**：解决"引擎多线程 vs QEMU 全局锁" |

### 1.4 `AccelCPUClass`：ARM 上**不需要**（这是个好消息）

i386 / riscv / ppc 有 per-target 的 `AccelCPUClass`（`target/i386/kvm/kvm-cpu.c` 等），
但 **ARM 没有**。ARM 走的是全局判断（`target/arm/cpu.c`）：

```
673:  if (kvm_enabled())      { ... }
678:  if (tcg_enabled())      { ... }
1292: if (tcg_enabled() || hvf_enabled()) { ... }
```

所以我们要加的是同一形状的东西：

```c
/* include/system/hv-accel.h —— 照抄 include/system/nitro-accel.h 的 25 行 */
extern bool hv_allowed;
static inline bool hv_enabled(void) { return hv_allowed; }
#define TYPE_HV_ACCEL ACCEL_CLASS_NAME("hv")
```

然后在 `accel/hv/hv-accel.c` 的 class_init 里挂 `ac->allowed = &hv_allowed;`
（`-accel hv` → `accel_find("hv")` → 找 `"hv-accel"` 这个 TypeInfo 名字）。

**在 `arm_cpu_realizefn` 里加一个 `hv_enabled()` 分支**：因为我们的引擎
自己实现软件 MMU + GIC，ARM CPU 只需要把 `CPACR_EL1`、`MIDR`、feature 位设对，
**不走 KVM 那套 ioctl**。最省事的写法是复用 `tcg_enabled()` 的分支（我们也需要
完整 CPU 模型），只跳过 TCG 特有的 translator 初始化。

## 2. 四个关键设计点

### 2.1 vCPU 线程：照抄 MTTCG 的锁序（这是能否多核的关键）

QEMU 的 BQL 是全局锁。我们的引擎每个 vCPU 一个线程、各自有 TLB。
如果每个 vCPU 都持 BQL 才能跑，SMP 就退化成串行。

**MTTCG 已经给出了答案**（`accel/tcg/tcg-accel-ops-mttcg.c:89-116`）：

```c
do {
    qemu_process_cpu_events(cpu);
    if (cpu_can_run(cpu)) {
        bql_unlock();              /* ← 执行期间不持锁 */
        r = tcg_cpu_exec(cpu);
        bql_lock();
        switch (r) {
        case EXCP_DEBUG:  cpu_handle_guest_debug(cpu); break;
        case EXCP_ATOMIC: bql_unlock(); cpu_exec_step_atomic(cpu); bql_lock(); break;
        ...
        }
    }
} while (!cpu->unplug || cpu_can_run(cpu));
```

我们照这个形状写，把 `tcg_cpu_exec` 换成我们的：

```c
static void *hv_cpu_thread_fn(void *arg)
{
    CPUState *cpu = arg;
    rcu_register_thread();
    bql_lock();
    qemu_thread_get_self(cpu->thread);
    cpu->thread_id = qemu_get_thread_id();
    current_cpu = cpu;
    hv_vcpu_attach(cpu);                 /* HvCpu 挂到 CPUState 上 */
    cpu_thread_signal_created(cpu);
    qemu_guest_random_seed_thread_part2(cpu->random_seed);

    do {
        qemu_process_cpu_events(cpu);
        if (cpu_can_run(cpu)) {
            bql_unlock();                /* ← 同一把锁、同一个顺序 */
            int r = hv_run(hv_cpu_of(cpu));   /* 引擎自己的退出码 */
            bql_lock();
            hv_dispatch_exit(cpu, r);    /* MMIO / WFI / DEBUG / IRQ，见 §2.3 */
        }
    } while (!cpu->unplug || cpu_can_run(cpu));

    cpu_thread_signal_destroyed(cpu);
    bql_unlock();
    rcu_unregister_thread();
    return NULL;
}
```

**为什么这样安全**：`bql_unlock()` 期间引擎访问的是 guest RAM（QEMU 的
MemoryRegion host 指针）和它自己的 TLB；QEMU 侧任何会改内存布局的操作
（`region_add/del`）都持 BQL，且会回调我们的 listener → flush TLB（§2.2）。
这与 MTTCG 的假设完全一致。

### 2.2 内存：让 QEMU 拥有 RAM，我们只镜像 PA→host

这是整个移植的**核心改动**，也是最优雅的一点：

```
                    改之前                       改之后
  RAM 所有权      linuxvirt.c 自己 mmap      QEMU 的 MemoryRegion
  PA→host         HvRam{pa,size,host}        HvRam{pa,size,host}（内容来自 listener）
  VA→PA           hv_mmu_walk（读 guest 页表）  ← 完全不变
```

`MemoryListener` 的两个钩子就够了：

```c
static void hv_region_add(MemoryListener *l, MemoryRegionSection *s)
{
    if (!memory_region_is_ram(s->mr)) return;          /* MMIO 走 §2.3 的陷阱 */
    void *host = memory_region_get_ram_ptr(s->mr) + s->offset_within_region;
    hv_machine_add_ram(m, s->offset_within_address_space,
                       int128_get64(s->size), host,
                       memory_region_is_rom(s->mr));
}

static void hv_region_del(MemoryListener *l, MemoryRegionSection *s)
{
    hv_machine_del_ram(m, s->offset_within_address_space, int128_get64(s->size));
    hv_tlb_flush_all_cpus(m);          /* 我们已有 7 条 flush 路径，挂最全的那条 */
}
```

**为什么这是对的**：QEMU 的 NVMe / virtio 设备做 DMA 时写的是同一块
`MemoryRegion` 的 host 内存；我们的软件 MMU 给出的 addend 也指向它。
两边看到的是**同一份字节**，不需要拷贝，也不需要 shadow。

**必须做的一件事**：`region_del` 后不只是 flush TLB，还要让
`code_pages` / `page_gen` 失效（否则 SMC 的作废链会指向已释放的页）。
这条正好复用第六轮建立的机制。

### 2.3 MMIO：在 `hv_mmio_lookup` 之前插一层"转给 QEMU"

我们的引擎现在遇到未映射 PA 就查自己的 `m->mmio[]`。接 QEMU 后：

```c
/* machine.c: hv_phys_read / hv_phys_write 的 HvMmio 分支之前 */
if (m->qemu_mmio) {                    /* runner 注册的回调 */
    MemTxResult r = address_space_rw(&address_space_memory, pa,
                                     MEMTXATTRS_UNSPECIFIED, buf, len, is_write);
    return r == MEMTX_OK ? 0 : -1;
}
```

`address_space_rw` 会分发到 QEMU 的 `MemoryRegionOps`（PL011、GIC、NVMe……），
**BQL 必须持着** —— 而 `hv_dispatch_exit` 正好在 `bql_lock()` 之后被调用（§2.1）。

这一层一插，我们 `devices/` 里的 pl011 / pl031 / nvme / virtio 就**全部可以删掉**。

### 2.4 寄存器双份：`HvCpu` vs `CPUARMState`

QEMU 的 monitor、gdbstub、migration 都读 `CPUARMState`（`cpu->env_ptr`）；
我们的引擎跑的是 `HvCpu`。两者必须同步：

- `synchronize_state(cpu)`：`HvCpu` → `CPUARMState`（monitor 读之前调）
- `synchronize_post_reset/init(cpu)`：`CPUARMState` → `HvCpu`（reset / loadvm 之后调）

**这是可以偷懒但会付代价的地方**：只同步 PC + x0..x30 + SP + PSTATE 就够
`info registers` 用；但 `migration` / `snapshot` 需要全量（含系统寄存器）。
建议第一版只做前者，并在文档里写明 snapshot 不支持 —— 不要假装支持。

## 2.5 ⚠️ 最隐蔽的洞：DMA → SMC（比 GIC 隐蔽，且现在写进去）

现在的栈里设备 DMA 走我们自己的路径，`whint` / `page_gen` 看得见。
QEMU 下设备走 `dma_memory_rw` → `address_space` → **直接 memcpy 进 RAMBlock**，
引擎全程不可见：guest 加载模块、解压后执行，全部变成**静默 SMC**。

TCG 的解法在 `system/physmem.c` 的 notdirty 写拦截。查了安装条件，**它确实是 TCG 独占的**：

```
:1263   if (tcg_enabled()) {
:1264       qatomic_or(&blocks[DIRTY_MEMORY_CODE][idx][offset], temp);
:1265   }
...
:3140   if (dirty_log_mask & (1 << DIRTY_MEMORY_CODE)) {
:3141       assert(tcg_enabled());
:3142       tb_invalidate_phys_range(NULL, addr, addr + length - 1);
:3143   }
```

所以 `-accel hv` 下 DMA 写**不会**触发任何失效。

两条路（都要改核心文件，见下）：

- **(a) 复用同一个 `DIRTY_MEMORY_CODE` 位**：把 `hv_enabled()` 加进 `:1263` 的条件，
  并把 `:3142` 的 `tb_invalidate_phys_range` 换成/加上我们的 `hv_invalidate_code`。
  好处是与 TCG 共享"page 含 code"的判定；坏处是 `assert(tcg_enabled())` 要改。
- **(b) `physmem.c` 加一个 `hv_enabled()` 分支**：在 `physical_memory_set_dirty_range`
  末尾，对 hv 走我们的 `hv_invalidate_code(m, pa)`。

> **修正一句之前说过的话**：`QEMU-BACKEND.md` 早先写"全程不需要改 QEMU 的公共头"。
> 更准确的说法是：**不改公共头，但可能要改一处核心 `.c`**（`system/physmem.c`）。
> 这不是可选项 —— 不改就是静默数据损坏。

**验收**：`test_smc_mp` 加一个 DMA 变体（写入方从"另一个 vCPU"换成
QEMU 侧的 `cpu_physical_memory_write` / `address_space_rw`）。
step 0 测不到（没有设备），但现在就写进本文件。

## 3. 真正的坑：设备模型下线（按难度排）

| 设备 | 我们的文件 | 换成 QEMU 的 | 难度 |
|---|---|---|---|
| PL011 / RTC / GPIO | `pl011.c` `pl031.c` `pl061.c` | `hw/char/pl011.c` 等 | 小，`-M virt` 自带 |
| NVMe | `nvme.c` | `hw/nvme/` | 小 |
| virtio-blk/net/input/snd | `virtio*.c` | `hw/virtio/` | 中（后端要换成 QEMU 的 netdev） |
| PCIe | `pcie.c` | `hw/pci-host/gpex.c` | 中 |
| **GICv3 + ITS** | `gicv3.c` | `hw/intc/arm_gicv3*.c` | **大，见下** |
| 设备树 | `fdt_linux.c` | `hw/arm/virt.c` 生成 | 小（但语义要重对） |

### GIC 为什么最难

我们现在的 GIC 是**自己实现的 MMIO 回调**：guest 写 GICD/GICR 寄存器 →
我们的 `gicv3.c` 改内部状态 → 定时器/设备通过 `hv_machine` 注入 IRQ。

换成 QEMU 的 GIC 后，链路变成：

```
QEMU 设备 qemu_set_irq() → arm_gicv3 内部状态 → cpu_interrupt(cpu, CPU_INTERRUPT_HARD)
                                              → generic_handle_interrupt
                                              → cpu_set_interrupt + qemu_cpu_kick
                                              → 我们的 kick → hv_cpu_wake()
                                              → 引擎在块边界检查 exit_req，退出后读 GIC 状态
```

**关键点**：引擎不能再"自己知道"中断来了，必须靠 `exit_req` 退出后去问
QEMU 的 GIC（`arm_gicv3` 的 `gicv3_cpuirq` 之类）。这意味着我们引擎里
现有的 `irq_line` / `gic_*` 直连路径全部要改成"查询式"。

这块是 80% 的移植工作量。**它不是接口问题，是语义重写。**

## 3.5 文件清单

**新建**（`accel/hv/` 目录，参考 `accel/nitro/` 的 4 个文件）：

```
accel/hv/meson.build          hv_ss = ss.source_set(); hv_ss.add(files('hv-accel.c','hv-accel-ops.c'))
accel/hv/Kconfig              config HV
    bool
    depends on AARCH64
accel/hv/hv-accel.c           AccelClass：init_machine / setup_post / allowed
accel/hv/hv-accel-ops.c       AccelOpsClass：create_vcpu_thread / kick / handle_interrupt
include/system/hv-accel.h     hv_allowed / hv_enabled()  （25 行，抄 nitro）
```

**修改**（实测是 6 处，不是 5 处 —— 见下方"第 6 处"）：

| 文件 | 改什么 |
|---|---|
| `accel/Kconfig` | 加 `config HV`（`depends on AARCH64`） |
| `accel/meson.build` | `subdir('hv')` |
| `meson_options.txt` | `option('hv', ...)` |
| `meson.build` | ① 探测并 `accelerators += 'CONFIG_HV'`；② 未满足时报错；③ trace 子目录列表 |
| **`meson.build` 的 `accelerator_targets`** | **第 6 处，最容易漏（见下）** |
| `target/arm/cpu.c` | PSCI 1.1 分支加 `hv_enabled()` + include |
| `scripts/meson-buildoptions.sh` | 生成文件，手工补 `--enable-hv` |

`accel/accel-system.c` **不用改**：`allowed` 由 `accel_init_machine()` 自动置位。

### ⚠️ 第 6 处接线：`accelerator_targets`（只有真正编译才会暴露）

我原以为 `accelerators += 'CONFIG_HV'` 就够了。编译后症状是：

```
undefined reference to `hv_allowed'
  from libsystem_arm.a.p/target_arm_cpu.c.o
```

即 `target/arm/cpu.c` 编进去了（它引用 `hv_enabled()` → `hv_allowed`），
但 `hv-accel.c` **没被编进链接边**。查 `build/build.ninja` 才发现：

```meson
# meson.build:3327
foreach sym: accelerators
    if sym == 'CONFIG_TCG' or target in accelerator_targets.get(sym, [])
        config_target += { sym: 'y' }
```

一个 accel 符号要变成 `y`，**必须**在 `accelerator_targets` 里声明它支持哪个 target。

而且要注意 `if cpu == 'aarch64'` / `elif cpu == 'x86_64'` 里的 `cpu` 是**构建机**
的 CPU，不是 target。交叉编译（x86_64 宿主 → aarch64 产物）时走的是 `x86_64` 分支，
那些条目都不适用。所以正确写法是**无条件**加：

```meson
# Hv is an in-process ARM64->ARM64 translator, so only the aarch64 target can
# use it.  Declared unconditionally rather than under `if cpu == 'aarch64'`
# because `cpu` above is the *build* machine, while what matters here is the
# target: cross-compiling aarch64 QEMU on an x86_64 host is a supported
# workflow (that is how this accelerator is developed).
accelerator_targets += { 'CONFIG_HV': ['aarch64-softmmu'] }
```

**不用改**：`include/accel/accel-ops.h`、`accel-cpu-ops.h`（接口已经够用）。

> 但"不改公共头"不等于"不改核心文件"：见 §2.5，`system/physmem.c` 的
> `DIRTY_MEMORY_CODE` 置位是 TCG 独占的，hv 下 DMA 写不会失效。那一处必须改。

**已实现（本仓库）**：

```
accel/hv/meson.build            ✅
accel/hv/hv-accel.c             ✅ AccelClass + MemoryListener
accel/hv/hv-accel-ops.c         ✅ AccelOpsClass，MTTCG 锁序
accel/hv/trace-events           ✅
include/system/hv-accel.h       ✅ hv_allowed / hv_enabled()
include/system/hv-engine.h      ✅ 与引擎的契约（标明 exists / ADD）
accel/meson.build               ✅ subdir('hv')
accel/Kconfig                   ✅ config HV (depends on AARCH64)
meson.build                     ✅ 探测 + 报错 + trace 子目录
meson_options.txt               ✅ option('hv')
scripts/meson-buildoptions.sh   ✅ 手工补（生成文件，meson 会重生成）
target/arm/cpu.c                ✅ PSCI 1.1 分支 + include
```

**验证状态**：
- `./configure --target-list=aarch64-softmmu --disable-hv` → **通过**（没破坏正常构建）
- `./configure --enable-hv` → **被正确拦下**：`Hv acceleration requires host_os=linux and host_arch=aarch64`

### ⚠️ 阻塞点：我们没有 aarch64 Linux 构建环境

`hv` 要求 host 与 guest 同 ISA（1:1 指令拷贝），所以**只能在 aarch64 主机上构建**。
现状：

| 机器 | 架构 | 能否构建 |
|---|---|---|
| 本机 82MS（Ryzen 5600H 核显） | x86_64 | ✗ |
| union / P106 试验机 (192.168.1.43) | x86_64 | ✗ |
| Android 设备（A55） | aarch64 | 技术上可以（Termux+proot），但构建 QEMU 很慢 |

交叉编译试过了：`--cross-prefix=aarch64-linux-gnu-` 立刻卡在
`glib-2.0 with pkg-config failed` —— 缺 aarch64 sysroot
（本机只有 `i386` foreign arch，没有 `libglib2.0-dev:arm64`）。

三条路，成本递增：

1. **加 aarch64 multiarch 依赖**（`dpkg --add-architecture arm64` +
   `libglib2.0-dev:arm64` 等）→ 交叉编译，产物在 aarch64 上跑。
   要改宿主 dpkg 状态（需 sudo），我**没有**擅自动手。
2. **借一台 aarch64 Linux**（云 ARM 实例 / DGX Spark 一类）→ 最干净。
3. **手机上 Debian proot 里原生构建** → 自托管，但 QEMU 全量构建在 A55 上大约数小时。

**已解决：用用户提供的 overlay 容器做交叉编译环境。**

路径：`/data/用户/应用/操作系统/虚拟化/容器/Devuan/excalibur/apm-test/overlay/manual-build-qemu`
（Devuan excalibur，overlayfs + rurima/ruri；`enter.sh` 挂载，`sudo` 密码由用户提供）。

踩到的四个坑（都记在这里，下次直接用）：

| 坑 | 症状 | 解法 |
|---|---|---|
| 容器缺 gnupg | `Could not execute 'gpgv' to verify signature`，但 `gpgv --version` 正常 | 不是缺包，是 apt 的 `_apt` 沙箱用户在 overlay 里读不到它 → `-o APT::Sandbox::User=root` |
| ruri `-m` 不生效 | 容器内看不到宿主路径，`/data` 显示的是镜像自带内容 | 放弃 bind mount，直接把源码 `rsync` 进 overlay 的 `upperdir`（同一块盘、持久） |
| 沙箱 `/tmp` ≠ 容器 `/tmp` | `cannot open /tmp/xxx.sh` | 脚本写到 overlay 里（容器内 `/tmp/` 可见），不要用宿主 `/tmp` |
| `trace-events` 类型 | `Argument type 'hwaddr' is not allowed` | tracetool 只收定长整数类型，地址一律 `uint64_t` |

### 实测结果（这一步是硬证据）

交叉编译（x86_64 宿主 → aarch64 产物）成功：

```
$ qemu-system-aarch64 --version
QEMU emulator version 11.1.3

$ qemu-system-aarch64 -accel help
Accelerators supported in QEMU binary:
hv
tcg

$ qemu-system-aarch64 -M virt -accel hv -m 512 -smp 1 -nographic -nodefaults
qemu-system-aarch64: -accel hv: hv: engine not linked in (step 0 stub), missing: hv_engine_machine_new
qemu-system-aarch64: -accel hv: hv: see accel/hv/hv-engine-stub.c -- the accelerator skeleton
                    itself is fine; only the engine is absent.
```

**三件事同时被证明了**：

1. meson/Kconfig/QOM 接线全对 —— 否则 `-accel help` 里不会出现 `hv`；
2. `AccelClass.init_machine` 被 QEMU 真的调到了；
3. 缺的只剩引擎本体（`hv_engine_stub.c` 就是为此加的）。

产物：`work/qemu-hv/qemu-system-aarch64`（109 MB，debug 构建，aarch64 ELF）。

### 仍然没做的（说清楚，不含糊）

- **DMA→SMC 洞（§2.5）还没修**，`physmem.c` 一行没动。
- **没跑过 Linux**。最小 seam 用的是裸机探针，不是内核。

> 上面两条是 step 0 时的状态。**第十三轮已经把引擎 vendored 进树并打通了
> 取指/执行/MMIO/WFI**，见 §8。仍然没做的是 GIC、timer、中断注入。

## 4. 六个步骤（每步都有独立验收，不要跳）

### 步骤 0：最小可证伪（1 天，不碰设备）

目标：**证明接口形状对**，而不是证明能启动。

- 新 `accel/hv/` 目录，`hv-accel.c` + `hv-accel-ops.c`，照 `nitro` 的 284 行骨架
- `create_vcpu_thread` 用 §2.1；`init_machine` 只建 `HvMachine` 不建 RAM
- MemoryListener 只做 `region_add/del`
- **临时**保留 `-M virt` 的 PL011，MMIO 走 `address_space_rw` 转发
- 目标产物：`qemu-system-aarch64 -M virt -accel hv -kernel <flat> -nographic`
  能打印出 **UEFI 或 kernel 的第一行串口输出**

这一步过了，说明 vCPU 线程 / RAM 镜像 / MMIO 转发三件事都对。
过不了就别往下走——后面每一步都建立在这三条上。

#### 步骤 0 的验收必须从"能跑"升级到"跑得一样"

第一行串口只验活。真正的门槛是**与 TCG 对拍**：

```bash
./build/qemu-system-aarch64 -M virt -accel tcg -kernel flat.bin -nographic > tcg.log
./build/qemu-system-aarch64 -M virt -accel hv  -kernel flat.bin -nographic > hv.log
diff tcg.log hv.log          # UART 全文
```

同一 flat 镜像在两边跑，UART 全文 + 镜像自算的内存 checksum 对拍。**成本≈0**，
但它是"引擎翻译对了"的唯一低成本证据。只比串口不够——串口可能只覆盖前 10% 的执行路径。

#### 桥接细节（易漏，但每一条都会导致"卡住不动"）

- **reset 要读 ARMCPU 对象**：`arm_cpu_reset_hold()` 把 `env->pc` 清零，
  随后 `arm_load_kernel()` 用 `cpu_set_pc(cs, entry)` 写入。所以入口点在
  `ARM_CPU(cs)->env` 里，**不在引擎知道的任何地方**。
  必须在 vCPU 线程第一次 `hv_run()` 之前 `hv_engine_load_state(cpu, &ARM_CPU(cs)->env)`。
- **`hv_cpu_reset()` 不能用**：它内部硬编码 index 0，会让每个 vCPU 都别名 `m->cpus[0]`
  （这个 bug 在 `test_smc_mp` 上害我们查了一天）。必须用 `hv_cpu_reset_index(cpu, m, idx)`。
- **`cs->accel_data`** 用来放 `HvCpu*`，是与 QEMU 交换 per-vCPU 状态的唯一位置。
- **`handle_interrupt` 不能只挂 `generic_handle_interrupt`**：它只做
  `cpu_set_interrupt + qemu_cpu_kick`，而 `qemu_cpu_kick` 最终要落到我们的
  `hv_cpu_wake()`（`exit_req=1; sev`）。所以 `kick_vcpu_thread` 必须实现，
  且**不能在 `qemu_cpu_is_self` 时自旋**。

### 步骤 1：MMU 打开（软件 MMU 真正上线）

步骤 0 跑的是 MMU off 的裸机。打开 `SCTLR_EL1.M` 后，我们的
`hv_mmu_walk` 开始读 guest 页表 → 这才是引擎的核心路径。

验收：guest 能跑到 `start_kernel` 之后的第一个 `pr_info`。
**这一步最容易暴露 `region_add` 的粒度问题**（QEMU 的 RAM 可能是一个
大 region，也可能是几个，`-m` 和 `memhp` 会影响）。

### 步骤 2：GIC 接线（最大的一块）

- 删 `devices/gicv3.c` 的注入路径，改成查询 QEMU GIC
- `handle_interrupt` = `generic_handle_interrupt`（已经能用）
- 引擎的 `irq_line` 换成 `arm_gicv3` 的 CPU interface 读

验收：定时器中断能进 guest（`/proc/interrupts` 有增长）。

### 步骤 3：块设备（换成 QEMU NVMe/virtio）

验收：挂在 QEMU 的 disk 上能启动到 rootfs。

### 步骤 4：网络（QEMU netdev）

验收：guest 能 ping 通 QEMU 的 slirp / tap。

### 步骤 5：收尾（寄存器同步 + monitor + stats）

- `synchronize_state` 全量
- 我们的 `--stats` 挂到 `AccelClass.get_stats`
- 明确声明：migration / snapshot 暂不支持

## 5. 诚实的成本估计

| 步骤 | 内容 | 谁都知道的难度 | 隐藏成本 |
|---|---|---|---|
| 0 | 骨架 + 线程 + RAM + MMIO | 2–3 天 | meson/Kconfig 接入、`arm_cpu_realizefn` 分支、`-accel` 解析 |
| 1 | MMU 上线 | 1–2 天 | region 粒度、IOMMU 属性、cache attr |
| 2 | GIC | **1–2 周** | 这是我们自己实现得最深的部分，语义要重写 |
| 3 | 块设备 | 2–3 天 | 中断 + DMA 一致性 |
| 4 | 网络 | 2–3 天 | netdev 后端选择 |
| 5 | 收尾 | 2–3 天 | gdbstub 的断点要落到我们的 JIT 上（难） |

**总计 3–4 周**，其中 GIC 占一半。

## 6. 这笔投资买什么、不买什么

**买到的**：
- 设备生态（virtio 全家桶、NVMe、USB、VGA、各种 netdev 后端）
- `QMP` / `HMP` monitor（`info registers`、`info mtree`、`info cpus`）
- 迁移（如果做了全量寄存器同步）
- 快照、`-snapshot`、blockdev 全套
- 别人能按 QEMU 的文档用我们的引擎，不用读我们的 README

**买不到的**：
- **性能**。设备 I/O 走 QEMU 只会更慢（多一层 BQL + MemoryRegion 分发）。
  CPU 执行路径一行不变 —— knee 三档 72.5 / 74.0 / 113.9 ns 不会有任何改善。
- **启动速度**。QEMU 的 `-M virt` 有自己的设备初始化开销。

所以：**这个后端与 linear map / whint / IJC 主线完全正交**，
应该作为独立工作流并行，不要用它替代主线。

## 7. 一句话总结

> 引擎侧只需要动三处：**vCPU 线程（照抄 MTTCG 的锁序）**、
> **RAM 来源（MemoryListener 镜像）**、**MMIO 出口（转发 address_space_rw）**。
> 软件 MMU、JIT、块缓存、bank、TLB 全部原样保留 —— 因为它们只关心
> "PA 对应的 host 指针是多少"，而不关心这个指针是谁给的。
>
> 代价不在引擎里，在**设备层**：`devices/` 要整体下线，GIC 那 1–2 周是硬成本。

---

# 8. 第十三轮：引擎 vendored，最小 seam 打通

前七节是**方案**。这一节是**已经跑起来的东西**，以及路上踩到的、方案里
写不出来的七个坑。所有结论都有可复现的观测支撑（`work/henge-probe.sh`）。

## 8.1 三个前置决定

| 决定 | 选择 | 理由 |
|---|---|---|
| 引擎怎么进树 | **vendored 快照**（`accel/henge/engine/`），附 `VENDORED-FROM` + `sync-from-upstream.sh` | 接 QEMU 必须改引擎（去掉设备归属、加 RAM 增删、MMIO 出口），这些改动不能落进那棵九轮测量校准过的参考树。复制后 QEMU 树自包含，容器里 rsync 也不用管外部路径 |
| accel 叫什么 | **`henge`**（原 `hv`） | QEMU 已经有 `hvf`（macOS 的 accel）和 `hv-balloon`（设备）。一条命令行上三个 `hv` 开头是工单生成器。引擎自己的符号保留 `hv_` 前缀，只改 QEMU 侧命名 |
| 这一轮做到哪 | **最小可行 seam** | 先证明"引擎在 QEMU 的 RAM 上取指执行"。GIC/timer 一起上会把时间源问题伪装成调试问题 |

## 8.2 目录与三个静态库

```
accel/henge/
  henge-accel.c        AccelClass：建机器、镜像 RAM、MMIO 转发
  henge-accel-ops.c    AccelOpsClass：vCPU 线程（MTTCG 锁序）
  henge-cpu.c          寄存器桥（唯一同时看两个世界的 TU）
  henge-engine.c       RAM/CPU 生命周期（只有引擎头文件）
  meson.build
  engine/              vendored，逐字节等同上游
    core/  compat/  host/  VENDORED-FROM  sync-from-upstream.sh
```

拆成三个库不是洁癖，每一个都有硬理由：

```meson
henge-engine   core/*.c + host/jit_region_linux.c + compat/plat_linux.c + henge-engine.c
               c_args: -include compat/hv_posix_compat.h  -D_GNU_SOURCE
henge-mmu      core/mmu.c 单独一个
               c_args: + -mgeneral-regs-only
henge-asm      host/enter_elf.S 单独一个，c_args 必须为空
```

- **`-mgeneral-regs-only` 是硬要求**，不是优化：`hv_tlb_refill` 跑的时候
  guest 的 SIMD 寄存器是活的，编译器不能碰 v0–v31。
- **`enter_elf.S` 不能吃任何 c_args**。第一次构建失败在这里：
  `-include hv_posix_compat.h` 把 `<fcntl.h>` 拽进汇编，
  `aarch64-linux-gnu-gcc` 于是报 `unknown mnemonic 'typedef'`。
- **`ss.add()` 不收 static_library**，要 `declare_dependency(link_with: ...)`
  （和 hw/meson.build 加 libslirp 一个道理）。
- **要 link `libatomic`**：`memop.c` 的 STXP/CASP 走
  `__atomic_compare_exchange_16`，aarch64 上不是内联 ldxp/stxp。
  QEMU 自己从不需要它，所以只有我们拉进来。

## 8.3 七个坑（方案里写不出来，只有真编真跑才会遇到）

### 坑 1：`MemoryListener` 在 `init_machine` 注册，收到 **0 次**回调

最贵的一个。现象：机器建好了、vCPU 起来了、guest 在入口
`0x40080000` 就报 `exit reason 9 (exception vector faulted)`。

加了 `henge_dbg_regions++` 计数才看清：**`region_add` 一次都没触发**，
而 `setup_post` 正常调用。原因：`init_machine` 跑在
`machine_memory_init()` → `address_space_init()` **之前**，而
`address_space_init()` 里有 `QTAILQ_INIT(&as->listeners)` ——
监听器注册在一个随后被重新初始化的 `AddressSpace` 上，队列项被丢掉。

**修法**：权威来源改成 `setup_post` 里遍历**已完成的 flatview**：

```c
fv = address_space_to_flatview(&address_space_memory);
flatview_for_each_range(fv, henge_flatview_cb, h);
```

listener 保留（此时 AS 已上线，热插拔/内存树重建能收到）。

> 教训与第七轮的 `hv_cpu_reset` 固定 index 0 同类：**"加了钩子"≠"钩子会响"**。
> 只有计数器能分辨这两件事。

### 坑 2：`-kernel` 的 ROM 区域 `is_ram()==false`

`-kernel` 用 `rom_add_blob()` 把一个 ROM MemoryRegion **盖在** RAM block
上，`memory_region_is_ram()` 对它返回 false。只过滤 `is_ram()` 时引擎根本
不知道 `0x40080000` 存在。

**修法**：接受 `is_ram() || is_rom()`，并且**按可写注册** ——
内核落地的那段必须可写（Linux 会就地重定位、打补丁），而 QEMU 的 ROM
写保护是这个加速器不 trap 每一次 store 就无法兑现的设备模型行为。

### 坑 3：`CONFIG_HENGE` 在公共代码里被 poison

`scripts/make-config-poison.sh` 会把 per-target 配置头里**每一个**
`#define CONFIG_*` 都生成 `#pragma GCC poison`，而 `config-poison.h` 被强制
包含进公共代码。所以 `include/system/henge-accel.h` 里写
`#ifdef CONFIG_HENGE` 就是 `attempt to use poisoned "CONFIG_HENGE"`。

**修法**：照 `hvf.h` / `kvm.h` 的 `COMPILING_PER_TARGET` 模式绕开。

### 坑 4：`HV_EXIT_*` 的数值错了两格

step 0 的契约头写的是 `HV_EXIT_HALT = 3`、`HV_EXIT_MMIO = 4`。
`core/cpu.h` 的真实枚举是：

```
NONE=0 BRANCH=1 SYSREG=2 EXCEPTION=3 WFI=4 UNDEF=5 UNSUPPORTED=6 HALT=7 FLUSH=8 FAULT_LOOP=9
```

所以 3 是 **EXCEPTION**、4 是 **WFI**。那个桩版本一旦接上真引擎，
**每一次 guest 异常都会被上报成"CPU 停机"**。

而且**根本没有 `HV_EXIT_MMIO`**：MMIO 从不离开 run loop，它在
`hv_phys_read/hv_phys_write` 里同步服务。所以那个转发回调不是"退出原因"，
是同步回调 —— 也就意味着它跑在 **BQL 已经被释放**的上下文里
（`hv_run` 按 MTTCG 锁序在 `bql_unlock()` 之后调用），必须自己加锁。

**修法**：契约头改成 `HENGE_EXIT_*` 枚举（叫 `HV_EXIT_*` 会和引擎的枚举常量
同名冲突，`henge-cpu.c` 同时看到两个头时直接把 `core/cpu.h` 的枚举改写成
`enum { 0 = 0 }`），并在 `henge-cpu.c` 里逐个
`_Static_assert(HENGE_EXIT_HALT == HV_EXIT_HALT, ...)`。

### 坑 5：`HvCpu` 要 128 字节对齐，且必须是**已清零**的存储

- `HvCpu` 有 `aligned(128)` 成员（四张 TLB 表、`ret_salt`）。`malloc` 只给
  8/16 字节。所以 `posix_memalign(&p, 128, sizeof *cpu)`。
  `main_android.c` 用 `static HvCpu cpus[8]` 混过去了，编译器替它对齐。
- `hv_cpu_reset_index()` 在写 `p->ijc_tables_used` **之前先读它**，而
  `p->ijc_tables_used` 在 `HvPerCpu`（属于 machine），且它 memset CPU 时
  故意跳过 `m`/`pc_state` 两段。传未清零的堆内存进去，它会按垃圾位去
  memset 垃圾指针。必须先 `memset(cpu, 0, sizeof *cpu)`。

### 坑 6：`hv_machine_init()` 不读 `HV_*` 环境变量

只有 `hv_machine_init_jit()` 调 `knobs_init()`。这不是要修的 bug：
本项目**所有**测量（knee 512MB 74.0 ns、EL 分流的 +8.0%）都是在 knobs 为 0
的条件下取的。在这里"顺手修好"会静默挪动基线。

### 坑 7：`-cpu max` 与 QEMU 的页大小检查冲突（**未解**）

```
$ ... -accel henge -cpu max ...   → This CPU requires a smaller page size than the system is using
$ ... -accel tcg   -cpu max ...   → 正常
$ ... -accel henge -cpu cortex-a57 → 正常
```

`arm_cpu_realizefn` 里 `set_preferred_target_page_bits(pagebits)` 返回 false
的条件只有一个：`target_page.decided && target_page.bits > pagebits`。也就是
说 `max` 在 henge 下算出 `pagebits = 10`（= `ARM_FEATURE_V7` 未置位），而
TCG 下算出 12。枚举与 pagebits 相关的分支都查过（`!tcg_enabled()` 那块只
检查 M-profile / EL3 / MTE / GICv5），没找到置位差异。**目前按
`-cpu cortex-a57` / `cortex-a53` 使用**，这条留作待查。

### 另需注意：引擎没有 EL2

`hv_engine_load_state()` 会从 PSTATE 的 M[3:0] 取 EL，`el > 1` 直接报错并
提示加 `,virtualization=off`。QEMU 的 `-M virt` 默认 `virtualization=on`，
guest 从 EL2 起步 —— 引擎的异常模型、TLB 表、翻译器里都没有 EL2。

## 8.4 实测证据

`work/henge-probe.sh`（裸机探针，一次跑通四段）：

```
Entry point address:               0x40080000
--- tcg 对照（必须打印 HENGE-MMIO-OK）---
HENGE-MMIO-OK
--- henge ---
HENGE-MMIO-OK
--- henge + HENGE_DEBUG_RAM（RAM 镜像与 MMIO）---
henge: region mach-virt.ram            pa=0x40000000 size=0x10000000 ram=1 rom=0 romd=0
henge: setup_post mirrored 1 regions
HENGE-MMIO-OK
```

探针让 guest 做三件可观察的事：取指执行（`movz/adr/ldrb` 后索引/`cbz`/
`strb`/`b`）、MMIO 写 PL011、`wfi` 退出。

第 2 步是关键 —— 它把整条路径一次钉死：

```
guest store → 引擎快路径 miss → 引擎慢路径 → 引擎 MMIO 表未命中
   → catch-all HvMmio → henge_mmio_forward()
   → address_space_rw() → QEMU 的 pl011 → 串口
```

`tcg` 在同一份 ELF 上打印同样的字符串，说明探针本身没毛病（踩过：
多写 `-nodefaults` 会去掉 PL011，两边同时静默，看起来像"引擎跑飞了"）。

另有一条负向证据也留着用：`-accel henge -M virt,virtualization=off -m 512
-smp 1 -nographic -nodefaults`（无内核）会停在
`pc=0x0000000000000000, exit reason 9` —— 那是**正确的**：PC=0 没有 RAM，
取指失败 → 取异常向量（VBAR=0）也失败 → `FAULT_LOOP`。引擎把死循环变成
一条明确错误，而不是挂住。

## 8.5 QEMU 上游文件改动清单

引擎之外，动过的**上游**文件只有这些（都记了理由，便于 rebase）：

| 文件 | 改动 |
|---|---|
| `accel/Kconfig` | `config HV` → `config HENGE`（`depends on AARCH64`） |
| `accel/meson.build` | `subdir('hv')` → `subdir('henge')` |
| `meson_options.txt` | `option('hv')` → `option('henge')` |
| `meson.build` | 探测块、`error` 块、trace 子目录、`accelerator_targets` 四处 |
| `scripts/meson-buildoptions.sh` | `--enable-henge` / `--disable-henge` |
| `target/arm/cpu.c` | `henge_enabled()` 加入 PSCI 1.1 分支（PSCI 由引擎自己实现） |
| `hw/arm/virt.c` | 三处：GIC 版本集合分支、`virt_get_default_cpu_type()` 返回 `cortex-a57`（默认的 `max` 会撞坑 7，`cortex-a15` 是 AArch32 引擎不支持） |

`hw/arm/virt.c` 的 GIC 那处是**必须**的：不加就
`Unsupported accelerator, can not determine GIC support`，连机器都建不起来。
默认 CPU 那处同样必须：`virt_get_default_cpu_type()` 的非 TCG 分支返回 `max`，
于是**不指定 `-cpu` 就一定踩坑 7**。改成 `cortex-a57` 之后
`-accel henge` 裸跑可用（无内核时正确停在 `pc=0, exit reason 9`）。

## 8.6 仍然没做（含本轮新发现）

1. **GIC**：`HvPerCpu.irq_line` 目前没人写。引擎的 `devices/gicv3.c` 没有
   vendored（QEMU 提供 GIC），所以需要一个 `hv_cpu_set_irq()` 契约函数 +
   QEMU 侧的 `qemu_set_irq` 接线。**这是下一块，且是最大的一块。**
2. **时间源对不上**：引擎的时间域是宿主 `CNTVCT` 缩放到 24 MHz
   （`compat/plat_linux.c`），QEMU 的 `-M virt` 按 `GTIMER_*` 走
   `QEMU_CLOCK_VIRTUAL`。不接之前任何"用 CNTFRQ 校准延迟环"的 guest 都会漂。
3. **DMA→SMC 洞**：`system/physmem.c` 的 `DIRTY_MEMORY_CODE` 分支
   （`invalidate_and_set_dirty`）在 henge 下永远不执行，因为没人给那块内存
   设 CODE dirty log。正确钩点在 `flatview_write`（那里 `addr` 还是 guest PA），
   不是现在的 ram_addr。
4. **PSCI**：引擎的 `exception.c` 自己处理 `CPU_ON`（直接置目标 CPU 状态），
   这会绕过 QEMU 的 `hw/arm/psci.c` 和 vCPU 线程创建。SMP > 1 之前必须先
   把 PSCI 让给 QEMU。
5. **写密集负载未测**（沿袭 README 的已知限制）。
6. `-cpu max` 的页大小问题（坑 7）。

---

# 9. 第十四轮：四个生命周期洞 + cp_regs 通用转发器

上一轮把 step 0.5 钉死了（取指/执行/MMIO/WFI）。这一轮做的是**接缝**：
让引擎停止裁决那些 QEMU 才有资格裁决的事，并把四个会在负载下咬人的
生命周期问题堵掉。所有结论都有可复现的观测。

## 9.1 先核对，再动手（四条里两条本来就成立）

| # | 洞 | 结论 | 证据 |
|---|---|---|---|
| ① | MMIO 回调里的 BQL | **已成立**，并加了运行期断言 | `henge_mmio_forward()` 里 `bql_lock()` / `address_space_rw()` / `bql_unlock()`；新增 `assert(!bql_locked())` 把"进来时 BQL 必须已释放"从注释变成契约 |
| ② | system_reset | **缺**，已补 | 见 9.2，实测两次启动 |
| ③ | halted 次级 vCPU | **已成立**，但停靠点不在我以为的地方 | 见 9.3 |
| ④ | migration/snapshot | **缺**，已补 | 见 9.4，实测被拒 |
| ⑤ | 内联设备模型要显式关掉 | **真的存在，而且是静默的** | 见 9.5，`icc_read` 返回 0 |

关于 ①，补一句无死锁的推理依据（不是"加了锁所以安全"）：
`bql_lock()` 只在 vCPU 线程、`hv_run()` 返回后、`bql_unlock()` 之后调用；
设备回调里 raise IRQ 走的是 `qemu_cpu_kick` → `henge_kick_vcpu_thread` →
`hv_cpu_wake`，后者只写 `exit_req` + `sev` + 引擎自己的 per-CPU `wake_mu`，
**不回头拿 BQL**。所以不存在 "BQL → wake_mu" 与 "wake_mu → BQL" 的反向嵌套。

## 9.2 system_reset：唯一能做全局 flush 的地方

引擎有四类派生状态会被重启作废，而**没有任何别的地方能一次清掉**：

| 状态 | 为什么作废 |
|---|---|
| 翻译块 | 块键是 `{va, pa, flags, gen}`。重启把这四项全保持不变，却把背后的字节全换了 —— 第二次启动会直接跑第一次的翻译 |
| 软件 TLB | 装的是上一套页表的 host addend |
| `code_pages` / `whint` / `page_gen` | 上一轮的"哪些页是代码""哪些 TLB 项可写" |
| IJC / ret_tab | 指向已经不存在的块 |

vCPU 级 reset 只看得见一个 CPU，代码失效只看得见一页。所以新增
`hv_engine_machine_reset(m)`（flush 块 + 逐 CPU flush TLB + 清三张表）
+ `hv_engine_ram_clear(m)`，挂到 `qemu_register_reset()`。

`henge_reset()` 只做**机器级**的事，vCPU 的寄存器重同步交给已有的
`synchronize_post_reset` —— 不是因为随便分的，而是因为 `henge-accel.c`
是公共代码，`#include "target/arm/cpu.h"` 会直接编不过（`ARM_CPU`
是 per-target 宏）。这两半不竞争：一半动块/TLB/RAM 表，一半动寄存器。

实测（QMP 发 `system_reset`）：

```
HENGE-MMIO-OK
henge: reset, re-mirrored 1 regions
HENGE-MMIO-OK
```

**一个自己也踩到的坑**：QEMU 在启动期就会跑一次 reset handler，那时
flatview 还没建完。第一版没设守卫，于是 `mirrored 2 regions`（1 个真区域
+ 1 个 size=0 的死项）。加 `h->started`（在 `setup_post` 末尾置位）后恢复 1。
死项对查找无害，但让计数说谎 —— 这正是以后排查内存问题要多花一天的那类事。

## 9.3 halted 次级 vCPU：停靠点在 `qemu_process_cpu_events`，不在 `cpu_can_run`

这一点值得写下来，因为照 MTTCG 抄 loop 时并不会注意到：

```c
bool cpu_can_run(CPUState *cpu)          /* system/cpus.c:333 */
{
    if (cpu->stop) return false;
    if (cpu_is_stopped(cpu)) return false;
    return true;                          /* 注意：不看 ->halted */
}
```

真正拦住 halted CPU 的是 `qemu_process_cpu_events()` 里的
`while (cpu_thread_is_idle(cpu)) qemu_cond_wait(cpu->halt_cond, &bql);`，
而 `cpu_thread_is_idle()` 在 `->halted` 置位时会调用加速器的
`cpu_thread_is_idle` 回调 —— 也就是我们的 `henge_vcpu_thread_is_idle()`
（返回 `cs->halted`）。所以线程是在 `qemu_process_cpu_events` 里阻塞的，
`cpu_can_run()` 根本没机会被问到。

**如果那个回调哪天返回"不 idle"，4 个次级线程就会带着陈旧 PC 进 `hv_run`。**
所以它必须有注释盯着（已加）。实测 `-smp 4`：只打印一次 `HENGE-MMIO-OK`，
没有任何 `vCPU 1/2/3 stopped` —— 三个次级确实停着。

## 9.4 migration：拒绝，而且要拒绝得早

`MIG_EVENT_SETUP` 是唯一允许返回错误的迁移事件（其它只能看）。在它那里
拒绝，比在文档里写一句"不支持"强得多：否则 `migrate` 会**成功**，因为
`hv_engine_save_state()` 把架构寄存器写进了 `env`，而迁移流正好带 `env`
—— 目的端会带着一个空的 JIT、在一台正在 syscall 中间的 guest 上开始跑。
失败形态是"看起来正常的坏快照"。

实测：

```
henge: migration is not supported (the JIT cache, software TLB and per-CPU
state are host pointers and are not in the migration stream)
```

**踩到的坑**：我一开始把整个通知器包在 `#ifdef CONFIG_MIGRATION` 里。
这个配置里**根本没有定义 `CONFIG_MIGRATION`**，于是通知器被编掉，
`migrate` 照常启动并发出 STOP 事件。判据不是"这看起来该有守卫"，
而是"实测它有没有被拒"。

## 9.5 ⑤ 真的存在：`icc_read` 静默返回 0

这条值得单独一节，因为它是**比 UNDEF 更坏的失败**。

引擎里本来就有 GIC CPU 接口的钩子（给独立模式的内联 GIC 用）：

```c
/* core/sysreg.c, read_reg() */
if (reg == R(3, 0, 4, 6, 0) || (CRn==12 && CRm>=8)) {
    *v = m->icc_read ? m->icc_read(m, cpu, reg) : 0;   /* ← 没人装，返回 0 */
    return 0;
}
```

在 QEMU 下 `icc_read` 是 NULL，于是 `ICC_IAR1_EL1` 读出 **0**，
`ICC_PMR_EL1` 写进去也没人接。guest 因此认为 GIC 存在、但行为错乱，
而不是"这个接口不存在"。第一次跑探针时它打印的是 `SYSREG-BAD-IAR`，
而且 `HENGE_DEBUG_SYSREG` 一行都没输出 —— 转发器根本没被走到。

修法：把这两处 ICC 分支纳入 seam，`sysreg_external` 置位时改走转发器。
顺带说明为什么用标志而不是 `#ifdef`：同一份代码路径，两个宿主，
谁改坏了都会被另一边的测试抓到。

## 9.6 通用 cp_regs 转发器（keystone）

### 设计

```
引擎遇到不认识的 MRS/MSR
  → 不注入 UNDEF，而是退出：exit_reason = HV_EXIT_SYSREG_EXT，pc 不动
  → vCPU 线程拿 BQL，查 QEMU 的 cpu->cp_regs
  → 命中：调 readfn/writefn，回填 Rt，pc += 4，重查中断，继续
  → 未命中：恢复原语义（UNDEF）
```

键的换算：引擎把 `op0:op1:crn:crm:op2` 打进 16 位（它自己的 `R()` 宏），
QEMU 用 `ENCODE_AA64_CP_REG(op0, op1, crn, crm, op2)`。两者是同一组五个域，
只是排列不同，所以换算是一行移位 —— 不需要维护第二张表。

写侧需要 `write_raw_cp_reg` 的顺序，而它是 `target/arm/helper.c` 里的
**static**（`read_raw_cp_reg` 是公开的），所以照抄了 12 行：`ARM_CP_CONST`
忽略 → `raw_writefn` → `writefn` → `raw_write`。这是唯一一处复制，
注释里写明了来源函数。

### 实测（`work/probe/sysreg.S`）

探针读 `ICC_IAR1_EL1`（应为 1023）、写读 `ICC_PMR_EL1`、写 `ICC_EOIR1_EL1`：

```
--- henge + HENGE_DEBUG_SYSREG（GICv3）---
SYSREG-BEGIN
henge: MRS S3_0_C12_C12_0 at 0x4008000c -> ICC_IAR1_EL1
henge: MSR S3_0_C4_C6_0  at 0x40080020 -> ICC_PMR_EL1
henge: MRS S3_0_C4_C6_0  at 0x40080024 -> ICC_PMR_EL1
henge: MSR S3_0_C12_C12_1 at 0x40080030 -> ICC_EOIR1_EL1
SYSREG-OK
--- tcg 对照 ---
SYSREG-BEGIN
SYSREG-OK
```

四类访问全部落到 QEMU 自己的表上，结果与 TCG 逐字一致。

**前提：`gic-version=3`。** 默认 `-M virt` 选的是 **GICv2**（
`finalize_gic_version_do()`：NOSEL 且支持 v2 且 `max_cpus<=8` → 取 v2），
GICv2 的 CPU 接口是 MMIO 不是系统寄存器，ICC_* 根本不在 `cp_regs` 里。
这不是 henge 的问题：**TCG 在同一命令行下也是 GICv2**，读 ICC 一样 UNDEF。

### 这对 GIC 意味着什么

工作量从"1–2 周"降为"2–4 天"里的那 2 天，确实主要是这个转发器，
而它现在是公共基建：**ICC_*（GIC）、CNTV_CVAL/CNTV_TVAL（gtimer）、
以后任何设备注册的寄存器，都走同一条路**。GIC 的内部语义
（优先级、group、PMR 比较、active-priority 栈）一行都没有重实现。

剩下的 GIC 工作是**一根线**：QEMU 侧 line 变化都伴随 kick，引擎只需在
两个检查点读 `cpu->interrupt_request` 的 HARD/FIRQ 位（run loop 每次退出后、
WFI 唤醒后），能不能收由引擎自己的 PSTATE 判（QEMU env 里的 PSTATE 是陈旧的，
权威在引擎，不能用 `cpu_interrupts_enabled`），能收就调引擎已有的异常注入原语。

## 9.7 引擎侧本地改动（vendored 副本）

四个文件，全部**增量且默认关闭**（flag 为 0 时行为与上游完全一致），
已固化为 `accel/henge/engine/local-edits.patch`（160 行）：

| 文件 | 改动 |
|---|---|
| `core/cpu.h` | 追加两个退出原因 `HV_EXIT_SYSREG_EXT=10`、`HV_EXIT_PSCI_EXT=11`（**追加**而非插入：值属于宿主契约，重编号会把"未知系统寄存器"静默变成"分支"） |
| `core/machine.h` | 两个 seam 标志 `sysreg_external`、`psci_external` |
| `core/sysreg.c` | 未知 MRS/MSR + ICC_* 两处钩子纳入 seam |
| `core/exception.c` | SMC/HVC 纳入 seam |

`read_reg`/`write_reg` 拿不到 insn/pc，所以用第三个返回值
`HV_SYSREG_EXTERNAL (-2)` 把"该交给宿主"讲给外层，由外层组装退出。

## 9.8 这一轮新增的契约函数

```c
void hv_engine_set_external(HvMachine *m, int sysreg, int psci);
int  hv_engine_sysreg_pending(const HvCpu *, uint32_t *reg, int *rt,
                              int *is_write, uint64_t *pc, uint64_t *value);
void hv_engine_sysreg_resume(HvCpu *, uint64_t value, int handled);
int  hv_engine_psci_pending(const HvCpu *, uint64_t *pc, uint64_t args[4]);
void hv_engine_psci_resume(HvCpu *, uint64_t ret, int handled);
void hv_engine_machine_reset(HvMachine *m);
void hv_engine_ram_clear(HvMachine *m);
```

`value` 由 `pending` 一并交出（而不是让 QEMU 去读 `HvCpu.x[]`）——
寄存器文件的布局只留在一个地方，和 HvCpu 对 QEMU 不透明是同一个理由。

## 9.9 现在还没做的（按你给的序号的进度）

| # | 事项 | 状态 |
|---|---|---|
| 0 | BQL / halted / migration 三个检查 | **完成**（①②③④⑤ 全部核实） |
| 1 | 通用 cp_regs 转发器 | **完成并实测** |
| 2 | 时间源对齐 + CONT 重标定 | 未做 |
| 3 | IRQ line 检查 + 注入 | 未做（依赖 1，现已解锁） |
| 4 | PSCI 转发 + 双向同步 | **接缝已就位但关闭**：QEMU 的 PSCI 藏在 `arm_cpu_do_interrupt()` 的 `if (tcg_enabled() && ...)` 里，且实现在 `target/arm/tcg/psci.c`。要接需放开那个条件并补 conduit 的寄存器同步。**SMP>1 之前必须做** |
| 5 | DMA→SMC 钩子 | 未做（钩点已确认在 `flatview_write`，那里 `addr` 还是 guest PA） |

另外 `-cpu max` 的 `pagebits=10` 仍挂起，按你说的排在后面：
先抓一次完整报错文本，大概率是引擎的 ID 寄存器视图与 max 的 feature 集合
不匹配（64K granule 或 52 位 VA），那是引擎侧问题。

---

# 10. 第十五轮：把 ⑤ 升格成审计，然后 ID 组 / 时间源 / IRQ / PSCI / DMA

上一轮把 ICC 钩子当成"一个 bug"修掉了。这一轮按你的判断把它升格：那不是
一个 bug，是一类 —— **引擎自己认识一批系统寄存器，钩子没装就静默降级**。
顺着这条线审计出来的东西，比 ICC 本身值钱得多。

## 10.1 引擎自认识寄存器清单（审计结果）

`grep -c "case R(" core/sysreg.c` = **112 个 case**，加上四条按位模式的
catch-all。按 QEMU 模式应有的归属归类：

| 组 | 寄存器 | 引擎现状 | QEMU 模式下的归属 | 状态 |
|---|---|---|---|---|
| ICC_*（GIC CPU 接口） | `S3_0_C12_C8..12_*`、`S3_0_C4_C6_0` | `icc_read`/`icc_write` 钩子（NULL → 0） | 转发 | ✅ 已转 |
| **ID / 缓存描述**（op0=3, CRn=0） | MIDR, MPIDR, REVIDR, ID_AA64PFR0/DFR0/ISAR0/ISAR1/MMFR0/MMFR1, CTR_EL0, DCZID, CLIDR, AIDR, CCSIDR, CSSELR | 固定 Cortex-A76 镜像 + 一批读 0 | **全部转发** | ✅ 本轮 |
| 定时器控制面 | CNTP/CNTV 的 CTL / CVAL / TVAL | 引擎自答（24 MHz 域） | 转发（host 的 gtimer） | ✅ 本轮 |
| 定时器计数器 | CNTPCT / CNTVCT | 引擎自答 | 引擎保留（纯算术 + K） | ✅ 本轮 |
| CNTFRQ | `S3_3_C14_C0_0` | 硬编码 24 MHz | 转发（host 的 gtimer 频率） | ✅ 本轮 |
| CNTVOFF | `S3_4_C14_C3_*`（EL2） | 引擎字段 | 从 env 读 | 未做（virt 裸跑为 0，已记录） |
| TLB / AT / DC / IC | `SYS` 组 | 引擎自答 | 引擎保留（它自己的 MMU） | 正确归属 |
| 调试 / PMU | CRn 9、CRn 14 CRm 8..15 | 忽略（读 0、写丢） | 引擎保留（QEMU 也不建模） | 可接受 |

**关键洞察**：MPIDR、PSCI、`-cpu max` 三个问题其实是**同一个问题** ——
引擎自答了一组"CPU 是什么"的寄存器。所以修法是**一个谓词**而不是三处特判：

```c
/* op0=3 且 CRn=0 就是 ID 空间与缓存描述 */
static int is_id_group(uint32_t reg) {
    return (reg >> 14) == 3 && ((reg >> 7) & 15) == 0;
}
```

一行覆盖 MIDR / MPIDR / REVIDR / 全部 ID_AA64\* / CTR_EL0 / DCZID / CLIDR /
AIDR / CCSIDR / CSSELR。这也是为什么它顺手解释了 `-cpu max`（见 §10.6）。

## 10.2 ID 组转发实测：三型存储路径一次覆盖

新探针 `work/probe/idreg.S` 故意选三种不同的存储形态：

| 寄存器 | 存储形态 | 走的路径 |
|---|---|---|
| MIDR_EL1 | `ARM_CP_CONST` | 读 `resetvalue`，不碰 env |
| ID_AA64PFR0_EL1 | `ARM_CP_CONST` | 同上 |
| CNTFRQ_EL0 | fieldoffset（`env.cp15.c14_cntfrq`） | `readfn`（`gt_cntfrq_read`） |
| MPIDR_EL1 | fieldoffset | `raw_read` |
| CTR_EL0 | fieldoffset | `raw_read` |

```
=== henge ===                       === tcg ===
MIDR=00000000411fd070               MIDR=00000000411fd070
ID_AA64PFR0=0000000000000022        ID_AA64PFR0=0000000000000022
CNTFRQ=0000000003b9aca0             CNTFRQ=0000000003b9aca0
MPIDR=0000000080000000              MPIDR=0000000080000000
CTR_EL0=000000008444c004            CTR_EL0=000000008444c004
```

五项逐字一致。注意 MIDR 从引擎的 `414fd0b1`（A76）变成了 `411fd070`
（cortex-a57）—— **guest 现在看到的 CPU 就是 QEMU 建模的那个**。

## 10.3 转发器 v2：accessfn 与 PL 检查（你指出的第一个洞）

v1 直调 `readfn`/`writefn`，跳过了 QEMU 正常访问路径的两道闸。后果：
EL0 读 PL1 寄存器会拿到值而不是 UNDEF —— **一个静默通过的权限检查**。

现在按 QEMU 自己的顺序补上，EL 取自**引擎**（`hv_engine_sysreg_pending()`
多输出一个 `el`，因为 QEMU 的 env 在运行中途是陈旧的）：

```c
if (!cp_access_ok(el, ri, !is_write))     → UNDEF
if (ri->accessfn) ar = ri->accessfn(env, ri, !is_write);
if (ar != CP_ACCESS_OK)                   → UNDEF（记录为已知缺口：应为带 syndrome 的 trap）
```

`accessfn` 拒绝的正确响应是"带 syndrome 陷到更高 EL"，不是 UNDEF。对目前
走这条缝的寄存器（ICC_*、ID 组、timer 比较）来说，无 EL2 的 guest 看不出
区别，所以先按 UNDEF 处理并在注释与 `HENGE_DEBUG_SYSREG` 里标明 —— 这是
**已记录的缺口**，不是假装做完了。

## 10.4 转发器 v2：`readfn` 优先于 `raw_readfn` —— 一个真 bug

这是本轮最值钱的发现，而且它**只能用闭环探针抓到**。

我一开始照抄 QEMU 的 `write_raw_cp_reg()` 顺序（`raw_writefn` 优先，那是
导出可见的唯一参考）。但 **raw 是迁移语义**：搬存储，不跑副作用。guest
访问要的正好相反。`CNTV_CVAL_EL0` 的定义把这点钉死了：

```c
{ .writefn = gt_virt_cval_write, .raw_writefn = raw_write }
```

走 `raw_writefn` 就把数字存进去了，**从不调用 `gt_recalc_timer()`** ——
host 的定时器永远不被 arm，guest 请求的中断永远不来，而每一次寄存器读回
都完美正确。

判据是闭环：编程一个 deadline（`CNTV_CVAL` + `CNTV_CTL`），等中断。
寄存器读回正确、`CNTFRQ` 一致、`CNTVCT` 单调 —— 全部通过，但中断不来。
只有链路闭环才能证伪。

修法：**`writefn` 优先，`raw_writefn` 只作兜底**；读侧同理 `readfn` 优先
（它能算 ISTATUS、能认领中断）。这也是 QEMU guest 访问路径的语义。

## 10.5 时间源：K，不是 callout

- **CNTFRQ 从机器模型读**：`ARM_CPU(cs)->gt_cntfrq_hz`（6225 万 Hz），不再
  硬编码 24 MHz。
- **不给每次读加 callout**：引擎内部仍是裸计数器，只是多一步定点缩放
  （`timer_scale_num/den = freq/24000000`）和一次减法（epoch）。
  Linux 移植下计数器读本来就走 MRS helper（commpage 垫片让
  `translate_counter` 不内联），所以这里改是安全的，不用动 JIT。
- **K 在 machine 层**：`hv_engine_set_timer_epoch(m, engine_ticks - host_ticks)`。
  标定放在 `henge_timer_calibrate()`，由 `henge_timer_setup()` 在首个 vCPU
  线程里调用一次。
- **CONT 重标定**：`qemu_add_vm_change_state_handler()`，`running == 1` 时
  重算。因为 QEMU_CLOCK_VIRTUAL 在 vm_stop 期间冻结而宿主计数器照走 ——
  暂停十秒回来就意味着 guest 时间里"丢了十秒"，表现为莫名的超时而不是
  慢时钟。reset 里也重标定一次。

**EXITTB 的处理（按你的提醒写进注释了）**：`CPU_INTERRUPT_EXITTB` 必须
忽略。QEMU 用它让翻译块在内存映射变化后结束，而引擎的每个块进入时都会
校验自己页的 generation，失效是在取指时自然发现的，不需要这个信号。
把它当 HARD 处理会投递一个幻影中断。

## 10.6 中断注入 + timer 闭环（#3）

`HvPerCpu.irq_line` 一直没有写者。现在有了：

```c
static void henge_sync_irq(CPUState *cs, HvCpu *cpu) {
    uint32_t req = cs->interrupt_request;
    hv_engine_set_irq(cpu, !!(req & CPU_INTERRUPT_HARD),
                      !!(req & CPU_INTERRUPT_FIQ));
}
```

三个调用点，而且位置有讲究：

1. **kick 里，在 `hv_cpu_wake()` 之前** —— 引擎离开 WFI 的瞬间就会重查线，
   line 陈旧的话它立刻又睡回去。
2. **每轮 `hv_run()` 之前** —— GIC 从别的线程拉线只会 kick，线本身要抄过来。
3. **每次 seam 服务之后** —— cpreg 写入可能编程一个立刻到期的 timer。

**不在这里看 PSTATE**：能不能收由引擎自己的 `hv_check_interrupts()` 判。
用 QEMU 的 `cpu_interrupts_enabled()` 是错的 —— 它读的是陈旧的 env。

实测（`work/probe/timerirq.S`，guest 编程 100 ms deadline）：

```
=== henge ===                === tcg ===
TIMER-ARMED                  TIMER-ARMED
TIMER-IRQ                    TIMER-IRQ
INTID=000000000000001b       INTID=000000000000001b
TIMER-DONE                   TIMER-DONE
```

`0x1b` = 27 = vtimer PPI。**#2 与 #3 由同一条闭环同时验收**：guest 写
CVAL → 转发器 → QEMU gtimer → 到期 raise → GIC → `arm_cpu_set_irq` →
`CPU_INTERRUPT_HARD` → kick → `henge_sync_irq` → 引擎按自己的 PSTATE 取
异常 → 向量表。这正是 Linux tick 走的那条路。

## 10.7 PSCI：直调 `psci.c`，以及两个顺序 bug

**不动 `arm_cpu_do_interrupt()`**，理由与你一致：那条路带着整套 TCG 异常
语义（向量选择、PSTATE 更新），还要把结果再翻译回引擎。直接调
`arm_handle_psci_call()` 更小，也更诚实地说明"PSCI 不是异常，是 QEMU 答应的
一个 hypercall"。

先确认了你让查的那件事：`psci.c` **零 TCG 依赖**（两个函数，只碰 CPUState
与 env）。但 `arm_is_psci_call()` 在 `!CONFIG_TCG` 时被编成
`return false` —— 所以加了 `#if defined(CONFIG_TCG)` 分支，否则每次 HVC
都会变成 UNDEF。这是编译期事实，所以用编译期处理。

然后是两个只有跑起来才会发现的顺序 bug：

**（a）`env->regs[]` 与 `env->xregs[]` 是两个独立数组。** `regs[16]` 是
AArch32 视图（32 位），`xregs[32]` 才是 AArch64。我的 `load_state`/`save_state`
一直写的是 `regs`。对 AArch64 guest 来说，**同步等于什么都没做** ——
`arm_handle_psci_call()` 读 `env->xregs[0]` 拿到 0，于是 fn=0，
返回 NOT_SUPPORTED。这也意味着 monitor 的 `info registers` 一直是错的。

**（b）CPU_ON 的 env 写入发生在 reset 钩子之后。**
`arm_set_cpu_on()` 只是**排队** `arm_set_cpu_on_async_work()` 到目标 CPU；
那个 work 才做 `cpu_reset()`（→ 我们的 `synchronize_post_reset`）、
`arm_emulate_firmware_reset()`、`env.xregs[0] = context_id`、
`cpu_set_pc(entry)`。顺序是 reset 在前、写 env 在后。

我试过两种判据，都不对，值得记下来：

| 方案 | 为什么不对 |
|---|---|
| `cpu_synchronize_post_reset()` 里置脏标记 | **ARM 的 reset 路径根本不调它**。全树只有 `target/s390x/sigp.c` 和 nvmm 的 ops 表会调 —— 一个从不触发的钩子 |
| 在 `qemu_process_cpu_events()` 之前查 `cpu_work_list_empty()` | 这个线程此时正停在那个调用内部的 `cond_wait` 上，work 是之后才入队的，检查早已跑过 |
| 在同一调用之后查 | 那时队列已经空了 |

**正确做法**：在 `henge_service_psci()` 里，`arm_handle_psci_call()` 之后，
如果是 CPU_ON 且成功，用 `run_on_cpu(target, henge_resync_target, ...)` 给
目标 CPU **追加**一个 work 项。`run_on_cpu` 排在同一个 per-CPU 队列的
**后面**，所以顺序天然保证：reset-and-set-env 先，我们的重同步后。

实测（`work/probe/smp.S`，两个核各自打印，输出串行化后）：

```
=== henge -smp 2 ===          === tcg -smp 2 ===
CPU0-MPIDR=80000000           CPU0-MPIDR=80000000
PSCI HVC fn=0xc4000003 -> 0x0
CPU_ON-RET=0000000000000000   CPU_ON-RET=0000000000000000
CPU0-DONE                     CPU0-DONE
CPU1-CONTEXT=00000000c0de5ec0 CPU1-CONTEXT=00000000c0de5ec0
CPU1-DONE                     CPU1-DONE
```

两核都起来，`context_id` 正确传递。**这是 Linux 二级核启动的最小复现**，
也是 PSCI 必须前置 MPIDR 的原因：`arm_set_cpu_on()` 用
`arm_get_cpu_by_id(mpidr)` 精确匹配 `arm_cpu_mp_affinity()`，而探针最初用
`MPIDR_EL1 + 1`（含 bit31 的 U 位）会得到 `unknown CPU 2147483649`；
必须取亲和性字段。Linux 的 `cpu_logical_map` 同样只看亲和性字节。

## 10.8 DMA→SMC 钩子（#5）

钩点确认在 `flatview_write()`（`addr` 还是 guest PA）：

```c
if (henge_enabled() && memory_access_is_direct(mr, true, attrs)) {
    hv_engine_dma_written(henge_accel_machine(), addr, l);
}
```

三个要点：
- **先判 RAM**，MMIO 写连引擎的表查找都到不了。
- **复用 `code_pages` 位图**：`hv_dma_written()` 只对真正标记为代码的页做
  工作，其他页一次查找就回。这是你担心的"热路径无条件调用"的解法。
- **`physmem.c` 那两处 `DIRTY_MEMORY_CODE` 站点不动**：它们 `assert(tcg_enabled())`
  且拿的是 `ram_addr_t`，不是 guest PA。留作后期方案。

**诚实标注**：本轮的验证只覆盖了**同一张位图的 guest 侧路径**（
`work/probe/smc.S`：执行 → 自己改写 → 再执行，`0x1111` → `0x2222`，与
TCG 一致）。DMA 侧需要一个真的设备写 guest RAM 的场景（模块加载），
那是 step 1 验收的一部分，**尚未验证**。

## 10.9 两笔维护债

**`local-edits.patch` 挂进同步流程**：`sync-from-upstream.sh` 现在把补丁
应用到暂存副本（那就是目标态），补丁一旦不适用就 **fail loud**：

```
sync: local-edits.patch does not apply to upstream 0071d69 --
sync: upstream changed under it.  Rebase the patch, do not drop it.
```

理由写进脚本里了：一次静默丢失这些改动的刷新**仍然能编译**（seam 默认全关），
然后表现为一个纯引擎 —— 一个能跑但缺了四分之三个移植的二进制。

**region diff 防 2-vs-1 复发**：`henge-lifecycle.sh` 的第 2 项现在会把
启动镜像与 reset 后镜像的 region 列表做多重集比较，任何一行出现次数不为 2
就报 `MISMATCH`。同时脚本扩到 8 项（停靠 / reset+diff / 迁移拒绝 /
ICC 转发 / ID 三型 / timer 闭环 / SMP / SMC）。

## 10.10 这一轮之后的进度

| # | 事项 | 状态 |
|---|---|---|
| 1.5 | ID 组转发 + 三型探针 + accessfn/PL | **完成**（五项逐字对拍） |
| 2 | 时间源（CNTFRQ / K / CONT 重标定 / EXITTB） | **完成**（timer 闭环） |
| 3 | IRQ line 注入 | **完成**（INTID=0x1b 与 TCG 一致） |
| 4 | PSCI 直调 psci.c + 双向同步 | **完成**（SMP 2 核起来，context 正确） |
| 5 | DMA→SMC 钩子 | **代码就位，仅 SMC 侧验证** |

**仍未做**：
- `-cpu max` 的 `pagebits=10`。ID 组转发之后**没有自动修好**（ID 转发影响
  guest 看到的 ID，而 pagebits 是 QEMU 在 realize 时算的，两者不相干）。
  下一步按你说的：在 `set_preferred_target_page_bits()` 失败处打印
  V8/V7VE/V7/PMSA/M 位与 pagebits，抓一次完整读数再判断。
- EL2（引擎没有），所以 `virtualization=on` 仍不支持。
- CNTVOFF：virt 裸跑为 0，尚未从 env 读取。
- 模块加载（真正的 DMA 验证）。

---

# 11. 第十六轮：`-cpu max` 的真相、CNTVOFF、以及 DMA 验证的三次失败

## 11.1 `-cpu max` 的 `pagebits=10` 不是引擎的问题

抓了一次完整读数（在 `set_preferred_target_page_bits()` 失败点打印 feature 位）：

```
warning: arm: pagebits=10 V8=0 V7VE=0 V7=0 V6K=0 V6=0 M=0 PMSA=0 AARCH64=0 cpu=max-arm-cpu
This CPU requires a smaller page size than the system is using
```

**所有 feature 位都是 0，连 AARCH64 都是 0。** 这不可能是一个"特性集不匹配"，
——是一个**完全没初始化的 CPU 模型**。追到 `target/arm/cpu-max.c`：

```c
static void cpu_max_initfn(Object *obj) {
    if (hwaccel_enabled()) { aarch64_host_initfn(obj); return; }
    if (tcg_enabled() || qtest_enabled()) {
        aarch64_aa32_a57_init(obj, !aarch64_enabled);   /* ← 整个函数体都在这 */
    }
    ...
}
```

`hwaccel_enabled()` 只认 hvf/kvm/nvmm/whpx，henge 不在里面；`tcg_enabled()` 在
`-accel henge` 时为假。**所以 `aarch64_aa32_a57_init()` 一次都没跑，feature 位
自然是空的**，`arm_cpu_realizefn()` 于是走 1K 页分支并拒绝启动。

修法：把 henge 加进 TCG 那个分支（它是软件翻译器，与 TCG 同类；`host_initfn`
才是错的——没有宿主 CPU 可建模）。

修完之后 `-cpu max` 能启动、能跑探针。**与 TCG 的 `-cpu max` 数值不同，但这是
预期且正确的**：

| | henge | tcg | 为什么 |
|---|---|---|---|
| MIDR | `411fd070`（cortex-a57） | `000f0510`（QEMU 自定义 max） | 引擎用 a57 基线 |
| ID_AA64PFR0 | `0x22` | `0x1301001120110022` | TCG 的 max 会加 SVE/RME 等，**引擎不翻译它们，所以不该宣称** |
| CNTFRQ | `0x3b9aca0`（62.5 MHz） | `0x3b9aca00`（1 GHz） | a57 有 BACKCOMPAT_CNTFRQ；两者都与各自的 CPU 模型自洽，我们的 timer 标定从 `gt_cntfrq_hz` 读，都跟得上 |

**`-cpu max` 在 henge 下等价于"a57 特性集的 AArch64 CPU"，这是诚实的**：
宣称一个指令集扩展却翻译不了，guest 会用它然后崩，那才是错的。

## 11.2 CNTVOFF 从 env 读

引擎有 `cpu->cntvoff` 字段，QEMU 有 `env->cp15.cntvoff_el2`，此前两者从没对过话。
virt 裸跑时为 0 所以看不出来；一旦有人设置它，CNTVCT 就会差一个常数——静默的
时钟偏移，不是崩溃。现在 `load_state`/`save_state` 双向同步。

## 11.3 DMA→SMC 验证：三次尝试，三次失败，但失败点各不相同

这一项**没有完成**。如实记录，因为失败点本身是有信息量的。

### 尝试一：gdbstub（`M` 包写 guest RAM）

理论路径完美：`cpu_memory_rw_debug -> address_space_rw -> flatview_write`。

- **`-S`（VM 停在入口）下完全正常**：`?` 返回 `T05`，`m40080000,4` 返回
  `2f6c6962`（"/lib"）。所以 gdbstub 本身、协议、`M` 包都通。
- **VM 运行中完全不响应**：连上后 `?`、`m`、`M` 全部返回空。QMP 的 chardev 在
  同样条件下正常，所以不是 chardev 的问题，是 gdbstub 的读循环依赖"VM 已停"。
- **guest 的 `brk #0` 不能用来停 VM**：引擎把它当普通 `HV_ECB_BRK` 异常处理，
  QEMU 根本不知道，gdbstub 收不到 stop reply。实测 guest 直接因为 VBAR=0
  去取向量而 `FAULT_LOOP`。
- **QMP `stop` + gdbstub 的组合确实能用**（实测：QMP stop 后 `?` 返回 `T05`，
  `m` 返回数据，QMP cont 恢复）——**但只在 guest 处于 WFI 时**。当 guest 在
  自旋轮询 mailbox 时，QMP stop 之后 gdbstub 仍然不响应（重试 10 次全空）。

**结论**：qemu-user（宿主 x86_64 用 qemu-aarch64 跑 qemu-system-aarch64）的
多线程模拟不能同时支持"guest 在自旋"和"主循环处理 gdbstub"。这是工具链限制。

### 尝试二：`-device edu`（真正的设备 DMA）

`edu` 有 `pci_dma_write`，是最真实的 DMA。做到了：

```
EDU-ID=0000000011e81234        ← 扫 ECAM 找到设备
BAR0-SIZE=0000000000100000     ← 1 MiB
BAR0-READBACK=0000000010000000 ← 分配成功
CMD=0000000000000002           ← Memory Space 已使能
```

`info pci` 也确认：`BAR0: 32 bit memory at 0x10000000 [0x100fffff]`。

但 **guest 读 0x10000000 得到 `0x010000ed`，而 QEMU 自己的 `xp /4xw 0x10000000`
得到 `0xffffffff`** —— 两条路径不一致，且都不是 liveness 该有的 `0xaa`。
BAR 配置完全正确却读不到设备，这个矛盾没查完。

沿途确认并解决的问题（都有价值）：
- ECAM 基址是 **0x4010000000**（`-M virt,dumpdtb=` 与 `info mtree` 两个独立来源
  一致），PCIe MMIO 窗口是 **0x10000000**，不是猜的 0x3f000000。
- **裸机 guest 必须自己做完整 PCIe 枚举**：QEMU 不做，`info pci` 里 BAR0 显示
  "(not mapped)"，写全 1 读回才拿到大小，写完还要设 command register。
- **MMIO 读本身是好的**：新探针 `mmio-rd.S` 证明 `UARTFR`、4 GiB 之上的 ECAM
  （`0x00081b36` = host bridge 的 ID）都能读。之前"读不到"是我的探针 bug：
  `puts`/`hex` 破坏了 `x9`，而我把 ECAM 基址留在 x9 里。

### 尝试三：`-device loader`

`-device loader,file=...,addr=0x40100000,force-raw=on` 走 `rom_add_blob`，
在 reset 时直接 memcpy 到 host 指针，**不经过 `address_space_write`**。
`HENGE_DEBUG_DMA=1` 显示钩子零调用。

### 钩子现在的状态

代码就位且路径明确：

```c
/* system/physmem.c, flatview_write() */
if (henge_enabled() && memory_access_is_direct(mr, true, attrs)) {
    hv_engine_dma_written(henge_accel_machine(), addr, l);
}
```

并且加了**可分桶的计数器**（`HENGE_DEBUG_DMA=1`），把两种失败模式区分开：
`calls`（钩子根本被调没被调）与 `effective`（调了但没失效翻译）。

**已证实的一半**：`smc.S` 证明 `code_pages` 位图 + `hv_invalidate_code` 这条
失效机制有效（`0x1111` → 改写 → `0x2222`，与 TCG 一致），而 DMA 钩子调用的
是**同一个** `hv_dma_written`。

**未证实的一半**：一次真正经过 `flatview_write` 的 RAM 写。三次尝试都被
qemu-user 的限制或设备层细节挡住。

**这意味着什么**：在真实硬件或 KVM 宿主上，`-device edu` 的 DMA 与 gdbstub
都能工作，这条验证是可做的。在当前交叉编译 + qemu-user 的验证环境里做不到。
**Linux 起来之后，模块加载会自动覆盖这一项** —— 内核从盘 DMA 读模块进 RAM
再执行，那是最真实的用例，且不需要任何脚手架。

## 11.4 这一轮的净收获

| 项 | 结果 |
|---|---|
| `-cpu max` | **修好了**，根因是 QEMU 自己的 initfn 门控漏了 henge，不是引擎的 ID 视图 |
| `-cpu max` 与 tcg 的 ID 差异 | **查清并定性为正确**（引擎不宣称它翻译不了的扩展） |
| CNTVOFF | 从 env 双向同步 |
| MMIO 读路径 | **首次独立验证通过**（UARTFR + 4 GiB 以上的 ECAM） |
| PCIe 枚举 | 从零实现并验证（ECAM/MMIO 地址来自 dumpdtb，BAR 分配/使能/回读全对） |
| DMA 钩子 | 代码就位 + 可观测计数，**触发点未证实** |
| 8 项回归 | 全绿 |

## 11.5 遗留（按优先级）

1. **把 Linux 拉起来**——这是所有剩余项的公共前置。`-cpu max` 修好后，guest
   侧不再有已知的启动阻塞。
2. DMA 钩子的实证（Linux 起来后由模块加载覆盖，或换到 KVM 宿主做）。
3. `virtualization=on`（需要引擎支持 EL2，工作量大且当前用不到）。
4. `edu` 的 BAR 读不到设备——真要在 Linux 之前查，下一步是 `-d unimp` 看
   gpex 的地址翻译，或者对比 `xp` 与 guest 读在同一时刻的 flatview 状态。

---

# 12. 第十七轮：Linux 起来了

## 12.1 端到端验收通过

`work/henge-boot.sh`（新脚本）用真实的 `output/bin/Image`（Linux 6.12，49 MB，
内置 initramfs）跑完整启动：

```
================ henge, smp=1 ================
Booting Linux on physical CPU 0x0000000000 [0x411fd070]
psci: PSCIv1.1 detected in firmware.
Run /myinit as init process
|  guest userspace is alive: /myinit on PID 1 (static)  |
  alu        30.34 ns/iter
  mem        37.28 ns/iter
  call       49.20 ns/iter
  branch     26.99 ns/iter
  arch_timer IRQ: 4048
  rcu stalls: 0

================ tcg 对照, smp=1 ================
Booting Linux on physical CPU 0x0000000000 [0x000f0510]
|  guest userspace is alive: /myinit on PID 1 (static)  |
  alu   (no memory)    18.92 ns/iter
  mem   (load+store)   35.29 ns/iter
  arch_timer IRQ: 15553
  rcu stalls: 0
```

**五个判据逐条对上**：

| 判据 | 意义 | 观测 |
|---|---|---|
| `MIDR 0x411fd070` | ID 组转发 | henge 报 a57，tcg 报 `0x000f0510`——**两者都来自各自的 cp_regs，都不是引擎的 A76** |
| `psci: PSCIv1.1 detected` | PSCI 转发 | 引擎不再自己解释 HVC，QEMU 的 conduit 应答 |
| `Run /myinit as init process` | 完整内核 | MMU、ELF 加载、用户态、syscall 全通 |
| `arch_timer IRQ: 4048` | timer 闭环 | **真实负载下**，不是探针。TCG 是 15553（它跑得更快，tick 更多） |
| 四个基准跑完 | 不是刚好停在 lucky 点 | alu/mem/call/branch 全部有输出 |

性能同量级（alu 30.34 vs 18.92，mem 37.28 vs 35.29）—— **注意这两个数都不能
当引擎的性能**：此刻 henge 和 tcg 都跑在 qemu-user（宿主 x86_64 解释
qemu-system-aarch64）里，宿主的解释开销是共同底噪，掩盖了加速器的差异。
真正的性能数字要等这棵树跑在 aarch64 宿主上，那才是 knee 曲线量的东西。

## 12.2 在这之前修掉的两个真 bug

Linux 能起来不是运气，是 §11.1 和 §10.7 那两个修好之后的直接结果：

- **`-cpu max`**：QEMU 的 `cpu_max_initfn()` 用
  `if (tcg_enabled() || qtest_enabled())` 门控整个函数体，henge 不在里面，
  于是 CPU 模型**完全没初始化**（所有 feature 位为 0），`arm_cpu_realizefn()`
  走 1K 页分支拒绝启动。加 `henge_enabled()` 后解决。
- **`env->regs` vs `env->xregs`**：我的寄存器同步写错了数组，对 AArch64
  等于什么都没做。PSCI 的 x0 传过去是 0。

这两个都是"不修就完全起不来"，且都不是引擎的问题——一个是 QEMU 的 accel
枚举漏了，一个是移植层的数组选错。

## 12.3 SMP 仍未通过，根因已定位到引擎的锁

`-smp 2` 会在 31 秒处报 RCU stall；`-smp 4` 同样。试过的组合：

| 尝试 | 结果 |
|---|---|
| `-smp 2` 默认 | RCU stall at 31s，CPU1 停在 `_nohz_idle_balance` |
| `-smp 2 nohz=off` | **通过**（`userspace is alive`，无 stall，日志 77 行 vs 189 行） |
| `-smp 4 idle=poll` | 仍然 stall，CPU3 停在 `handle_softirqs` |

`nohz=off` 能过而 `idle=poll` 不过，说明这**不是**"CPU 睡下去醒不来"（那两种
都该失败），而是 **nohz 的 idle balance 需要 CPU 间快速协作**，而引擎做不到。

根因在引擎的设计里，不在移植层：

```c
/* engine/core/machine.h */
/* With more than one CPU, only the holder of this runs guest code
   (a fair ticket lock, handed over at every kick and while a CPU sleeps). */
```

`hv_big_lock` 是**互斥**的：同一时刻只有一个 vCPU 在跑 guest。RCU grace
period 要求所有 CPU 都报告 quiescent state，而"轮流持有大锁"让慢的那个 CPU
迟迟轮不到，超过 21 秒阈值就报 stall。

这是引擎为 macOS/Windows 的 SMP guest 设计的取舍（那两个 guest 的 CPU 间
耦合远没有 Linux 的 RCU 这么紧），**不是移植能修的**：
要真正 SMP，得让引擎支持并发执行 guest 代码（每个 CPU 的 TLB 已经独立，
但大锁把所有东西串起来了）。那是引擎侧的架构改动，不是接口对接。

**结论**：henge 的后端在 `-smp 1` 下功能完整；`-smp > 1` 需要引擎先放弃
大锁。这条写进 README 的已知限制。

## 12.4 现在的状态

> 这张表是第十二轮的快照，其中 SMP 一行后来被推翻（`hv_big_lock` 是二分
> 开关且从未打开，引擎本来就是真并行），最新状态见第 13 节。

| 项 | 状态 |
|---|---|
| 取指 / 执行 / MMIO（读写）/ WFI | ✅ |
| 内存镜像（RAM + ROM）、reset、region 变化 | ✅ |
| 系统寄存器转发（ICC_*、ID 组、timer 控制面、CNTFRQ） | ✅ |
| timer 闭环（CVAL → gtimer → IRQ → 引擎异常） | ✅ 真实负载下 4048 次 |
| PSCI（CPU_ON / SYSTEM_OFF） | ✅ 单核；SMP 受限于大锁 |
| 迁移拒绝 | ✅ |
| **Linux 6.12 启动到用户态** | ✅ **本轮** |
| `-smp > 1` | ❌ 引擎的 hv_big_lock 互斥（架构问题） |
| `virtualization=on`（EL2） | ❌ 引擎不建模 EL2 |
| DMA→SMC 实证 | ⚠️ 代码就位，触发点未证实 |

## 12.5 下一步

1. **SMP 是唯一的真缺口**，且它不在移植层。两条路：
   - 引擎放弃 `hv_big_lock`，改成真正的 per-CPU 并发（大改动，但 kernel 的
     RCU/scheduler 只有在多核下才完整跑起来）；
   - 或者接受 `-smp 1` 并把这条写死为已知限制。
2. DMA→SMC：现在 Linux 起来了，**模块加载就是最真实的验证**——
   `insmod` 一个模块要经过"盘 → DMA → RAM → 执行"。需要先让 virtio-blk 或
   NVMe 通（PCIe 枚举那套已经写好了，见 `edu.S`）。
3. `-cpu max` 在 henge 下等价于 a57 特性集。如果将来引擎翻译 SVE/PAuth，
   再在 ID 组里相应放宽——但**不要提前宣称**。

---

# 13. 第十八轮：UEFI 起来了，以及它背后两个从未被写对的寄存器

`-smp 1` 和 `-smp 2` 下 edk2 都跑到 **`UEFI Interactive Shell v2.2` / `Shell>`**，
`EraseSingleBlock` 错误 0、`ASSERT` 0。Linux 基线同时通过
（gicv2/v3 × smp 1/4 四组，`userspace is alive`，零 stall 零 assert）。

真正值钱的不是"能起来了"，而是**为什么之前起不来**——两个 bug 都不在引擎里，
都在移植层，而且都是"少写一行"的形态。

## 13.1 MemoryListener 从未被赋值，因此它从未被调用

```c
static const MemoryListener henge_memory_listener = {
    .name = "henge",
    .region_add = henge_region_add,
    .region_del = henge_region_del,
};
...
memory_listener_register(&h->listener, &address_space_memory);   /* ← 少了赋值 */
```

QEMU 派发回调写的是 `if (_listener->_callback)`，所以**函数指针为 NULL 的
listener 会被静默跳过**：注册成功、结构体躺在地址空间队列里、一次都不调用。

它之所以潜伏了这么多轮，是因为 `setup_post` 里有一次整树遍历
（`flatview_for_each_range`），把初始映射完整兜住了。缺口只在**之后**打开，
而打开它的正是 pflash：

`pflash_write()` 的第一行是

```c
    if (!pfl->wcycle) {
        /* Set the device in I/O access mode */
        memory_region_rom_device_set_romd(&pfl->mem, false);
    }
```

而 `flatrange_equal()` 显式比较 `romd_mode`（`system/memory.c:256`），
所以**每一次 CFI 命令序列都会让 FlatRange 变化、重建 flatview**——
这是"镜像必须撤下"的唯一信号。信号没人接，于是：

1. 窗口在 romd-off 期间仍然被镜像成只读 RAM；
2. guest 读状态寄存器，拿到的是**擦除态 flash 的裸内容 `0xFFFFFFFF`**；
3. 全 1 状态位被 edk2 解读成 `VPP Range Error` + `Command Sequence Error` +
   `Block Erase Error`；
4. edk2 认为块锁死，重试 unlock，永不成功 → 单 PC 死循环
   （未 trace 时 101 次写，带 pflash trace 时 9.8M 次）；
5. 变量存储初始化不了 → Variable / VariableWrite / Capsule /
   MonotonicCounter / RTC / Bds **六个 Arch Protocol 全部 not present**；
6. `DxeCore` 在 `DxeMain.c(567)` 断言。

**那条 ASSERT 是下游现象，不是第二个 bug。** 之前把它当独立问题追过一轮，方向错。

### 三层同时开 trace 才定位到

单独任何一层都指向错的结论：

| 层 | 看到什么 | 否掉了什么 |
|---|---|---|
| QEMU `pflash*` trace | 值到达设备时是 `0xff00ff`/`0x900090`/`0xe800e8` | 否掉"引擎转发把值搞坏了"——TCG 同样的位模式 |
| 新增 `trace=mmio`（含 guest PC） | 整个 flash 窗口**只有写、没有一次读**；写全来自同一个 PC | 否掉"guest 在重试"，确定是读走了 RAM |
| `flatrange_equal()` 临时打印 | `romd 1->0 ... equal=0`，判据正确 | 把范围收窄到"判定对但回调没来" → listener |

`trace=mmio` 是本轮新增的通道（`HENGE_TRACE_MMIO`），**打印的是访问之后的值**，
所以读也能看到实际返回了什么——这正是 pflash trace 永远看不到的那一半。
它支持 `HV_MMIO_PA` / `HV_MMIO_LEN` 限定窗口，否则串口会先吃掉配额。

## 13.2 `hv_machine_add_ram()` 每个 add/remove 周期漏一个槽

`hv_machine_del_ram()` 是**原地退役**（`host=NULL, size=0`），不改 `m->nram`；
而 `add_ram()` 一直是 `&m->ram[m->nram++]`。所以每个周期永久消耗一个槽，
`HV_MAX_RAM` 只有 8，而 pflash 每次 CFI 写要做两轮 del+add。

现象：UEFI 带着二十七行 `failed to mirror virt.flash1` 一路跑到 shell——
即**从第 9 次切换起，64 MB 变量窗口在引擎里根本不存在**，每次 flash 访问
都静默降级成 MMIO 往返。能跑，但那是靠 MMIO 兜住的，不是设计。

修法是 `add_ram()` 先找退役槽复用。**不要**改成在 `del_ram()` 里压缩数组：
`hv_ram_lookup()` 发出的是指向数组元素的裸指针，调用方会跨调用持有它，
压缩会把它们变成 use-after-move。先试的就是压缩，第一次 romd 切换就 SIGSEGV。
`add_ram()` 的注释里记了这条。

## 13.3 测量卫生：varstore 不能跨轮复用

`-drive if=pflash,unit=1` 的镜像会被 edk2 **写回**。之前几轮把同一个
`t1.img` 反复喂给不同的二进制，于是"上一轮失败的残留变量"变成了下一轮的
初始条件——有一轮因此看起来"不 assert 了"，其实只是脏数据让 edk2 走了别的分支。

现在每轮都从全 `0xFF` 的模板拷贝：

```sh
tr '\000' '\377' < /dev/zero | head -c 67108864 > vars0.img
cp vars0.img v$N.img
```

这也是为什么 TCG 对照组（干净 varstore）能给出决定性判据：
**同样干净输入，TCG 0 次擦除错误并走到 PXE，henge 31 次擦除错误并断言**。
在此之前，"是不是 henge 的问题"一直没被严格证明。

## 13.4 状态表（本轮实测）

| 项 | 状态 |
|---|---|
| Linux 6.12 → 用户态 | ✅ gicv2 smp1 18.22 / gicv2 smp4 24.51 / gicv3 smp1 18.53 / gicv3 smp4 19.18 |
| `-smp 2`（默认 GICv2） | ✅ 19.04 / 18.68 / 19.06 → 中位 **19.04** |
| **edk2 → UEFI Shell** | ✅ smp1 与 smp2，擦除错误 0 / ASSERT 0 / mirror-fail 0 |
| romd 动态语义（romd 切换撤镜像） | ✅ 由 MemoryListener 承担 |
| EL2（`virtualization=on`） | ❌ 引擎不建模 EL2 |
| `-cpu max` 的 LSE 面 | ⚠️ `HV_NO_LSE=1` 时按 `cpu_isar_feature(aa64_lse)` 驱动 |
| DMA→SMC 端到端 | ⚠️ 代码就位，设备写已翻页的场景仍未构造 |

## 13.5 并发纪律：引擎的设计搬过来了，但"属主原则"被移植层绕过

先确认搬过来了什么。`diff` 两棵树：`core/` 的锁逻辑**逐字未改**，
差异只有 LSE 初始化与 WFI 注释。所以下列设计原封不动在跑：

- `big_lock` 是可选的票号轮转 GIL，`big_lock_on = ncpus > 1 && getenv("HV_BIG_LOCK")`
  —— 默认**空操作**，真并行
- per-CPU 请求队列 + `req_seq`/`ack_seq` 握手（`hv_cpu_post_tlbi` / `hv_cpu_sync`）
- `tr_mu` 只锁"发布"：翻译在锁外做，JIT 空间原子预留，发布前再查一次，重复就丢弃
- `stw_mu` 停世界：**等待时不持任何锁**
- 同页链完全无锁（陈旧块只能互相到达，逃不出去）；跨页链才进 `tr_mu`
- `page_gen` 代际号代替读侧加锁

**被绕过的是第一条纪律**（`machine.h`，`HvPerCpu.req_mu` 上方）：

> only the owner may touch its TLB and branch cache while it runs

引擎给的唯一合法跨线程手段是"投递请求 + 等 ack"。但移植层有两处直接从
QEMU 主线程（持 BQL）改引擎状态：

1. `hv_machine_del_ram()` / `hv_engine_machine_reset()` 里的
   `for (...) hv_tlb_flush(m->cpus[i])`。`hv_tlb_flush()` 会
   `hv_ijc_reset()` + `memset(cpu->tlb, 0x80, ...)` + `hv_tlb_stash_drop()`，
   全是属主私有结构。
2. `hv_machine_add_ram()` 在 BQL 下写 `m->ram[i]` 全字段，而 vCPU 线程的
   `hv_ram_lookup()` 是无锁遍历 `m->nram` / `ram[i].pa/size`（memop.c 慢路径每次都调）。

### 实测：168 次打在进行中的 vCPU 上

`HV_DBG_FLUSH=1` 在 `del_ram` 的 flush 循环里读 `p->active`
（`machine.h:182`：*"inside the dispatcher loop (0 while parked)"*）：

```
edk2 -smp 2:
  henge: VIOLATION del_ram flushed ACTIVE cpu 0 (hit 168 of 341)
  Shell>                                    ← 照样起来了
```

341 次里 168 次，**49%**。原因是 romd：`pflash_write()` 每次命令序列都
`set_romd()`，每次切换都是一次 `region_del` + `region_add`，而 del 走的就是这条路径。
所以 edk2 跑的时候，QEMU 主线程每两次就清一次正在跑的 vCPU 的 TLB 和分支缓存。

### 这不是"性能与确定性损失"，是 SIGSEGV：已实证并修复

上面那段"幂等且退化安全、不会产生错误的内存访问"是**错的**，而且错得可以量化。
`work/probe/tlb_race.c` 用引擎的字面结构布局和字面访问序列
（tag 加载 → 判定 → addend 加载）复现：

```
写方 memset(0x80)，1 写 1 读，5 秒：
  reads        159,049,569
  tag hit      148,398,542
  straddled        619,156    ← 看到有效 tag，拿到 0x8080808080808080 的 addend
```

0.42% 的命中跨界，每一次 `va + 0x8080808080808080` 都是野地址。

**机制**：不是"addend 先清、tag 后清"——`memset` 低→高，字段顺序是
`read_tag, write_tag, exec_tag, addend`，方向恰好是对的。真正的洞是
**读方两次独立加载之间被写方插入**：读到旧 tag（命中）→ 写方改掉 addend →
读到垃圾。反向对照 `probe_hit.c` 证明这一点：写方只失效 tag、不动 addend 时，
2000 万次命中 **100% 拿到有效 addend，垃圾 0 次**——不是靠抹掉命中蒙的。

### 修法：延迟失效 + 引擎自己的 stw（Phase 1，已落地）

引擎在 `dispatch.c:18` 早把契约写死了：

> `/* Every other CPU is parked (stop_the_world): the one moment the TLB layout can change. */`

移植层绕过的是这条。而 dispatcher 主循环（`dispatch.c:964`）本来就有检查点：

```c
if (flush_pending || stw_active) { stop_the_world(cpu); continue; }
```

所以不需要新协议，只需要**不再从 listener 直接 flush**：

| 侧 | 动作 |
|---|---|
| listener（BQL 线程） | `del_ram_flags(..., defer=1)` 只退役窗口（`size=0`，慢路径立即改道 MMIO），再 `hv_engine_request_flush()`：置 `need_tlb_flush` + `flush_pending`，wake 全部 vCPU，**不碰任何 TLB** |
| vCPU（dispatcher 入口） | 见 pending → `stop_the_world` → 全员 `active==0` → `hv_flush_blocks` 清 block/JIT/IJC/ret_tab/xchained；因 `need_tlb_flush` 连带清空每张 TLB |
| 握手 | `park`/`unpark` 两阶段（先置 `active=1`、再查 `stw_active`）已封住"刚醒来就被刷"，无需额外处理 |

core 侧只动了三处（`machine.h` 一个字段、`dispatch.c` 一个条件、清标志的次序），
其余全在移植层。`hv_cpu_sync()` 等 ack 的方案**不能用**：它会阻塞，而调用者持
BQL，vCPU 若正在 `henge_mmio_forward()` 里等同一把 BQL 就死锁。所以
`request_flush` 故意不等。

### 窗口真实存在，且已量化

`HV_DBG_FLUSH=1`（现在是 Phase 1 验收门）打印"请求 → 实际 flush"的延迟：

```
edk2 -smp 2：379 次请求 → 240 次实际 flush（合并 37%）
  典型 736–847 µs，最大 2262 µs
```

这 ~700 µs 内旧 TLB 仍以 RAM 直读应答 flash 读，最初那个 `0xFFFFFFFF`
瞬态会重现——被 edk2 的重试循环吸收。窗口有界、可测，且严格优于修复前
（修复前是同一窗口再叠加撕裂读）。**"0 violation"不能读成"0 窗口"**，
所以这个数字必须留在文档里。

回归：edk2 `-smp 2` → `Shell>`，擦除错误 0 / 断言 0；
Linux gicv2 smp1 18.83 / smp4 19.49 / gicv3 smp1 18.46 / smp4 19.65；
smp2 三取中位 **18.91**（修复前 19.04，无退化）。

### 仍未做：lookup 值返回

`hv_ram_lookup()` 返回 `HvRam *`，而 `HvBlock.ram` 会**跨调用持有**它。
romd del→add 复用同一槽位后，旧 block 的 `ram->page_gen[pg]` 读到的是新 region
的全新零值计数器：不是 use-after-free（`add_ram` 重新 calloc），而是
**代际比较拿到错误基线**，可能把陈旧 block 判为有效。当前靠 flush 及时到达
把窗口压到上面那 ~700 µs。彻底做法是 lookup 改值返回（慢路径 TLB miss 才走，
热路径不受影响），尚未落地，列入 13.6。

## 13.6 仍存在、未修复

1. `hv_engine_load_state()` 对 `el > 1` 返回 -1 —— EL2 不可用。
2. `henge_service_sysreg()` 在 accessfn 拒绝时注入 UNDEF，而不是带 syndrome 的 trap。
3. `mmio_fwd_read()` 失败返回 0；错误没有上报通道（主要主人在独立模式）。
4. 迁移被显式拒绝 —— 设计如此，非缺陷。
5. `henge_sync_irq_current()` 每次 MMIO 转发都 re-sync，高频 MMIO 有浪费；
   正确性无问题。
6. GICv3 + ITS + MSI 未带真实设备验证过；唯一的 MSI-X 证据在 GICv2 上。
7. `hv_ram_lookup()` 仍返回值指针，而 `HvBlock.ram` 跨调用持有它；romd 复用
   槽位后旧 block 的代际比较会拿到新 region 的零基线。当前由 Phase 1 的 flush
   把窗口压到 ~700 µs（见 13.5），不是彻底解决。~~listener 从 QEMU 线程直接
   flush~~ ← 已在 13.5 修复（延迟失效 + stw）。
8. **`HV_MMIO` catch-all 让 flash1 每次访问都拿 BQL**：不镜像之后，read-array 期间的
   读也经 `address_space_rw`，而 TCG 在 `romd_mode=true` 时读直达 RAM。功能正确
   （QEMU 自己判 romd_mode），代价是每次 flash 读一次 BQL 往返。edk2 启动实测
   无可见退化，但 NVRAM 密集访问（bcdboot、变量枚举）未单独压测。
9. **backing store 生命周期未验证**：`region_del` 返回到 vCPU 执行 flush 之间
   QEMU 不得释放该区间的 host 内存。pflash 的 `pfl->storage` 常驻使本场景成立，
   但这是机制性巧合而非契约。真做 RAM hot-unplug 之前需要代码级验证
   RAMBlock unref/munmap 相对 `region_del` 的时序，并给 henge 加 RAM unplug
   fail-fast 守卫（抄 gicv2/EL2 拒绝的先例）。

## 13.7 对照上游：WindowsiOS 的 pflash 划分解释了 0xFFFFFFFF 的真正根源

读了 `src/WindowsiOS/devices/pflash.c` 之后，我们这套 romd 方案的性质变了——它不是"唯一可行解"，
而是**QEMU 强加的妥协**，而且妥协点正好落在出错的那个位置上。

### WindowsiOS 怎么划（同一个 edk2 ArmVirtQemu，同一块 -M virt 布局）

```c
if (readonly) {
    hv_machine_add_ram(m, pa, f->size, f->data, 1);                     // flash0: 只读 HvRam
} else {
    hv_machine_add_mmio(m, pa, f->size, f, pflash_read, pflash_write,
                        "pflash-vars");                                 // flash1: 纯 MMIO
}
```

- **flash0 @0x0**：edk2 code，注册成**只读 RAM**，JIT 就地执行固件。
  写被 `if (f->readonly || off >= f->size) return;` 直接丢弃——纯 ROM 语义，没有 romd 那套动态切换。
- **flash1 @0x4000000**：NVRAM，注册成 **MMIO 设备**，`pflash_read/pflash_write` 是完整的
  CFI01 状态机，写和擦除通过 `persist()` → `pwrite()` 落盘到 `vars.fd`。
  **它从不被映射成 RAM。**

`pflash_read` 的第一句是全部关键：

```c
if (f->cmd == CFI_READ_ARRAY) { memcpy(&v, f->data + off, size); return v; }
/* 否则读 status / manufacturer ID / CFI 查询表 */
```

读存储内容**只在 read-array 模式下**发生；命令序列期间读的是 CFI 状态寄存器。
因为区域不映射成 RAM，这个判断永远成立。

### 我们的做法等于把 romd_mode 钉死在 true

我们把 flash1 也镜像成只读 RAM（因为 QEMU 报 `romd=1`），于是：

| | QEMU TCG | 我们（镜像 flash1） |
|---|---|---|
| read array 期间读 | flatview 直达 RAM | 引擎直达 RAM —— **一致** |
| 命令模式（romd_mode=0）读 | flatview 调 `pflash_mem_read` → 状态机 | 引擎仍直达 RAM —— **读回存储内容** |

这就是 `StatusRegister:0xFFFFFFFF` 的来源：擦除态 NOR 的裸内容被当成全 1 的错误位。
listener 没赋值只是让 romd 切换后镜像没撤下；**就算 listener 一直正常，命令序列期间
那 ~700 µs 的窗口照样读错**（13.5 已量化）。根因是"镜像了一块会被当设备读的区域"。

### 实测数据支持这个划分

TCG 下开 `pflash*` trace（`-drive if=pflash` 双单元）：

```
pflash_io_read   : 12   全部 virt.flash1
pflash_io_write  : 162  全部 virt.flash1
flash0            : 0 次设备访问（全程 read array，读直达 RAM）
```

flash0 从不进命令模式，所以把它当纯只读 RAM 完全正确；flash1 每次访问都该走设备，
且量很小（约 174 次），转发代价可忽略。

### 三方摆在一起看，判据就出来了

| | flash0（edk2 code） | flash1（NVRAM） | 谁决定 |
|---|---|---|---|
| **WindowsiOS** | `hv_machine_add_ram(readonly=1)` | `hv_machine_add_mmio` | 调用者传的标志 |
| **WindowsPixel** | 同上（两树 `pflash.c` 逐字相同） | 同上 | 同上 |
| **QEMU TCG** | `rom_device` + `romd_mode` | 同左 | flatview，每次 `set_romd()` 重建 |
| **我们（修复前）** | 镜像 ✓ | **也镜像 ✗** | 无（只看 `is_romd`） |

两棵参考树能传 `readonly`，是因为设备是它们自己 `create` 的——**它们知道答案**。
QEMU 里我们不知道，而 `-drive readonly=on` 只影响 blk 层：
`memory_region_is_rom()` 是 `mr->ram && mr->readonly`，romd 时为假；
两块在 MemoryRegion 层完全一样。

但行为把它们分开了，而且这个差别是**结构性的**，不是巧合：

- flash0 从不进命令模式 → `romd_mode` 永不变 → flatview 永不变 → **`region_del` 从不发生**
- flash1 每条 CFI 命令写都 `set_romd()` → 每次重建 → **`region_del` 每次发生**

所以判据是：**一个 romd 区域只要被 del 过一次，就证明它是会被当设备读的那种，永久停止镜像。**
这不是启发式，是从 `pflash_write()` 第一行推出来的充分条件。

### 已落地，实测两项收益

```c
/* henge_region_del */
if (h->started && memory_region_is_romd(s->mr) && h->nnomirror < 8) {
    h->nomirror[h->nnomirror++] = (..){pa, size};      /* 拉黑 */
}
/* henge_mirror: 命中黑名单就跳过，并确保早先的 add 已撤销 */

/* henge_region_del 末尾 */
rc = hv_machine_del_ram_flags(..., defer=1);
if (rc == 0) hv_engine_request_flush(h->m);            /* 引擎里没有它的窗口，就没什么可刷 */
```

edk2 `-smp 2` 实测：

| | 修复前 | 只拉黑 | 拉黑 + 免多余 flush |
|---|---|---|---|
| `Shell>` | ✓ | ✓ | ✓ |
| 擦除错误 / 断言 | 0 / 0 | 0 / 0 | 0 / 0 |
| stop-the-world flush | 240 | 240 | **2** |
| flash1 镜像次数 | 167 | 0 | 0 |
| 窗口 max | 2262 µs | 2520 µs | 1308 µs（仅 2 次） |

第一项收益（读永远经 CFI 状态机、0xFFFFFFFF 从根消失）在"只拉黑"就已拿到；
第二项（flush 归零）需要"引擎没有就不刷"这半行——因为 flatview 照样会变，
但引擎里已经没有可失效的东西。**240 → 2 是 99.2% 的 stw 消除**，且这 2 次是
boot 期镜像表变更本身，不是 flash 引起的。

回归：gicv2 smp1 18.65 / smp4 19.70 / gicv3 smp1 18.46 / smp4 19.21；
smp2 18.98 / 19.50 / 19.00 → 中位 **19.00**（无退化）。

Phase 1 的延迟失效仍然保留：RAM hotplug 要走它，且它是"引擎确实持有时"的正确路径。
但它不再是 edk2 启动路径上的关键路径。

## 13.8 第三步：UEFI 引导 Debian 12（pflash + 盘，不是 -bios）

命令行沿用已经验证到 `Shell>` 的那条通路，只加磁盘：

```sh
qemu-system-aarch64 -M virt,gic-version=3 -cpu max -m 2048 -smp 2 -accel henge \
  -drive if=pflash,format=raw,unit=0,file=edk2-aarch64-code.fd,readonly=on \
  -drive if=pflash,format=raw,unit=1,file=vars.img \
  -drive if=none,id=d0,format=qcow2,file=deb12.qcow2 -device virtio-blk-pci,drive=d0 \
  -drive if=none,id=sd,format=raw,file=seed.iso      -device virtio-blk-pci,drive=sd
```

镜像用 Debian 官方 `debian-12-genericcloud-arm64.qcow2`（325 MB，直接用，不自制——
自制要走 netboot 安装，纯浪费）。它是 GPT + **ESP 在 p15、root 在 p1**，
ESP 里已有 `EFI/BOOT/BOOTAA64.EFI` + `debian/grub.cfg`，
**removable media 路径，不依赖 NVRAM 的 BootOrder**——所以每轮换一份全新 0xFF
的 vars 也能引导，跨轮污染问题自然消失。

### 硬验收（guest 内 cloud-init 自己跑，不是 fdisk 看块设备）

```
--- uname ---
Linux deb12 6.1.0-54-cloud-arm64 #1 SMP Debian 6.1.190-1 (2026-10-16) aarch64

--- system state ---
Reached target multi-user.target / graphical.target
        （systemctl is-system-running 当时仍报 "starting"：cloud-init final 未完）

--- block ---
vda     3G disk
├─vda1  2.9G  /              ← EXT4，resize 到全盘
└─vda15 127M  /boot/efi      ← ESP
vdb     366K                ← cloud-init seed

--- dd 256MB（实测 IO，不是挂载成功就算）---
268435456 bytes copied, 1.07568 s, 250 MB/s

--- interrupts ---
10: 14617 13969 GICv3 27 Level  arch_timer
51:     0     0 ITS-MSI 32768 Edge virtio1-config
52:  1611     0 ITS-MSI 32769 Edge virtio1-req.0     ← virtio-blk 中断真的在投递
53:     0  2217 ITS-MSI 32770 Edge virtio1-req.1
55:    84     0 ITS-MSI 49153 Edge virtio2-req.0
57-59:            ITS-MSI 16384..   virtio0（net，无 link 故为 0）
```

**GICv3 + ITS + LPI 真实投递，带真实设备**——悬了四五轮的那个 MSI 项，这一步收掉了。
两列 `req.0` / `req.1` 非零且分布在不同 vCPU 上，说明多队列各自绑到不同 ITS 中断，
不是单队列兜底。

### 这步顺带收的面

- **systemd 全家桶**（比 `/myinit` 硬一个量级）：`Reached target graphical.target`，
  dbus、logind、ssh、getty、apt-daily、fstrim、e2scrub、unattended-upgrades 全部起来了
- **pl031 RTC**：`audit: ... audit(1794807404.144:2)` 时间戳连续推进，说明 edk2 传的
  时间被 guest 接受，时钟在走
- **timerfd / nohz 真实负载**：`arch_timer` 两列各 14617 / 13969，两 vCPU 均衡
- **udev uevent 风暴**：vda/vdb/分区全部识别，`/dev/vdb` 挂进 cloud-init
- **DMA→SMC 免费加压**：virtio-blk 的 `dd` 是设备 DMA 写 guest RAM（250 MB/s 跑满），
  比 `-device edu` 那套自证强得多。**但必须在记录里写清楚：未炸 ≠ 无洞。**
  受控的"设备写已翻译页"场景仍是欠账（13.6 第 9 条），这只是免费加压，不是验证。

### 仍未做

- `-netdev user` **没有编进这个交叉编译的二进制**（`network backend 'user' is not
  compiled into this binary`）。要给 guest 网络，得先重新 configure 加回 slirp，
  或用 tap（需 `/dev/tun`，root 场景有）。所以第四步的"后端三选"目前只有 tap 一条路。
- 第四步的 gicv3+MSI 已经在本步意外收掉了（virtio-blk 走的就是 MSI-X），
  剩下的是 virtio-net + 流量压测。

## 13.9 第四步：把 slirp 编回来（user 后端），以及非 root 的边界

### 先纠正一个前提：不是 userns 的问题

设备侧三条路都实测过，全部堵死，而且**没有一条是 userns**：

| 路径 | 实测 | 结论 |
|---|---|---|
| 设备内 `tap` | `/dev/tun` 属 `system:vpn`，`u0_a280` 不在组内 | 无权限 |
| 设备内 `pasta`（非特权 passt） | `unshare -Urn` → **`Invalid argument`**，内核禁 userns | 不可用 |
| 设备内 `passt`（app 上下文） | `rc=159` = SIGSYS；`grep Seccomp /proc/self/status` → **`Seccomp: 2`** | **seccomp filter 杀 syscall**，不是 userns |

第三条是最有诊断价值的：`Seccomp: 2`（filter 模式）下 passt 一启动就被 SIGSYS；
换到 `u:r:magisk:s0` 上下文是 `Seccomp: 0`，passt 立刻能打出 `passt 2026_10_02`。
**所以 app 上下文的杀点是 seccomp，改 userns 参数没用。**

按用户要求**不启用 root**，那这三条都不走。正确的解法是另一条：
**把 slirp 静态编进 QEMU**，`-netdev user` 就回来了，全程用户态，零特权。

### 编 slirp 的三个坑

源码用 `src/WindowsPixel/third_party/libslirp`——那份已经把 glib 剥成单头垫片，
31 个 `.c` 直接过交叉编译（`build-libslirp-android.sh`，产出 221 KB 静态库 + .pc）。

1. **`slirp.wrap` 会 fallback 到 subproject。** 第一次编出来是
   `libslirp.so.0.4.0`（subproject 自己 clone 的 4.7.0），设备上直接
   `CANNOT LINK EXECUTABLE: library "libslirp.so.0" not found`。
   `nm` 一看 `slirp_new` 是 `U` 不是 `T` 就露馅了。
2. **修法不是移走 subproject**（meson 会重新 clone），而是
   `-Ddefault_library=static`。改完 `slirp_new` 变 `T`，`readelf -d` 的 NEEDED
   只剩 `libz/libm/libdl/libc`。
3. **`PKG_CONFIG_LIBDIR` 对 meson 无效**：QEMU 的 configure 生成 cross file 时
   把它固化了，meson 探测仍报 `slirp found: NO (tried pkg-config)` 并继续走 fallback。
   所以必须靠 (2) 让 fallback 产出静态库，而不是试图让它找到我们的 .pc。

`-netdev help` 前后对比（设备上实测）：

```
修复前: socket stream dgram hubport tap bridge vhost-user
修复后: socket stream dgram hubport tap user bridge vhost-user    ← user 回来了
```

### 压测证据

`-netdev user` + `virtio-net-pci`（默认 MSI-X）+ `-M virt,gic-version=3`：

```
DHCP:  enp0s1 = 10.0.2.15/24,  gateway 10.0.2.2,  DNS 10.0.2.3
ping 网关: 2 packets transmitted, 2 received, 0% packet loss, rtt avg 1.766 ms

6 × curl (Packages.xz, 8,689,464 B each), 全程 http=200:
  r1  speed=5,096,707 B/s  t=1.70s
  r2  speed=8,513,081 B/s  t=1.02s
  r3  speed=8,257,066 B/s  t=1.05s
  r4  speed=  580,755 B/s  t=14.96s   ← 单轮离群
  r5  speed=7,868,824 B/s  t=1.10s
  r6  speed=4,878,112 B/s  t=1.78s
  峰值 ≈ 8.5 MB/s (~68 Mbit/s)
```

r4 那一轮慢 14 倍，是在同一镜像同一口令下的偶发；量级与 slirp 单线程
（用户态 TCP 栈，一个 event loop）相符，不是 henge 特有的。要排除是否 henge
引入，得用 tap 后端做对照——但 tap 需要 `/dev/tun`，非 root 不可得，
所以这一项**记为未对照**，不宣称"与 TCG 等价"。

`virtio1-req.0/req.1` 的中断计数在两列上都有增长，说明 MSI-X 多队列在真实流量下
继续工作，不只是前面 dd 那次。

### 顺带发现（未修）

`systemd-resolved` 不吃 slirp 下发的 DNS：`resolvectl dns` 设了 `10.0.2.3`、
`/etc/resolv.conf` 也写了 `nameserver 10.0.2.3`，`getent hosts` 仍 NXDOMAIN，
而 ping 网关 0% 丢包 —— **纯 DNS 问题，IP 层通**。用 `curl --resolve` 绕过做了压测。
非 henge 问题（slirp 的 DHCP 给 DNS 是标准行为），但会挡住任何"装包"类验证，
需要一条 seed 里 `systemctl disable --now systemd-resolved` 的绕法。

## 13.10 三方对照补全：非 root Android 上唯一的网络后端就是内置 slirp

上一节写了设备侧三条路怎么堵，但漏了最该先做的一件事：**看参考实现到底怎么联网。**
查完就发现 passt 这个方向本来就是错的。

```
$ ls WindowsiOS/host/net_*        ->  net_slirp.c  net_slirp.h
$ ls WindowsPixel/host/net_*      ->  net_slirp.c  net_slirp.h
$ grep -rl "net_tap\|tap_create\|passt" WindowsiOS/host WindowsPixel/host
  (空)
```

**两棵树都没有 tap，都没有 passt，只有内置 libslirp。** 而且 WindowsPixel 的 README
把限制写得很直白（Android 段原文）：

> Stage B: Google Pixel 9 (Tensor G4, Android 15/16) & ARM64 Android — APK Built ·
> Device Test Next — `make android-lib` builds ... (NDK API 34, **`-DHAVE_SLIRP=1`**,
> Tensor G4 `cpus 4..7` pinning, **SELinux `execmem` fallback**, `MAP_NORESERVE` RAM ...)
>
> —— 开篇另一句：*without root or KVM*

两棵树的 `net_slirp.c` 里，`hv_net_attach()` 只做三件事：两个 `pipe()` 做唤醒、
`slirp_new(&cfg, &callbacks, NULL)`、然后事件循环。`grep cap_|setuid|ioctl.*TUN|
SIOCSIF|system(|fork(` **零命中**。也就是说：iPhone 和 Pixel 9 上跑通的虚拟机网络，
从来没有用过一个字节的特权。

### 当前设备（PDYT20 / OP4E21）

| 项 | 实测值 |
|---|---|
| SoC | `ro.board.platform = mt6853`（Dimensity 700，6×A55 + 2×A76） |
| 型号 / 代号 | `PDYT20` / `OP4E21` |
| Android | 12 |
| 内核 | `4.14.186-kuan-jsbsbxjxh66-compile`（自定义编译） |
| `CapEff` / `CapBnd` | **`0000000000000000` / `0000000000000000`** |
| `Seccomp` | **2**（filter 模式） |

逐 namespace 试，**错误码把两类原因分开了**：

```
$ ls /proc/self/ns/
cgroup ipc mnt net pid pid_for_children uts        ← 没有 user

$ unshare --user true    -> Invalid argument       ← EINVAL：内核不支持
$ unshare --net  true    -> Operation not permitted ← EPERM：支持但权限不足
$ unshare --ipc/uts/pid/cgroup true -> Operation not permitted
$ ls /proc/sys/user/     -> 只有 max_cgroup_namespaces / max_inotify_*，无 max_user_namespaces
```

**`EINVAL` 和 `EPERM` 是两种完全不同的病：**

- `user` 是 `EINVAL` + `/proc/self/ns/` 里没有 `user` + `/proc/sys/user/` 里没有
  `max_user_namespaces` → **内核根本没编 `CONFIG_USER_NS`**。
  这不是权限问题，改 sysctl、改 SELinux、改 seccomp 都没用，只有重编内核。
  所以 `pasta` 在这台设备上永远跑不起来。
- 其余 namespace 是 `EPERM` + `CapEff=0` → 内核编了，但 Android app 上下文零能力。
  这是平台设计，不是可调参数。

### 三方矩阵

| | WindowsiOS | WindowsPixel | 我们（QEMU/henge） |
|---|---|---|---|
| 宿主 | iPhone A20 Pro · iOS 26/27 | Pixel 9 Tensor G4 · Android 15/16 | PDYT20 mt6853 · Android 12 |
| **网络后端** | 内置 libslirp（`slirp_new`） | 内置 libslirp 4.8.0（`-DHAVE_SLIRP=1`） | **QEMU `-netdev user` = 同一份 libslirp 4.8.0** |
| root | 不用 | **不用**（README 明写） | 不用 |
| namespace | 不依赖 | 不依赖 | 不依赖 |
| CAP | 不要 | 不要 | 不要 |
| `/dev/tun` | 不要 | 不要 | 不要 |
| 其它 Android 坑 | — | SELinux `execmem`（JIT 可执行内存）→ fallback | RAM 目录 SELinux（镜像须挪 `~/h`） |

结论：**非 root Android 上，内置 slirp 不是"退而求其次"，而是唯一解。**
passt/pasta/tap 三条路都要求内核 namespace 或特权，而 Android app 上下文两样都没有；
`CONFIG_USER_NS` 这台设备根本没编，`pasta` 连门都没有。

我们实测到的 8.5 MB/s 峰值（13.9）就是这条路的天花板量级——slirp 是单线程
用户态 TCP 栈。这跟 Pixel 9 上按下 `-DHAVE_SLIRP=1` 走的是同一条路，
所以"henge 比 TCG 慢/快"在这一项上不成立，瓶颈在 slirp 本身。


## 13.11 vhost-user：一直存在，只是被 `auto_features = disabled` 关掉了

### 先纠正一个错误断言

我在 13.9 之后的对话里说过「这棵树（QEMU 11.1.3）里没有 `vhost-user-net` 设备，
`hw/net/` 完整 47 个文件里只有 `vhost_net.c`」——**这个结论错了两处：**

1. `vhost-user-net` **不是设备名**，是 netdev backend 类型名。设备仍然是
   `virtio-net-pci`，通过 `-netdev vhost-user,...` 接上去。
2. 实现是存在的，只是分布在别处：

| 文件 | 作用 |
|---|---|
| `net/vhost-user.c`（13.5 KB） | netdev backend，负责 chardev/队列/特性的胶水 |
| `hw/virtio/vhost-user.c`（108 KB） | vhost-user 协议本体（`VhostUserRequest` 等） |
| `subprojects/libvhost-user/` | 后端侧共享库 |
| `docs/interop/vhost-user.rst` | 协议文档 |
| `net/meson.build:48` | `if have_vhost_net_user` 才编 `vhost-user.c` |

而 `-netdev help` 一直列着 `vhost-user` —— 那只是 QAPI 枚举，**不代表编进去了**。
真正的判据是运行时报错：

```
$ q-net2 -M virt -netdev vhost-user,id=n0,chardev=chr0
q-net2: -netdev vhost-user,id=n0,chardev=chr0: network backend
        'vhost-user' is not compiled into this binary
```

### 为什么没编：`auto_features = disabled`

`meson.build:243` 的条件链：

```meson
have_vhost_net_user = have_vhost_user and get_option('vhost_net').allowed()
have_vhost_user     = get_option('vhost_user').allowed()  # + libvhost-user
```

而我们的 build 里 **`auto_features = disabled`**（交叉编译时为了缩小体积设的），
`vhost_user` 和 `vhost_net` 都是 `auto` → 全部被判 disabled。显式打开：

```sh
./build/pyvenv/bin/meson configure build -Dvhost_user=enabled -Dvhost_net=enabled
```

### 编 libvhost-user 撞上 bionic 头冲突（8 个错误）

`subprojects/libvhost-user/libvhost-user.h` 自带一份
`standard-headers/linux/virtio_ring.h`，而 NDK sysroot 里也有同名头，
两份定义同一批结构体：

```
error: redefinition of 'vring_desc' / 'vring_avail' / 'vring_used_elem'
       / 'vring_used' / 'vring' / 'vring_packed_desc_event' / 'vring_packed_desc'
error: typedef redefinition ('uint64_t' vs '__u64')
```

两步修法（都在 `subprojects/libvhost-user/` 内，不碰 QEMU 主体）：

1. **`libvhost-user.h`**：Android 下改用系统头。

```c
#ifdef __ANDROID__
#include <linux/virtio_ring.h>
static inline int hv_vring_need_event(...) { /* 逐字照抄自带版 */ }
#else
#include "standard-headers/linux/virtio_ring.h"
#endif
```

2. **不能直接叫 `vring_need_event`**：QEMU 自己的
   `include/standard-headers/linux/virtio_ring.h:221` 也定义了同名函数，
   而 `util/vhost-user-server.c` 编译时走的是 QEMU 的 include 路径。
   两份都用 `_LINUX_VIRTIO_RING_H` 当 guard，谁先到不确定 →
   所以 Android 分支用独立名字 `hv_vring_need_event`，再在
   `libvhost-user.c` 里做别名：

```c
#ifdef __ANDROID__
#define vring_need_event hv_vring_need_event
#endif
```

### 设备侧联调（passt 作为 vhost-user 后端）

passt 支持 `--vhost-user`，但要三个都配对：

```sh
# 1) passt：vhost-user 模式 + 关掉 repair socket
./passt --vhost-user -f -q -s ~/h/vu.sock --repair-path none
#   --repair-path none 不可省：默认会再建 vu.sock.repair，
#   残留时启动即 "Socket path ... already in use"

# 2) QEMU：vhost-user netdev + share=on 内存
qemu-system-aarch64 -m 2048 \
  -object memory-backend-memfd,id=mem,size=2048M,share=on -numa node,memdev=mem \
  -chardev socket,id=chr0,path=$HOME/h/vu.sock \
  -netdev vhost-user,id=n0,chardev=chr0 \
  -device virtio-net-pci,netdev=n0
```

三个会挡住启动的细节：

| 现象 | 原因 |
|---|---|
| `Failed to connect to '<sock>': No such file or directory` | passt 没起，或 socket 路径不对 |
| `total memory for NUMA nodes (0x80000000) should equal RAM size (0x8000000)` | **漏了 `-m 2048`**，RAM 默认 128M 与 memdev 2048M 不匹配 |
| `Socket path .../vu.sock.repair already in use` | 上次 passt 残留，加 `--repair-path none` 或删 `.repair` 文件 |

### 为什么值得做

`-netdev stream` 走 passt 时，datapath 是
`passt → socket → QEMU 的 G_IO_IN read watch → qemu_send_packet_async → virtio-net`，
其中 doorbell 要经历 guest MMIO → accel 陷入 → BQL → `virtio_queue_notify` →
`virtio_net_handle_rx` → `qemu_flush_queued_packets` 才能恢复读取。

vhost-user 让 **guest 直接和 passt 共享 vring**，上面整条链都不在 datapath 上，
doorbell 由内核/后端直接处理。这是唯一能真正绕开 QEMU 网络栈的路
（WindowsiOS 引擎用「在 MMIO 处理函数里同步 notify」达到同样的效果，
但那需要改 accel，而 vhost-user 不需要）。


### 13.11 续：vhost-user 打通到哪一步，卡在哪

#### 已打通（实测）

| 步骤 | 证据 |
|---|---|
| 编译进二进制 | 修完 2 处 bionic 头冲突后 `ninja` 通过，`nm` 里 288 个 `vhost_user` 符号 |
| 设备上可用 | `-netdev vhost-user` 的报错从 `not compiled into this binary` 变成 `Failed to connect to '<sock>'`（说明走通了参数解析） |
| passt 侧就绪 | `./passt --vhost-user -f -q -s vu.sock --repair-path none` → socket 建立、可连 |
| 内存后端 | `-M virt,gic-version=3,memory-backend=mem` + `-object memory-backend-memfd,...,share=on` → 引擎记录 `henge: region mem pa=0x40000000 size=0x40000000 ram=1`，UEFI banner 正常出现 |

#### 卡点：`share=on` 内存 + virtio-blk 的 DMA 可见性

用 memfd 时 UEFI 能跑，但读不到 ARM64 引导项：

```
UEFI firmware (version edk2-stable202408-prebuilt.qemu.org ...)
Error: Image at 000BFDB6000 start failed: 00000001
...
Image type X64 can't be loaded on AARCH64 UEFI system.
```

**隔离实验证明这不是 vhost-user 的问题：**

| # | 内存 | 网络 | 磁盘 | 结果 |
|---|---|---|---|---|
| A | 匿名 | slirp | 无 | ✅ UEFI 正常（1365 行日志） |
| B | **memfd share=on** | slirp | 无 | ✅ UEFI 正常（794 行日志） |
| C | **memfd share=on** | slirp | **virtio-blk** | ❌ 11 行，`Image type X64` |
| D | **memfd share=on** | **vhost-user** | **virtio-blk** | ❌ 11 行，同上 |

**B 好、C 坏 → 变量是 virtio-blk 的 DMA，不是 vhost-user，也不是 memfd 本身。**

归因：`system/physmem.c:3864` 的 hook
```c
if (henge_enabled() &&
    hv_engine_dma_written_host(henge_accel_machine(), buffer, access_len))
```
靠 `pa = r->pa + (host - r->host)` 反查。匿名 RAM 下能匹配（A 组 virtio-blk 一直正常，
Debian 早就跑通了）；memfd 的 RAMBlock 下 `buffer` 与引擎记录的 `r->host` 对不上，
反查失败 → 引擎保留旧翻译 → UEFI 读到 FAT 目录的旧内容 → 误判成 X64 PE。

待验证的具体猜测：memfd 的 RAM 在 MemoryRegion 上可能带 alias/offset，
`memory_region_get_ram_ptr(mr) + offset_in_region` 与 `address_space_map()` 返回的
`buffer` 不是同一个基址。下一步应当在 hook 里打印两者，或改用
`qemu_ram_block_from_host()` 做反查（比自建表更权威）。

#### 顺带踩到的两个坑（都记在这里，省下次）

1. **`-machine` 会覆盖 `-M`**。写
   `-M virt,gic-version=3 ... -machine memory-backend=mem` 时后者完全替换前者，
   `gic-version=3` 被丢掉，QEMU 直接起不来（0 行日志）。必须合并成
   `-M virt,gic-version=3,memory-backend=mem`。
2. **`-mem-path` + `-mem-prealloc` 在 Android/Termux 上连启动都没有**（0 行日志），
   不能用它替代 memfd。

#### 结论：vhost-user 不是当前性能问题的必要解

- slirp 已达 6–8 MB/s，passt(stream) 在正确的地址参数下也是 6–8 MB/s（见 13.9 更正）。
- vhost-user 要生效必须先解决 memfd RAM 的 DMA 反查，这是**独立的新 bug**，
  不是"打开一个 configure 选项"就能拿到的收益。
- 在 DMA 反查修好之前，vhost-user 这条路**不可用**；不要在它上面继续堆时间。


### 13.12 反查 API 最终定论 + **判据教训（差点误判三小时）**

#### 用户指示：不要自造 `pa = r->pa + (host - r->host)`

对。第一版换成 QEMU 官方 `qemu_ram_block_from_host()`，然后**实测证明它单独也不够**：

```
DMAhost mr=mem addr1=0x7efcd298 rb->offset=0x0 rb_off=0x7efcd298 len=0x200
```

`rb->offset` 是 **0**，而这个 region 的真实 GPA 是 `0x40000000`。
原因：`-object memory-backend-memfd` 创建自己的 RAMBlock（offset=0），
`-machine memory-backend=mem` 再把 machine RAM 作为**别名**映射进地址空间。
所以既不能用 host 范围扫，也不能用 `rb->offset + rb_off`。

**权威答案是 `address_space_unmap()` 里已经算好的那一对**：
`memory_region_from_host()` 给出的 `mr` + MR 内偏移 `addr1`。
MR 的 GPA 基址在 mirror 时由 MemoryListener 报过，记下来按 MR 身份查即可。

```
DMAhit mr=mem off=0x7eb1d000 -> gpa=0xbeb1d000 n=0x1 (base=0x40000000)
```

**96 次命中、0 次 miss，GPA 全部正确。** 实现见
`accel/henge/henge-accel.c:hv_engine_dma_written_mr()` +
`HengeAccelState.ram_map[]`。旧的自建反查函数已整体删除，不留后路。

#### ★ 判据教训：`Image type X64` 不是失败标志

这一条代价最大，必须记下来。

我用「日志只有 11 行 + 含 `Image type X64 can't be loaded`」判定 memfd 实验失败，
连续误判了多轮。**而成功日志里同样有这句话**：

```
$ grep -c "Image type X64" def.log     # def.log 是成功的 6-8MB/s 那次
1
```

它在成功日志里的上下文是：

```
Image type X64 can't be loaded on AARCH64 UEFI system.
BdsDxe: loading Boot0001 "UEFI Misc Device" from PciRoot(0x0)/Pci(0x1,0x0)
...
Linux version ...
```

也就是说：**它只是 UEFI 扫描某个非 AArch64 OptionROM 时的正常消息**，
紧接着 BDS 就正常引导了。

正确的判据只有两个，缺一不可：

| 判据 | 含义 |
|---|---|
| `grep -c "Linux version"` > 0 | guest 内核真的起来了 |
| `grep -c "NET-END"` > 0 | 测试脚本跑完了 |

**绝不能用行数、"有没有某个错误字样"、或某个时间点的采样来判断成败。**
UEFI 阶段本身就要几十秒，60–120s 采样常常还停在 BDS 之前。

#### memfd + UEFI 仍然卡住（与 DMA 无关）

DMA 钩子修好之后（96/96 命中）memfd 仍然 `bds=0`、走不到 `Linux version`。
所以卡点不在 DMA 可见性上，而在 memfd RAM 与 pflash/romd 的交互，尚未定位。
**vhost-user 因此仍不可用**（它强制要求 shared memory）。

在定位之前，passt 只能走 `-netdev stream`（6–8 MB/s，已达标）。


### 13.13 活性缺陷定位：常用 sysreg 未内联 → seam 风暴（实测）

> 前两轮在同一位置过早落笔（memfd "henge 特有"、overlay "罪魁"）。本节结论
> 全部来自 Phase 0 建的自动仪器（schedstat / futex 符号化 / sidecar），
> 不再依赖一次性手工验尸。

#### 撤回首轮证据：`utime=0` 是我读错的字段

`/proc/<tid>/stat` 的 comm 是 `(CPU 0/Henge)`，**含空格**，
`awk '{print $14}'` 错位，实际读到的是 `cmajflt`。
**"vCPU utime=0" 这条证据作废。** 改用 `/proc/<tid>/schedstat`（三字段纯数字，免疫空格）。

#### 决定性格子：R1（cpu 0,1 / 无盘 / 无网 / b-old / 600s）

| 读数 | 值 |
|---|---|
| serial 行数 | 11（停在 `Image type X64` 之后） |
| BdsDxe | **0** |
| vCPU0 on-cpu | `20:12:27` 4.22s → `20:14:06` 4.27s → `20:17` 4.46s |
| 结论 | **99 秒只涨 0.05 秒 CPU ≈ 0.05% 占用** |

**这条把热降频排除了**：降频只能给 1.57 倍的慢化，给不出 0.05% 的占用。
也把磁盘/网络/memfd/DMA 全部排除（这一格什么都没有）。
cpu0,1 是 A55 簇（用户指出的"另一簇核"），6,7 是 A76 —— **两簇都卡**，
所以与核型无关。

#### 真正的指纹：sysreg seam 风暴

`-accel henge,trace=sysreg` 抓到的 stderr（255 行）分布：

```
152  MRS S3_0_C0_C0_* at 0x476a6068  -> CTR_EL0     ← 同一 PC，152 次
 69  MRS S3_0_C0_C0_* at 0xbfdc0b30  -> MPIDR_EL1
  9  MSR/MRS ...        at 0xbfd5dd8x -> CNTV_CTL_EL1
  2  ...                              -> ID_AA64MMFR0_EL1 / ID_AA64PFR0_EL1
```

配套现象（不带 trace 时）：stderr 被
```
henge: hv_run returned 10
```
刷屏。`10 = HENGE_EXIT_SYSREG_EXT`（`include/system/henge-engine.h:64`）。

**机理**：`CTR_EL0`、`MPIDR_EL1`、`CNTV_CTL_EL1` 这些**最常用的 sysreg
没有被引擎内联建模**，每次访问都要：
`hv_run 返回 10` → `bql_lock()` → `henge_service_external_exit()`
→ `get_arm_cp_reginfo()` 查表 → `henge_sync_irq()` → `bql_unlock()` → 重新进入

UEFI 启动后期的 cache 维护代码（`0x476a6068` 处的例程）**密集读 CTR_EL0**，
于是每个读都变成一次"陷入 + BQL + 主线程往返"。
158 次 CTR_EL0 读的量级下，活性被压到 0.05% —— 看起来像卡死，实际是在爬。

#### 为什么 TCG 通过而 henge 不通过

T1（TCG + memfd + cp 盘）到 GRUB + 内核全程正常。TCG 直接在自己的翻译块里
处理这些 sysreg，**没有 seam、没有 BQL 往返**。所以这不是 QEMU 或固件的问题，
是**henge 的 sysreg 覆盖度问题**。

#### 这也解释了 13.9-13.12 的混乱

之前那些"overlay 有毒"、"memfd 有 henge 特有 bug"的结论，全部是在这个
seam 风暴的底座上测出来的。UEFI 能不能在超时窗口内爬过 banner，
取决于当时读了多少次 CTR_EL0（受 cache 状态、盘有无、路径影响），
于是表现为"有时过有时不过"的 flaky 现象 —— 被误读成某个配置有毒。

#### 修复方向（下一步，尚未动代码）

引擎侧给高频 sysreg 加内联读：至少 `CTR_EL0`、`MPIDR_EL1`、`CNTV_CTL_EL1`、
`CNTV_CVAL_EL1`、`DAIF`、`CurrentEL`。判据用 R1 同一格：
`hv_run returned 10` 的条数应下降数量级，serial 应越过 BdsDxe。

#### 仪器（Phase 0 产出，已固化在设备 ~/）

| 脚本 | 作用 |
|---|---|
| `autopsy.sh` | schedstat 双采样 + futex uaddr 符号化 + State/ctxt_switches |
| `sidecar.sh` | 每 10s 记 freq/online/loadavg/RSS/serial 行数/线程 schedstat |
| `launch3.sh` | pidfile（绝不模式匹配）+ `-serial file:` + 五列日志头 + affinity 参数化 |
| `ms.sh` | 里程碑判据（UEFI→BdsDxe→Boot0001→Linux→NET-END） |

已知工具层坑（都写进脚本注释）：
- 清理循环 `*name*` 会匹配执行者自身 → 用 `*[n]ame*`，或只读 pidfile
- `-nographic` 的串口接 stdio，经管道被缓冲 → 用 `-serial file:`
- `setsid` 在 Termux 不可靠 → 用 `nohup`
- sidecar 只写 2 行就停（未定位，暂用手工采样兜底）


### 13.14 F0 三读数：seam 不是主体，gate 在等待侧

用户指出 13.13 的因果链算术不闭合，这是对的。摆出来：

- S1 窗口 120s，255 次 seam → 平均 0.47s 一次
- R1 后期：99s 内 on-cpu 只涨 0.05s → 每次醒来约 0.2ms 执行
- 255 × 10ms（宽算）= 2.6s，**不到 96s 的 3%**

所以 13.13 的"seam 风暴压低活性"**只是伴生现象，不是根因**。
以下三个读数把"96 秒的主人在哪"定下来了。

#### F0-1 exit 码分桶 —— 根本没有 WFI

```
$ grep -o 'hv_run returned [0-9]*' run-R1T.stderr.log | sort | uniq -c
    131 hv_run returned 10     ← HENGE_EXIT_SYSREG_EXT
      2 hv_run returned 11     ← HENGE_EXIT_PSCI_EXT
```

**没有 4（WFI）、没有 7（HALT）。** 这直接推翻了"vCPU 在 WFI park"的假设。
（注意：`hv_run returned` 只在 `trace=irq` 时打印，R1 默认 trace 下 stderr 是 0 行 ——
之前"刷屏"的印象来自被 trace 放大的 R1T，不是常态。）

#### F0-2 schedstat 增量 —— 是主动睡眠，不是等调度

```
schedstat: [on-cpu_ns, runqueue_wait_ns, slices]
S1 2887172081  9263463  132
S2 4442333319 93711164  918
Δ  +1.555s     +84.4ms  +786
```

- **786 slices / ~150s = 5.2 次/秒**
- 每次 on-cpu ≈ 2.0ms，**每次 runqueue wait 只有 0.11ms**

**runnable 就立刻上 CPU（wait 0.11ms），所以它不是在等调度。
schedstat 不统计主动睡眠时间 —— 这就是两个字段都小、却有 96 秒缺口的原因。**
是 `pthread_cond_timedwait` / futex 这类主动睡眠。

#### F0-3 futex 参数 —— 超时不是周期源

```
CPU 0/Henge  futex uaddr=0xb400... op=0x89 val=0x4 TIMEOUT=0x7c5919c958
CPU 1/Henge  futex uaddr=0xb400... op=0x89 val=0x6 TIMEOUT=0x0
b-old        ppoll nfds=14
```

`op=0x89 = FUTEX_WAIT_BITSET(9) | FUTEX_PRIVATE(0x80)`。

读那个 timespec（16 字节）：

```
107133 275022307   →  {tv_sec=107133, tv_nsec=275022307}
```

**约 29.8 小时。** 不是 0.19 秒的周期源，是"基本无限"的兜底。
CPU 1 干脆 `TIMEOUT=0`（无限）。

#### 三条合起来：vCPU 在 futex 上等 kick，每 192ms 醒一次

| 观测 | 含义 |
|---|---|
| exit 码无 4/7 | 不在引擎的 WFI 路径上 |
| futex 超时 30 小时 | 唤醒不是超时兜底 |
| 5.2 次/秒、每次 2ms | 有个东西每 ~192ms 踢它一次 |
| runqueue wait 0.11ms | 醒来立刻就跑，不是调度延迟 |

**所以 192ms 的唤醒源是某个 `kick`，不是 timer 超时。**
这一格把问题从"seam 太贵"转成"**谁在周期性 kick / 该 kick 的没 kick**"。

配套的源码线索（`engine/core/dispatch.c:523` `wait_for_interrupt`）：

```c
if (!m->tick) { wfi_count(cpu, 1); return -1; }   /* nothing could ever wake us */
```

以及 B 路径的注释（`dispatch.c:484`）：

> `B  there is no tick callback (henge never installs one), so "nothing can ever
> wake us" and the whole run exits to the host. The host then parks the thread
> on halt_cond`

而 `hv_engine_set_tick()` **确实被调用了**（`henge-accel.c:823`），
`henge_tick_delta24()` 读的是 **QEMU 的 `env->cp15.c14_timer`**。
guest 在引擎里跑，只有走过 seam 才会同步回 env —— 于是 timer 的到期时刻
可能永远不被引擎看见，WFI 就一直睡到 10ms 上限（`wait_ticks` cap 240000 @24MHz）。

这与"每 192ms 醒一次"仍不完全吻合（10ms 上限应该更频繁），
但方向明确：**要查的是 timer 到期 → IRQ 投递 → kick 这条链**，
而不是 sysreg 内联。

#### 下一步（F3，按用户的分支结构）

1. `-smp 1` 格：排除跨 CPU kick 干扰
2. gdbstub 读 `CNTV_CTL.ISTATUS` 与 GIC PPI pending：确认 timer 到期时 IRQ 有没有挂起
3. 主线程 `ppoll` 的 timeout 参数：看 host 侧是不是靠 192ms 的轮询兜底

#### 纪律修正（按用户要求）

- 13.13 的"sysreg 风暴是根因"**降级为"seam 是醒来的伴生开销"**。
  正文已按此改写表述：stall = 秒级等待循环 + seam 伴生，gate 待定。
- `CNTV_CTL/CNTV_CVAL` **不动**。理由记在这里：它们不是热点（9/255），
  且 ISTATUS 若内联返回 stale 0，guest 轮询等 1 就是永远等不到 ——
  把"慢"修成"死"，活性从 0.05% 变 0%。
- F1（CTR_EL0 / MPIDR_EL1 / CurrentEL 内联）仍值得做，但定位是**判别实验**：
  消掉 87% 的 seam 后若活性不变，就证明 gate 确实在等待侧。


### 13.15 更正：F0 第三个读数并未取得；三个异常的重判

#### 先认错

13.14 里我写"F0 三个读数都已取得"——**不成立**。
第三个读数（`wfi_hist`，`HV_WFI_COUNT=1`）两次尝试都没落地，
我在没有数的情况下写成了"已取得"。探针造好了但没读到数，这条作废。

#### 异常 1：零次 code 4 —— 打印点排除后，只剩两条出路

读 `henge-accel-ops.c:278-345` 确认：`hv_run returned %d` 的打印
**在 WFI 分支之后、对所有 r 都执行**，然后才 `break`。
所以"打印点不覆盖 code 4"这条出路**不成立**。

剩下的两条：

| 出路 | 含义 |
|---|---|
| **A 路径** | `wait_for_interrupt()` 开头 `if (p->irq_line \|\| p->fiq_line) { wfi_count(cpu,0); return 0; }` —— IRQ 已挂起时返回 0，引擎继续跑，**不产生任何 exit** |
| guest 从未 WFI | 那 vCPU 在哪个 wait 上 |

**A 路径成立的话，"henge never installs one" 那句注释就是过时的**：
`hv_engine_set_tick()` 确实被调用（`henge-accel.c:823`），
`m->tick` 不为 NULL，所以 WFI 走"睡 ≤10ms"的分支，醒来若 IRQ 已挂起就返回 0。
这条与"零次 code 4"完全自洽。

`wfi_hist` 的 `path_a / path_b / slept` 三个计数能一次裁决，**仍需在设备上跑**。

#### 异常 2：那个"30 小时"很可能是我读错了语义

`op=0x89 = FUTEX_WAIT_BITSET | FUTEX_PRIVATE`，`FUTEX_WAIT_BITSET` 的
timeout 是**绝对时刻**，不是相对时长。而 bionic 的 `pthread_cond_timedwait`
虽然 API 上是 CLOCK_REALTIME，内部转成 **CLOCK_MONOTONIC 绝对值**交给 futex。

于是 `{tv_sec=107133, tv_nsec=275022307}` 的正确解读是
"**单调时钟 107133.275 秒处的死线**"，而 107133 秒 ≈ 29.76 小时
**正好是设备的开机时长**——不是 30 小时的超时。

所以：**这不是 deadline 算术错误，是我的单位误读。**
但它反而把矛盾推得更尖锐：`wait_for_interrupt()` 的算术我已逐步核对——

```c
uint64_t wait_ticks = deadline && deadline > now ? deadline - now : 240000;
if (wait_ticks > 240000) wait_ticks = 240000;          /* 240000 @24MHz = 10ms */
struct timespec ts = {(time_t)(wait_ticks / 24000000),
                      (long)(wait_ticks % 24000000) * 1000 / 24};
```

240000 → `ts = {0, 10000000}` = 10ms，**换算正确，cap 不是死代码**。
可实测每 192ms 才醒一次。**10ms 的 cap 造不出 190ms 的间隙**——
说明 vCPU 要么不在 wake_cv 上，要么根本没被调度。

#### 引擎里的全部等待点（源码枚举）

| 位置 | 等待 | 有无超时 |
|---|---|---|
| `dispatch.c:90` | `pthread_cond_wait(&m->stw_cv)` | **无限** |
| `dispatch.c:562` | `pthread_cond_timedwait_relative_np(&p->wake_cv)` | ≤10ms |
| `dispatch.c:178/188/230/827` | `pthread_mutex_lock(&m->tr_mu)` | 无限 |
| `dispatch.c:559` | `pthread_mutex_lock(&p->wake_mu)` | 无限 |

实测 CPU1 是 `TIMEOUT=0`（无限）→ 只可能是 `stw_cv` 或某把 mutex；
CPU0 是定时等待 → 只可能是 `wake_cv`。
**CPU1 卡在 stw_cv 上而 CPU0 在 10ms 循环里，两者都不是 190ms。**

#### 新假设：线程根本没被调度（Android cgroup 冻结/限流）

如果线程被 `cgroup.freeze` 冻住，它**既不在 futex 上、也不在跑**，
`schedstat` 的 wait 字段同样不增长——正好对上"两个字段都小、却有 96 秒缺口"。

这一条还顺带解释了两件旧事：
- 同二进制同参数，def.log 通、C1 卡（冻结是按 app 状态变的）
- 设备越用越慢（后台 app 越多，cgroup 压力越大）

零成本判别脚本已写好：`work/probe/probe-freeze.sh`
（读 `/proc/PID/cgroup`、`cgroup.freeze`、`cpu.max`、`pressure/*`，
再做三次 slices 采样——冻结时该值应完全不动）。

#### 异常 3：源码里的频率契约其实是对的

逐步核对后发现 62.5/24 的失配**不会泄漏**：

```c
/* sysreg.c:27 */  #define CNTFRQ 24000000ull          /* 仅作 m->timer_freq 为空时的兜底 */
/* sysreg.c:186 */  *v = m->timer_freq ? m->timer_freq : CNTFRQ;   /* guest 读到 62.5MHz */
/* sysreg.c:30 */   counter() = mach_absolute_time()               /* 24MHz 域 */
/* sysreg.c:35 */   hv_guest_ticks() = muldiv(counter, timer_freq, 24e6)  /* 换算到 62.5MHz 域 */
```

`m->timer_freq` 来自 `ARM_CPU(cs)->gt_cntfrq_hz`（`-M virt` = 62.5 MHz），
而 `hv_guest_ticks()` **有换算**。所以 CNTVCT 在 guest 眼里确实按 62.5 MHz 走。

**整条链只有一个未验证假设：`mach_absolute_time()` 在这台设备上真的是 24 MHz。**
它一旦错，guest 的时间世界整体被稀释，而所有下层算术仍自洽——正是 19.2 的形态。

已加零风险自校准（`compat/plat_linux.c`，只打印不改行为）：

```
HV_CLOCK_CAL=1 → hv-clock: cntvct_el0 measured N Hz | cntfrq_el0 reports N Hz
                 | engine assumes 24000000 Hz | dilution=X.XXXXx
```

三种读数对应三种结论：
- measured ≈ cntfrq ≈ 24e6 → 24MHz 假设成立，19.2 另找原因
- measured ≈ cntfrq ≈ 19.2e6 → **稀释成立**，24MHz 硬编码是根因
- measured ≠ cntfrq → 内核报的频率不可信

#### 本轮未完成（设备离线）

OPPO（192.168.1.9）`No route to host`，vivo 在线但没有二进制。
以下全部待设备恢复，**按用户给的顺序**：

1. 磁盘旧文件榨干：`run-R1T.stderr.log` 的 `irq line` 计数（trace=irq 那次）
   —— 零次转换 = timer IRQ 从未投递；~5.2Hz 翻转 = 投递正常
2. `wfi2.sh` 抢救 wfi_hist（300s 窗口，不再用 launch3 的包装）
3. `probe-freeze.sh` 查 cgroup 冻结
4. `HV_CLOCK_CAL=1` 判 19.2
5. 以上都不解释时，才上 gdbstub


### 13.16 归因闭合：timer deadline 读错了源，每次 WFI 睡满 10ms

设备 IP 变成 192.168.1.7 后，五件事全部跑完。结论不在 13.15 列的三条假设内。

#### 读数 1（零成本，榨旧文件）：IRQ 从未投递

```
run-R1T.stderr.log (trace=irq):
  irq line       = 0     ← 整个窗口，IRQ 线路一次都没翻转
  WFI streak     = 0
  stderr 总行数  = 133   = 131×code10 + 2×code11
```

`henge_sync_irq()` 只在 `hard != last[i]` 时打印，`last[]` 初值 0。
**零次转换 = 从没出现过 IRQ 拉高。** 与"9 次 CNTV_CTL seam"合起来就是
"programmed but never delivered"。

#### 读数 2：时钟契约是对的（我上一版脚本算错了）

第一版自校准只测裸 `cntvct_el0`（13 MHz），却和 `HV_TICK_HZ=24e6` 相除，
打印出 `dilution=1.8481x`。**这是错的**——代码里 `to24_mult = 24e6<<32/13e6`，
换算本来就存在。改成同时测裸计数器和 `hv_host_ticks_24mhz()`：

```
hv-clock: raw_cntvct=13000339 Hz | cntfrq_el0=13000000 Hz |
          engine_domain=24000293 Hz (want 24000000) | ratio=1.0000
```

- 设备晶振 **13 MHz**（不是 24 MHz）
- 引擎时间域实测 **24.000293 MHz**，误差 1.2 ppm
- **ratio = 1.0000，频率契约正确**

**异常 3 的"稀释"假设作废。** 又是"机制描述冒充归因"的一次预演，
只在打印里活了几分钟就被自己的第二版脚本否掉。

#### 读数 3：wfi_hist —— 算术闭合在这里

```
HV_WFI_COUNT=1:
hv-wfi: cpu0  A(line-high)=10  B(no-tick)=0  slept=8192
```

- **B(no-tick)=0** → `m->tick` 不是 NULL，tick 确实装上了。
  `dispatch.c:484` 那句 "henge never installs one" 是**过时注释**。
- **slept=8192** → 真的在 `wake_cv` 上睡了 8192 次
- **8192 × 10ms = 81.9 秒**，实测 96 秒零进展 → **算术闭合**
- slept 路径必须 `return 0`（否则会产生 code 4，而实测 0 次）
  → WFI 完全在引擎内部消化，从不交给 QEMU

#### 读数 4：cgroup 冻结排除

```
09:02:02 on-cpu=12490.0ms slices=8772
09:02:07 on-cpu=12653.6ms slices=9792    ← 在动
09:02:12 on-cpu=12897.2ms slices=10327   ← 在动
```
slices 持续增长，未被冻结。13.15 的冻结假设**作废**。

#### 根因：deadline 的数据源错了

引擎**完全内联管理** generic timer（`sysreg.c:319/321`）：

```c
case R(3,3,14,3,0): cpu->cntv_cval = counter() - cpu->cntvoff + (int64_t)(int32_t)v; break;  /* CNTV_TVAL */
case R(3,3,14,3,2): cpu->cntv_cval = v; break;                                               /* CNTV_CVAL */
```

这些写入**不进 seam**（`access bit (k>>8)&1` 表示内联），所以 QEMU 侧
`env->cp15.c14_timer[GTIMER_VIRT].cval` **从头到尾是 0**。

而 WFI 算 deadline 时（`henge-cpu.c:551 henge_tick_delta24`）读的正是那份：

```c
uint64_t ctl = env->cp15.c14_timer[idx].ctl;   /* 0 */
uint64_t cval = env->cp15.c14_timer[idx].cval; /* 0 */
if (!(ctl & 1) || (ctl & 2)) continue;         /* ctl=0 → 直接跳过两个 timer */
...
if (!best) return 0;                            /* → 0 */
```

`engine_tick` 拿到 0 → `deadline = 0` → 
`wait_ticks = deadline && deadline > now ? ... : 240000` → 取 10ms 上限。

**于是每一次 WFI 都睡满 10ms，醒来 IRQ 没来，再 WFI。8192 次 = 82 秒。**

完整链条：

```
guest 写 CNTV_CVAL  → 引擎 cpu->cntv_cval（内联，QEMU 不知道）
guest WFI           → wait_for_interrupt
                    → engine_tick → henge_tick_delta24
                    → 读 QEMU env 的 cval = 0 / ctl = 0
                    → 两个 timer 都 continue → best=0 → return 0
                    → deadline=0 → wait_ticks=240000 = 10ms
                    → 睡 10ms → 醒 → 没 IRQ → 再 WFI
```

#### 为什么 TCG 通过

TCG 自己管 timer，只有一份状态，不存在"引擎有 cval、QEMU 不知情"。
这与 13.13 的观察一致：TCG 到 GRUB + 内核全程正常。

#### 这也解释了所有 flaky

slept 的次数取决于 guest 在这个窗口里执行了多少次 WFI（受 cache 状态、
固件路径影响），乘 10ms 后决定能否在超时窗口内爬完 banner。
同一二进制时通时卡，就是这条链的随机性——不是哪个配置有毒。

#### 修复方向（有明确判据）

让 WFI 的 deadline 从**引擎自己的 timer 状态**算，而不是 QEMU 的 env。
两种做法：

| 方案 | 做法 | 风险 |
|---|---|---|
| A | 引擎新增 `hv_engine_next_timer_delta24(HvCpu*)`，读 `cpu->cntv_cval/ctl` 算 delta | 低：只读状态，不动 guest-visible 语义 |
| B | 引擎在写 cval/ctl 时通过 seam 同步到 QEMU env | 中：多一条 seam，且要保证不重复触发 |

倾向 A。**注意这与"不要内联 CNTV_CTL/CNTV_CVAL"的禁令不冲突**：
那条禁的是让内联读返回 stale 的 ISTATUS（会把"慢"修成"死"）；
这里是让 WFI 的 deadline 数据源正确，不改变 guest 读到的任何值。

验收判据（同一格，b-old 或修复后的二进制）：
- `hv-wfi` 的 `slept` 应大幅下降（deadline 算得出来，不再睡满 10ms）
- `irq line` 应出现非零转换
- serial 应越过 `BdsDxe` 到 `Boot0001`

#### 本轮五件事的完成状态

| # | 事项 | 状态 |
|---|---|---|
| 1 | 榨干旧文件（irq line） | ✅ irq_line=0 |
| 2 | 抢救 wfi_hist | ✅ slept=8192, B=0 |
| 3 | 查 cgroup 冻结 | ✅ 排除 |
| 4 | 时钟自校准 | ✅ ratio=1.0000，假设作废 |
| 5 | gdbstub | 不需要了（根因已闭） |


### 13.17 外部调研：上游 Henge 的架构原点，以及它如何解释这个 bug

用户要求每次先查外部进展再动手。这次查到了本项目的身世，**它直接改变了修复方案**。

#### 上游关系

| 项目 | 作者 | 时间 | 关系 |
|---|---|---|---|
| **Leviidev/Henge** | Leviidev | 2026-11-02 起，0.1/0.2/0.3 | **本项目的引擎来源**（`accel/henge/engine/`） |
| **WindowsiOS** | Ammaar Reshi | 2026-11-11 | 花 2 小时把 Henge 适配到 Windows 11 ARM，跑在 iPhone Duo |
| **WindowsPixel** | — | — | 未找到对应的公开仓库；检索只命中 kdrag0n 的 Pixel 6 + KVM 实验与 limbo_tensor |

Henge 的 README 有一句决定性的话：

> **Own emulator** — iOS gives apps no hypervisor, so Henge runs the Mac's arm64 code
> through its own JIT, **with its own MMU and devices**. **It doesn't use QEMU** or
> Virtualization.framework.

**上游 Henge 是"引擎拥有全部设备"的完整实现**：没有 QEMU，所以 timer、GIC、
中断投递全在引擎里，只有一份状态，不可能分裂。

**而我们的移植把 engine 塞进了 QEMU 当加速器**，于是所有权被切开：
- GIC 归 QEMU（引擎只有 `p->irq_line` / `p->fiq_line` 两条电平线，
  `engine/core/` 下**没有任何 gic/irq/intc 文件**）
- timer 被**两边各存一份**

#### 引擎侧 timer 写路径（`engine/core/sysreg.c:317-325`）

```c
case R(3,3,14,3,0): cpu->cntv_cval = counter() - cpu->cntvoff + (int64_t)(int32_t)v; break;
case R(3,3,14,3,1): cpu->cntv_ctl = v & 3; break;
case R(3,3,14,3,2): cpu->cntv_cval = v; break;
default: goto other;
}
/* Timer outputs follow their registers at once, as in hardware: a masked
   timer must drop its line before the handler's EOI. */
if (m->tick) m->tick(m, cpu);
return 0;
```

**注意这三行是内联的（`access bit (k>>8)&1`），不走 seam。**

#### 缺失的那一半

`m->tick` 被调用后进入：

```
engine_tick(m, cpu)                      [henge-engine.c:712]
  → tick_delta24(opaque, cpu->index)     [henge-accel.c:823 注册为 henge_tick_delta24]
  → henge_tick_delta24()                 [henge-cpu.c:551]
      uint64_t ctl  = env->cp15.c14_timer[idx].ctl;    ← QEMU 的那份
      uint64_t cval = env->cp15.c14_timer[idx].cval;   ← 永远是 0
      if (!(ctl & 1) || (ctl & 2)) continue;           ← ctl=0，两个都跳过
      if (!best) return 0;
```

**也就是说：设计意图是"QEMU 的 timer 作真相源"，读侧接好了，
但引擎写完 `cpu->cntv_cval` 后从未同步给 QEMU —— 写侧缺失。**

后果链：

```
guest 写 CNTV_CVAL → 引擎 cpu->cntv_cval（QEMU 不知道）
                   → m->tick 立即被调 → 读 QEMU env → ctl=0/cval=0 → return 0
QEMU 的 generic timer 从未被 arm  → 永不到期 → 永无 qemu_irq_pulse
                                    → 永无 CPU_INTERRUPT_HARD
                                    → henge_sync_irq 无变化（irq line 转换 = 0，实测）
guest WFI → wait_for_interrupt → deadline = 0 → wait_ticks = 240000 = 10ms
          → 睡满 10ms → 醒 → irq_line 仍低 → 再 WFI  （slept=8192，实测）
```

**实测三个读数与这条链完全一致：`irq line` 转换 0 次、`slept=8192`、
8192×10ms ≈ 82s ≈ 96s 零进展。**

#### ★ 这否掉了 13.16 的方案 A

13.16 提的"让引擎自己算 deadline"**只是半个修复**：
即使 WFI 睡对了时长，醒来照样没有 IRQ（QEMU 的 timer 没 arm），
只是从"每 10ms 醒一次"变成"每 deadline 醒一次"的**空转**。

**必须补上写侧同步，让 QEMU 的 timer 真正 arm 起来。**

#### 正确方案（方案 C：补上写侧）

改动最小、且能同时修好"deadline 计算"和"中断投递"：

1. **target/arm 加导出函数**（`gt_recalc_timer` 是 static，accel 层碰不到）：
   ```c
   void arm_henge_set_vtimer(CPUState *cs, uint64_t ctl, uint64_t cval)
   {
       ARMCPU *cpu = ARM_CPU(cs);
       cpu->env.cp15.c14_timer[GTIMER_VIRT].ctl  = ctl & 3;
       cpu->env.cp15.c14_timer[GTIMER_VIRT].cval = cval;
       gt_recalc_timer(cpu, GTIMER_VIRT);
   }
   ```
2. **引擎暴露** `bool hv_engine_take_vtimer(HvCpu *cpu, uint64_t *ctl, uint64_t *cval)`
   —— 返回 `cpu->cntv_ctl/cntv_cval`，带 dirty 标记避免每次 WFI 都白同步。
3. **在 `henge_tick_delta24` 开头先同步再算**：
   ```c
   if (hv_engine_take_vtimer(hv_cpu_of(index), &ctl, &cval)) {
       arm_henge_set_vtimer(cs, ctl, cval);     /* 补上缺失的写侧 */
   }
   /* 然后走现有逻辑：此时 env 里是新鲜数据，delta 算得出来 */
   ```

   这一步同时做掉了两件事：
   - QEMU 的 timer 被 arm → 到期会 `qemu_irq_pulse` → GIC → `CPU_INTERRUPT_HARD`
     → `henge_sync_irq` 把它搬到 `p->irq_line` → 引擎投递异常 → **guest 收到中断**
   - `henge_tick_delta24` 立刻能算出正确的 delta → WFI 不再睡满 10ms

4. 时机天然正确：`m->tick` 在**每次 timer 寄存器写完时立即调用**，
   也在 `wait_for_interrupt` 开头调用，两处都需要新鲜数据。

#### 与"不内联 CNTV_CTL/CVAL"禁令的关系

**不冲突，反而更符合禁令的本意。**

那条禁的是：让内联路径返回 stale 的 ISTATUS 给 guest（会把"慢"修成"死"）。
本方案里：
- guest 读 CNTV_CTL 仍然走引擎内联（`sysreg.c:192` 用 `cpu->cntv_cval` 算 ISTATUS）
  —— **读语义一个字没改**
- 只是把引擎已知的值**额外**告诉 QEMU，让 QEMU 的 timer 设备能正常工作
- 不引入任何 guest-visible 的变化

#### 验收判据（三条，缺一不可）

| 判据 | 期望 |
|---|---|
| `hv-wfi` 的 `slept` | 从 8192 降到数量级更小（deadline 算得出来） |
| `irq line` 转换次数 | 从 0 变成非零（timer IRQ 真的投递了） |
| serial | 越过 `BdsDxe` 到 `Boot0001` → `Linux version` |

#### 调研习惯（用户要求，写死）

**每次动手改引擎前，先查上游 Henge / WindowsiOS / WindowsPixel 的最新进展。**
这次查完直接改变了修复方案（A → C），如果按 A 做，会得到"更频繁的空转"
而误判为"修复无效"。上游是纯 iOS 实现、设备全自有；我们是
engine + QEMU 的缝合体，所有权边界处就是 bug 的温床。


### 13.18 方案 C 实施：一半生效，一半没有

按 13.17 的方案 C 改了代码并实测。**修复有实质效果，但没闭合。**

#### 改动（四处，都在上游所有权边界上）

| 文件 | 改动 |
|---|---|
| `target/arm/internals.h` | 新增 `arm_henge_set_vtimer()` 声明 + 为什么需要它的长注释 |
| `target/arm/helper.c` | 实现：写 `env->cp15.c14_timer[GTIMER_VIRT]` 后调 `gt_recalc_timer()` |
| `engine/core/cpu.h` | `HvCpu` 加 `virt_timer_dirty` |
| `engine/core/sysreg.c` | 三个 CNTV 写路径置 dirty |
| `henge-engine.c` | `hv_engine_take_vtimer(m, index, &ctl, &cval)` |
| `henge-cpu.c` | `henge_tick_delta24()` 开头先 take + push 给 QEMU |

注意 `henge-engine.c` 编译在引擎静态库里、看不到 QEMU 头，
所以那个 TU 显式 `#include <stdbool.h>`（第一次编译就栽在这里）。

#### 实测：slept 增速降 400 倍

同一格（anon / 无盘 / 无网 / cpu0,1 / 只开 `HV_WFI_COUNT`），只换二进制：

| 读数 | 修复前 `b-old` | 修复后 `q-fix` |
|---|---|---|
| `slept` | 75s 时 **32768**（~437/s） | ~500s 时 **512**（~1/s） |
| `A(line-high)` | 30 | **0** |
| serial | 19 行（75s） | 11 行（500s） |

**`slept` 的增速降了约 400 倍**，这是 deadline 从"算不出来 → 10ms cap"
变成"算得出来 → 睡到真实到期"的直接证据。**写侧同步确实生效了。**

#### 但中断仍未投递

`A(line-high)=0` 意味着 WFI 时 IRQ 线路从未已挂起。链条：

```
arm_henge_set_vtimer() → gt_recalc_timer()
    → ISTATUS = (count - offset >= cval)
    → gt_update_irq(): irqstate = (ctl & 6) == 4   ← 需要 ISTATUS=1 且 IMASK=0
    → qemu_set_irq(cpu->gt_timer_outputs[GTIMER_VIRT], irqstate)
    → virt.c 里连到 GIC 的 PPI（machine init 时建立，与 accel 无关）
```

已确认 `gt_update_irq` **没有 TCG 依赖**（`helper.c:1376`，直接 `qemu_set_irq`），
所以这条链理论上是通的。剩下的可能：

1. **guest 从未写 CNTV_CVAL/CVAL**，`virt_timer_dirty` 一直是 0 → 什么也没发生
2. 写了，但 `cval` 远在未来 → 从未到期
3. 到期了，PPI 拉起，但 GIC 侧没使能该 PPI（GICR_ISENABLER0 bit 27）
4. `arm_henge_set_vtimer` 在错误的时机被调用（BQL / 线程上下文）

#### 下一步：四个探针，一次性分辨

不应再猜。加计数器打出来：

| 探针 | 位置 | 分辨什么 |
|---|---|---|
| `take` 返回 true 的次数 | `henge_tick_delta24` | 1 vs 2 |
| `gt_recalc_timer` 被调次数 | `arm_henge_set_vtimer` | 是否真进到 QEMU |
| `gt_update_irq` 的 `irqstate` | `gt_update_irq` | 3（ISTATUS） |
| `timer_mod` 的目标 ns | `gt_recalc_timer` | 2（cval 在未来多远） |

#### 诚实的当前状态

| 判据 | 结果 |
|---|---|
| `slept` 大降 | ✅ 32768 → 512（增速降 400 倍） |
| `irq line` 非零 | ❌ 未验证（本次未开 trace）+ `A=0` 提示仍为 0 |
| serial 越过 BdsDxe | ❌ 停在 11 行 |

**方案 C 的前提（写侧缺失）是对的，改动也确实改变了行为；但"补上写侧 → timer 到期 → PPI → 中断"这条链还缺一环。**
不要因为 slept 降了就宣布修好——那只是三个判据里的第一个。


### 13.19 mvisor 对照：三种 timer/中断归属，只有我们是分裂的

用户要求：保存进度，并列出 WindowsPixel 相对 mvisor 缺哪些组件。
先说结论：**一大半不是"缺"，是"不适用"** —— mvisor 是 x86/KVM 的 QEMU 替代品，
WindowsPixel 是 ARM64/Android 的模拟器。但对照暴露了一个比"缺组件"严重得多的问题。

#### ★ 三种架构的所有权归属（本节最有价值的一张表）

| 项目 | guest timer 归谁 | 中断控制器归谁 | 一致性 | 结果 |
|---|---|---|---|---|
| **mvisor** | KVM（PIT/LAPIC 在内核） | KVM（`kvm_irqchip`） | ✅ 同侧 | 稳定 |
| **WindowsPixel** | 引擎（`devices/timer.c`） | 引擎（`devices/gicv3.c`） | ✅ 同侧 | 稳定 |
| **我们的 henge+QEMU** | **引擎**（`sysreg.c` 内联） | **QEMU**（GIC） | ❌ **分裂** | timer 永不 arm |

mvisor 的 `devices/kvm/kvm_irqchip.cc` **只有 121 行，全是 save/load/reset**，
它**完全不模拟中断控制器**：PIC/SLAVE/IOAPIC 三份状态全靠
`KVM_GET_IRQCHIP`/`KVM_SET_IRQCHIP` 存取，迁移时才需要读出来。

这证明：**"宿主拥有中断控制器"本身不是问题** —— mvisor 也这样。
问题是 **timer 在另一侧**。

我们是唯一把两者放在不同侧的架构，所以只有我们会遇到
"timer 编程了但中断控制器永远不知道"这种 bug。

**这是 13.18 方案 C 只修一半的结构性原因**：补上写侧让 deadline 对了（slept 降 400 倍），
但 PPI 的最终拉起仍要穿过 QEMU 的 GIC，而那条链上还有一环没接。

对应到用户给的两个上游：WindowsPixel 的 `timer.c` 之所以只要 20 行，
是因为它旁边就有 `gicv3.c`，`hv_gicv3_set_ppi()` 直接改 `p->irq_line`。

#### A. 架构不适用（x86 专属，ARM 上不存在或已由 QEMU virt 提供）

| mvisor 组件 | 文件数 | 为什么 ARM 上不适用 |
|---|---|---|
| `devices/chipset/`（440FX/Q35/ICH9-LPC/PIIX3/PIIX4/SMBus/PMIO） | 11 | x86 芯片组 |
| `devices/superio/`（PS/2、CMOS RTC、i82078 软驱、i8257 DMA、debug_console、pvpanic） | 21 | x86 遗留设备 |
| `devices/display/vga` + `qxl` | 57（含子目录） | x86 PC 显示；ARM 用 ramfb（WindowsPixel 有） |
| `devices/ahci/`（AHCI/IDE/ATA） | 26 | WindowsPixel 用 NVMe 1.4 + virtio-blk |
| `devices/pci/i440fx_host` + `q35_host` | 6 | x86 host bridge；ARM 用 `pcie.c`（GPEX ECAM） |
| `devices/kvm/`（kvm_clock、kvm_irqchip） | 3 | 无 KVM（Android 非 root） |
| `devices/vfio/` | 3 | 无 VFIO |
| `devices/usb/uhci`（USB 1.0） | 21（含全部 usb） | xHCI 已覆盖 |
| `devices/audio/ac97` | 10（含全部） | 遗留；HDA / virtio-snd 覆盖 |
| `include/hyperv/`（cpuid.h、hypercall.h） | 3 | x86 Hyper-V enlightenments（CPUID 0x40000000） |

#### B. 真的缺、可移植、且有实际价值

| mvisor 组件 | 文件数 | WindowsPixel 状态 | 价值 |
|---|---|---|---|
| **`migration/`**（file/network reader+writer、稀疏文件、live） | 5 | 无 | 我们也不行：Henge 明说 JIT cache/TLB 是 host pointer 不可迁移 |
| **`images/` + qcow2**（DiskImage 抽象、raw/qcow2、zlib/zstd、LRU cache） | 5 + 2 头 | 只有 raw + `hvsparse`（稀疏） | 无 backing chain / 快照 / 压缩。**我们反而有**（QEMU 提供） |
| **virtio-console** | — | 无 | guest agent / 日志通道 |
| **virtio-fs（+ fuse 后端）** | — | 有 `host/share`（机制未确认） | 共享文件夹 |
| **guest agents**（qemu_guest_agent / spice_agent / webdav_agent） | 6 | 有 webdav（commit 提到），其余未见 | 关机/文件/查询 |
| **`devices/firmware/smbios.cc`** | 16（含全部） | acpi.c 里可能含，待确认 | Windows 依赖 SMBIOS |
| **`utilities/zstd`** | 5 | 无 | 压缩 |
| **`lru_cache`** | — | 无 | 块缓存（qcow2 依赖） |
| **`include/spice/`**（ipc_ring、vd_agent） | 8 | 无 | SPICE 协议；手机用不到 |
| **protobuf + yaml 配置系统**（每设备一个 `.proto`，`config/*.yaml`） | 3 yaml + 多个 proto | 硬编码 + CMake | 工程性；也是 WindowsPixel 能跑在手机上的原因（轻） |

#### C. 功能等价、不算缺

| mvisor | WindowsPixel | 说明 |
|---|---|---|
| `networks/uip/`（自研 ipv4/icmp/tcp/udp/dhcp，25 文件） | `third_party/` 里 vendored libslirp v4.8.0 | 功能等价 |
| `gui/`（VNC / SDL / GTK） | `devices/fb_android.c` + `fb_display.c` + `fb_metal.m` | 都直接画到平台 surface |
| `devices/superio/uart.cc` | `devices/pl011.c` | 串口 |
| `devices/superio/cmos.cc`（RTC） | `devices/pl031.c` | RTC |
| `devices/agents/serial_port.cc` | `devices/pl011.c` | 串口代理 |

#### D. WindowsPixel 独有、mvisor 没有的

ARM64/移动端特有的这些，mvisor 作为 x86 项目根本没有：

- `core/`：ARM64→ARM64 JIT、4KB stage-1 MMU、**24 MHz counter scaling**、ASID HvTlbStash、LSE/LRCPC2
- `devices/gicv3.c`（GICv3 + ITS）、`devices/timer.c`（generic timer）、`devices/pflash.c`、`devices/pcie.c`（GPEX）
- `host/`：`enter.S` 入口汇编、memfd JIT、libslirp NAT、audio_android
- `android/`：Jetpack Compose app + VmForegroundService + JNI

**注意 `core/` 里那句 "24 MHz counter scaling"** —— 和 Henge 的
`CNTFRQ 24000000ull /* 24 MHz on Apple silicon */` 是同一个来源。
我们已经测过这台设备是 13 MHz，靠 `to24_mult` 换算，`ratio=1.0000`，
所以频率契约没问题（13.16）。**但 WindowsPixel 也带着 Apple 的 24 MHz 假设**，
说明这个常数在整条血缘里都是硬编码的，换设备时是同一个雷。

#### 一句话

**"WindowsPixel 缺 mvisor 的什么" 不是重点** —— 它缺的（migration、qcow2、
console、agents）大多是 x86 桌面虚拟化的需求，手机上用不到；
它把有限的工程量投在了 ARM64 特有的 JIT/MMU/GIC/timer 上，这个取舍是对的。

**真正的收获是那张所有权表**：mvisor 和 WindowsPixel 各自内部一致，
只有我们分裂。要收敛，两条路：
- **路 A**：把 GIC 搬进引擎（对齐 WindowsPixel），工作量 ≈ 一个 GICv3
- **路 B**：把 timer 全部交给 QEMU（对齐 mvisor 的"都在宿主"），
  引擎不做内联 timer，代价是每次 timer 访问走 seam

既然我们已经在这条 seam 上修了一半（slept 降 400 倍），**路 B 的剩余工作量更小**，
而且和现有代码同向。路 A 是彻底方案但要重写中断投递。


### 13.20 通过率实验：UEFI 根本不需要 timer 也能过 BDS

用户指出两条程序性问题成立：验收三条只落了一条就谈架构；slept 降 400 倍有两种读法。
补数据后，得到的结论**比"链路是否通"更根本**。

#### 先说最重要的：b-old（未修复）能过 BDS，而且进了 Shell

`run-wf.serial.log`（昨天 09:00，b-old，300s）：

```
BdsDxe: loading Boot0001 "EFI Internal Shell" from Fv(64074AFE-340A-4BE6-94BA-91B5B4D0F71E)/...
BdsDxe: starting Boot0001 "EFI Internal Shell" from Fv(64074AFE-340A-4BE6-94BA-91B5B4D0F71E)/...
UEFI Interactive Shell v2.2
EDK II
UEFI v2.70 (EDK II, 0x00010000)
Mapping table
map: No mapping found.
Press ESC in 5 seconds to skip startup.nsh ... Shell>
```

**未修复、timer 从未 arm、`irq line` 转换 0 次的二进制，走完了整个 BDS 并进了 UEFI Shell。**

这直接推翻 13.16 的模型："UEFI 缺 timer IRQ 所以卡在 BdsDxe 前"不成立。
UEFI 靠 10ms 兜底在爬，82 秒的开销在 240-300 秒窗口里是**能爬过去的**。

#### 交替重复实验（探针全关，n=9）

| 轮 | 时间 | 二进制 | serial 行 | BdsDxe |
|---|---|---|---|---|
| wf | 昨 09:00 | b-old | **20** | **2 ✅ Shell** |
| r1 | 今 10:18 | b-old | **20** | **2 ✅ Shell** |
| b1 | 今 10:45 | b-old | 4 | 0 |
| b2 | 今 10:52 | b-old | 4 | 0 |
| q1 | 今 10:30 | q-fix | 12 | 0 |
| q2 | 今 11:02 | q-fix | 4 | 0 |
| fx | 今 09:35 | q-fix | 12 | 0 |
| fm | 今 09:40 | q-fix | 12 | 0 |
| f1 | 今 11:30 | q-fix2 | 4 | 0 |

三个清楚的停点：

| 行数 | 最后一行 | 含义 |
|---|---|---|
| **4** | `Error: Image at 000BFB65000 start failed: Aborted` | 更早 |
| **12** | `Image type X64 can't be loaded...` + `3h3h` | 中 |
| **20** | `Shell>` | **通过** |

**同一 md5、同一参数、同一组核（cpu0,1 满频），在 4/12/20 三档之间跳。**
b-old 2/4 通过，q-fix 0/4，q-fix2 0/1 —— 样本不足以判定差异，更不足以宣布修复有效。

#### ★ 我在第一版修复里引入了一个锁 bug（已修正）

`henge_tick_delta24()` 从 `hv_run()` 内部被调用，而 vCPU 线程在
`henge-accel-ops.c:276` 的 `bql_unlock()` **之后**才进 `hv_run`。
第一版把它写成"读引擎 + 立即 push 给 QEMU"，于是
`gt_recalc_timer()` 在**没有 BQL** 的情况下操作了 `QEMUTimer` 和 GIC 的 irq 线。

**这是违反 QEMU 锁顺序的**，很可能就是"修了反而更差"的原因。

修正为两段式：

| 位置 | 动作 | 锁 |
|---|---|---|
| `henge_tick_delta24()`（`hv_run` 内） | `hv_engine_peek_vtimer()` 读引擎寄存器，自己算 delta | ✅ 无锁需求 |
| `henge_push_vtimer()`（`bql_lock()` 之后） | `hv_engine_take_vtimer()` + `arm_henge_set_vtimer()` | ✅ 持 BQL |

`peek` 是新增的只读版本，不清 dirty；`take` 才清。这样：
- WFI 的 deadline 立刻正确（读到引擎真实 cval）→ slept 降 400 倍的解释成立
- QEMU 的 timer 在 seam 边界被 arm（持 BQL）→ 不违反锁顺序

#### 这一轮真正学到的东西

| 旧模型 | 新事实 |
|---|---|
| UEFI 缺 timer IRQ → 必然卡在 BDS 前 | **错**。b-old 能进 Shell，50% 通过率 |
| slept 降 400 倍 → 链路已通 | **不成立**。它只说明 deadline 算对了；而且第一版还有锁 bug |
| 卡住是确定性的 | **错**。4/12/20 三档随机，同参数同 md5 |

**所以"BdsDxe 卡住"与 timer 无关。** timer mirror 修的是一个真实的性能问题
（每次 WFI 睡满 10ms），但它不是"有时过有时不过"的原因。

"有时过有时不过 + 停在三档不同位置"是**竞态**的形状，与用户早前提出的
"丢唤醒（park/kick 竞态）"假设吻合：唤醒时机不同 → 推进速度不同 → 停在不同位置。

#### 执行序调整（按用户的分支结构）

现在是"不通"，且**根因不在 timer**。所以：

1. **timer 项关闭**（保留已修的两段式 mirror，锁正确；它解决的是性能不是活性）
2. **立即回 P0-a / P0-b**（SIGSEGV 级，挂了好几轮）
3. 卡住的竞态留给 sidecar 长期观测，不再烧单轮实验
4. 24 MHz 运行时化（`to24_mult` 里的 13e6 也是硬编码，vivo 是 19.2MHz 会踩中）

#### 工具层新增（本轮踩到的）

| 坑 | 现象 | 解法 |
|---|---|---|
| Termux `sleep` 不准确 | `sleep 240` 跑 400s 未返回 | 不用脚本内 sleep 控节奏，改"启动即返回"+ 本地控时 |
| 清理循环自杀（第二次） | `*abtest*` 匹配到自己的 argv | **只读 pidfile**，永不按名字匹配 |
| 设备无 gdb | P3 的 gdbstub 路线不可用 | 需要代码内打印 GICR_ISENABLER0，或用 -monitor unix: |

#### 进度入库

`git init` 完成，13M，只追踪文档 + 脚本 + 改过的源码文件，已首个 commit。
