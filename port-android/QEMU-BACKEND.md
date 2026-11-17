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


### 13.21 仓库结构：submodule + 移植层补丁

用户指出第一版的 git 用法有结构性问题：把 qemu 的源文件逐个 add 进主仓库。
那会丢三样东西 —— 上游关系、改动可见性、改动行数。

#### 现在的结构

```
qemu-acce/
├── .gitmodules                      # 四个上游，各自钉在 commit 上
├── src/                             # 全部是 gitlink（160000），内容不入库
│   ├── qemu-mainline   → gitlab.com/qemu-project/qemu     v11.1.3 / 005c61c0ef
│   ├── mvisor          → github.com/tenclass/mvisor       8f9f37d
│   ├── WindowsiOS      → github.com/ammaarreshi/WindowsiOS 0071d69  ← 引擎来源
│   └── WindowsPixel    → github.com/weidu-tpvision/WindowsPixel c2b39e5
├── port-android/
│   ├── patches/
│   │   ├── 0001-henge-port.patch    # 移植层：55 文件 / 14223 行 / 653 KB
│   │   ├── apply.sh                 # 带基线校验、--check、--revert
│   │   └── README.md
│   └── *.md                         # 全部实测记录
└── work/probe/*.sh                  # 仪器
```

`git submodule status` 一眼可读：

```
 c2b39e5 src/WindowsPixel (heads/main)
 0071d69 src/WindowsiOS (heads/main)
 8f9f37d src/mvisor (heads/master)
 005c61c0ef src/qemu-mainline (v11.1.3)
```

#### 为什么移植层是 patch 而不是提交进 submodule

| | 提交进 submodule | patch（当前） |
|---|---|---|
| 上游关系 | 变成 fork，看不出基线 | submodule 钉在 v11.1.3 |
| 改动可见 | 埋在 70 万行上游历史里 | `git apply --stat` 一眼看完 |
| 换 qemu 版本 | rebase 一堆 commit | `git apply --3way` |
| 主仓库 log | 混入上游提交 | 只有我们的决定 |
| 改动计数 | 看不出 | **14223 行**是硬数字 |

#### 补丁内容（55 个文件）

| 部分 | 数 | 内容 |
|---|---|---|
| 改上游 | 13 | `accel/Kconfig`、`accel/meson.build`、`hw/arm/virt.c`、`meson.build`、`meson_options.txt`、`scripts/meson-buildoptions.sh`、`subprojects/libvhost-user/*`、`system/physmem.c`、`target/arm/{cpu-max.c,cpu.c,helper.c,internals.h}`、`util/oslib-posix.c` |
| 新加速器 | 40 | `accel/henge/**`（QEMU 侧 half + vendored 引擎，含 `local-edits.patch`） |
| 新头文件 | 2 | `include/system/henge-{accel,engine}.h` |

#### 验证：在干净树上真的能 apply

```
$ git worktree add --detach /tmp/qemu-clean-verify v11.1.3
$ cd /tmp/qemu-clean-verify && git apply 0001-henge-port.patch
rc=0
accel/henge 文件数: 39    ✓
两个头文件:        2     ✓
关键内容: arm_henge_set_vtimer / henge_push_vtimer / hv_engine_peek_vtimer 全在 ✓
构建接线: config HENGE / subdir('henge') / option('henge') / virt.c 全在 ✓
```

#### 顺带踢掉的

`port-android/initramfs-alpine/` 686 个文件 / 20M（解包的 Alpine rootfs，含 `.so`）
—— 由脚本重建，不该入库。主仓库追踪文件数 **792 → 114**。

#### 基线钉死的理由

`apply.sh` 校验 qemu HEAD 必须是 `005c61c0ef`（v11.1.3）。
13.1–13.20 的全部测量都是对着这个版本取的，`gt_recalc_timer` /
`gt_update_irq` 的位置和语义都可能随版本变，而移植层的接线都建在它们上面。
悄悄跟 upstream 走 = 拿没校准的底座测数据。


### 13.22 ★ 重大纠正：我的修复从未生效；QEMU 的 timer 其实一直在 arm

用户指出 13.20 的三个问题（abtest 是单调恶化序列、timer 项关早了、flaky 基线上不能转 P0），
并给出双轨假设。顺着 D2 源码核查，发现了比"双轨"更严重的事实：

#### 一、`sysreg_external` 恒为 1，内联路径是死代码

`henge-accel.c:860`，accel init 时**无条件**调用：

```c
hv_engine_set_external(h->m, 1, 1);
```

于是 `write_reg()`（`engine/core/sysreg.c:234`）第一句就拦下：

```c
static int write_reg(HvCpu *cpu, uint32_t reg, uint64_t v) {
    HvMachine *m = cpu->m;
    if (m->sysreg_external && (is_id_group(reg) || is_timer_ctl(reg)))
        return HV_SYSREG_EXTERNAL;      /* ← CNTV_* 全部走这里 */
    switch (reg) {
    ...
    case R(3,3,14,3,2): cpu->cntv_cval = v; cpu->virt_timer_dirty = 1; break;   /* 死代码 */
```

`is_timer_ctl()` 覆盖 `crm == 2 || crm == 3`，即 **CNTP_* 和 CNTV_* 全部**。

**结论：`sysreg.c:319-322` 那几行内联写永远不可达。**
我加的 `virt_timer_dirty = 1` 永远不会执行 →
`hv_engine_take_vtimer()` / `hv_engine_peek_vtimer()` **永远返回 false** →
**13.18 和 13.20 的整个修复从未生效。**

#### 二、slept 32768→512 是混淆变量

既然修复没有执行路径，slept 的变化必然来自别处：
guest 走了不同路径（4/12/20 三档）、环境漂移、窗口长度不同。
**13.18 里"写侧同步生效"的结论作废。**

#### 三、QEMU 的 timer 一直在 arm —— 我早前的诊断是错的

seam 路径**真的调用 writefn**：

```c
henge_cpreg_write(env, ri, value)         /* henge-cpu.c:330 */
  → ri->writefn(env, ri, value)           /* 走 QEMU 的 writefn */
  → gt_virt_cval_write → gt_cval_write
  → gt_recalc_timer(cpu, GTIMER_VIRT)     /* 无条件 */
```

**所以 `env->cp15.c14_timer[]` 从来不是 0。** 13.16 那句
"QEMU 侧 cval 恒为 0，timer 从未 arm" 是**错的**。

#### 四、QEMU 自带的 trace 给出了硬数据（零代码改动）

发现 build 里编了 trace 点，backend 是 `simple`，输出到 stderr：

```
-trace enable=arm_gt_recalc -trace enable=arm_gt_update_irq
```

12 行档的一次 run（60s）：

```
arm_gt_recalc     gt recalc: timer 1 next tick 0xa5b35394     ← timer 1 = GTIMER_VIRT
arm_gt_update_irq gt_update_irq: timer 1 irqstate 0   ×4
```

- **timer 确实被 arm**：`next tick = 0xa5b35394 = 2779703700`
- 2779703700 / 62.5e6 = **44.5 秒**
- 整个窗口 `irqstate` **恒为 0**，且**只有 1 次 recalc**（没有第二次 = 从未 fire）

4 行档的一次 run（190s）：trace **一行都没有**，serial 停在 4 行
→ **guest 还没编程 timer 就卡住了**，是完全不同的故障模式。

#### 五、现在真正的问题变成了三个

| # | 问题 | 证据 |
|---|---|---|
| **A** | 12 行档：timer arm 到 44.5 秒，但 190 秒内从未 fire | 1 次 recalc、irqstate 恒 0 |
| **B** | 4 行档：guest 根本没走到 timer 编程 | trace 全空、serial=4 |
| **C** | 44.5 秒是否合理 | UEFI BDS 超时是 3–5 秒量级 |

**A 的可能机制**（用户早前指出的频率域，现在有硬数据支撑）：
`gt_get_countervalue()` 用 `qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL)`，
而引擎的 `counter()` 是 `mach_absolute_time()`（host 时钟）。
`henge_timer_calibrate()` 只在 setup/resume 时对齐一次（算 epoch）。
**如果 virtual clock 与 host clock 速率不同（VM 停过就漂），deadline 就系统性错位。**
44.5 秒 vs 期望的 3–5 秒，差 10 倍量级，与这种漂移一致。

#### 六、用户的双轨假设：机制确认了一半

用户假设"CNTV 有的写进 QEMU、有的只进引擎"。实际机制是：
**不是同一个 encoding 有两条路，而是 `sysreg_external` 这个全局开关决定了走哪条 —— 而它恒为 1，所以全部走 seam。**

所以"双轨"在 4/12/20 的 flaky 上不成立（它不可能时而 seam 时而内联）。
flaky 的来源是别的：4 行档和 12 行档是**两种不同的故障**，
不是同一个故障的两种时机。

#### 七、这一轮的方法论收获

1. **先查符号可达性，再谈修复。** 我加的代码在死路径上，三轮实验全部无效。
   判据：`grep` 写路径的前置 `if` 条件，而不是只看 `switch` 里的 case。
2. **QEMU 自带 trace 是最便宜的探针**（零代码改动、已有 trace 点、`-trace enable=`）。
   前面花了多轮加自定义打印，其实 `arm_gt_recalc` / `arm_gt_update_irq` 一直都在。
3. **slept 这类计数不能跨 run 比较** —— 它依赖 guest 执行路径，不是纯性能指标。

#### 八、下一步（顺序已修正）

| # | 内容 | 依据 |
|---|---|---|
| 1 | 撤掉无效的 13.18/13.20 改动（peek/take/push/dirty），保留干净的 v11.1.3 + 原有 seam | 死代码无价值，且 push 有 BQL 风险 |
| 2 | 用 `-trace enable=arm_gt_*` 跑 12 行档 + 190 秒，确认 timer 是否 fire | A |
| 3 | 若 fire 但 irqstate 仍 0 → 查 GIC PPI 27 使能（`GICR_ISENABLER0`） | A |
| 4 | 若永不 fire → 查 virtual clock 与 host clock 的速率差（epoch 漂移） | C |
| 5 | 4 行档单独查（`StartImage → Aborted`），与 timer 无关 | B |


### 13.23 KVM 后端 vs henge 后端：一个"不需要问"、一个"必须问"

用户要求对比 QEMU 的 KVM 加速后端与我们的 henge 后端在**与 QEMU 衔接方式**上的差别。
查完源码，结论可以用一行代码的差别概括：

```
accel/kvm/*.c + target/arm/kvm.c:   grep -c "wait_ticks|sleep_us|cond_timedwait|nanosleep" = 0
accel/henge/engine/core/dispatch.c: wait_for_interrupt() 里有全部四个
```

#### 一、KVM：WFI 在内核里，QEMU 完全不知道

`include/system/kvm.h:83` 的原文：

> `kvm_halt_in_kernel` — Returns: true if halted cpus should still get a
> `KVM_RUN` ioctl to run inside of kernel space.

`target/arm/kvm.c:605`：

```c
/* For ARM interrupt delivery is always asynchronous,
 * whether we are using an in-kernel VGIC or not. */
kvm_async_interrupts_allowed = true;

/* PSCI wakes up secondary cores, so we always need to
 * have vCPUs waiting in kernel space */
kvm_halt_in_kernel_allowed = true;
```

于是 KVM 的 vCPU 线程（`kvm-accel-ops.c:31`）简单到只有：

```c
do {
    qemu_process_cpu_events(cpu);
    if (cpu_can_run(cpu)) {
        r = kvm_cpu_exec(cpu);          /* 一次 KVM_RUN ioctl */
        if (r == EXCP_DEBUG) cpu_handle_guest_debug(cpu);
    }
} while (!cpu->unplug || cpu_can_run(cpu));
```

**guest 执行 WFI 时：**
- ARM 的 KVM 里**没有 `KVM_EXIT_HLT` 处理**（只有 `target/i386/kvm.c` 和
  `target/ppc/kvm.c` 有），因为 WFI 根本不让 QEMU 看到
- vCPU 线程阻塞在 `KVM_RUN` 里，**内核负责睡、内核负责醒**
- 内核同时拥有 timer（vtimer）和中断控制器（VGIC），所以它自己知道何时该醒

**关键：QEMU 侧完全不存在"WFI 要睡多久"这个问题。**
`gt_timer` 依然在 QEMU 里 arg（guest 写 CNTV_CVAL 仍走 cpreg），
但那只用于 QEMU 自己的虚拟时钟推进，与 vCPU 的 park 无关。

#### 二、henge：WFI 在用户态，引擎必须问 QEMU "睡多久"

我们的结构：

```
henge_vcpu_thread_fn（henge-accel-ops.c）:
    bql_unlock();
    r = hv_run(cpu);            ← 一次函数调用，在用户态跑 JIT
    ...
    bql_lock();
```

`hv_run` 内部遇到 WFI 时（`engine/core/dispatch.c:1176`）：

```c
case HV_EXIT_WFI:
    if (wait_for_interrupt(cpu) != 0) return HV_EXIT_WFI;
```

`wait_for_interrupt()`（同文件 523 行）必须自己决定睡多久：

```c
uint64_t deadline = m->tick ? m->tick(m, cpu) : 0;      /* ← 问 QEMU */
...
uint64_t wait_ticks = deadline && deadline > now ? deadline - now : 240000;
if (wait_ticks > 240000) wait_ticks = 240000;           /* 10ms 兜底 */
hv_big_unlock(m);
park(cpu);
pthread_cond_timedwait_relative_np(&p->wake_cv, &p->wake_mu, &ts);
```

`m->tick` 注册的是 `henge_tick_delta24()`（`henge-cpu.c:551`），它读
**QEMU 的 `env->cp15.c14_timer[]`**，换算成 24MHz 域的 tick 数返回。

**所以 henge 必须回答一个 KVM 从来不需要回答的问题：
"引擎的 24MHz 时钟域" 与 "QEMU 的 virtual clock 域" 怎么换算。**

#### 三、四条结构性差异

| 维度 | KVM | henge | 后果 |
|---|---|---|---|
| **执行体** | 内核（KVM_RUN） | 用户态 JIT（hv_run） | henge 每次退出都要自己决定下一步 |
| **WFI** | 内核处理，QEMU 不知情 | 引擎 park 在 condvar | **henge 必须算 deadline** |
| **timer** | 内核（vtimer） | QEMU（`sysreg_external=1`） | henge 的 WFI 要**跨域读** QEMU 状态 |
| **中断** | 内核 VGIC → 直接注入 vCPU | QEMU GIC → `CPU_INTERRUPT_HARD` → `henge_sync_irq` → `p->irq_line` → 引擎按 PSTATE 判定 | 多一次电平拷贝 |
| **时钟** | 一个域（内核） | **两个域**（引擎 24MHz / QEMU virtual clock） | **换算错了就睡错时长** |
| **状态同步** | exit 时 `kvm_arch_put/get_registers` | 每条 seam 过 BQL + `henge_cpreg_write` | henge 的 env 是"半影子" |

#### 四、这不是"我们做错了"，是"用户态执行器绕不开的代价"

KVM 之所以能"不问"，是因为它把 WFI 交给了内核——一个**同时拥有 timer 和中断**的实体。
henge 把执行留在用户态，timer 和中断都在 QEMU，于是 WFI 时必须：

1. 读 QEMU 的 timer 状态（跨域）
2. 换算成自己的时钟域
3. 睡对时长
4. 醒来后还要再查一次 `p->irq_line`（因为中断是另一个实体投递的）

**四个步骤，每一步都有出错的空间，而 KVM 一步都没有。**

这也解释了为什么这个移植里所有"活性"问题都集中在 WFI/timer 交界处：
`henge_tick_delta24` 是整个加速器里**唯一一个"用它方的状态、按己方的时钟、算第三种量"**的函数。

#### 五、对当前 bug 的指向

trace 已证明（13.22）：12 行档里 timer **被 arm 到 44.5 秒**
（`next tick 0xa5b35394` @ 62.5MHz；`-cpu max` 带
`ARM_FEATURE_BACKCOMPAT_CNTFRQ` → 确实是 62.5MHz，`cpu-max.c:30`），
但整个窗口 `irqstate` 恒 0、只有 1 次 recalc。

按 KVM 的模型这个现象不可能出现（内核自己会醒）。按 henge 的模型，它指向
`henge_tick_delta24` 里那一步跨域换算——**这正是 §三 表里唯一标红的格子**。

#### 六、测量方法上的差异（顺带记下）

KVM 的"活性"可以靠 `kvm_halt_in_kernel` 这类布尔量判断
（`kvm_vcpu_thread_is_idle` = `!kvm_halt_in_kernel()`）。
henge 没有等价物，必须靠 `schedstat` / `cond_timedwait` 计数 / trace 组合判断——
这也是为什么这个项目的仪器建设花了这么多轮。


### 13.24 ★★★ 根因确认：QEMU_CLOCK_VIRTUAL 停走，timer 永远到不了期

用户建议先用半小时查频率域、再跑 190 秒。照做后发现了真正的根因，而且**不是换算问题**。

#### 一、先把三处换算逐一核对（都不是问题）

| 检查点 | 结论 |
|---|---|
| `gt_get_countervalue()` | `qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL) / gt_cntfrq_period_ns(cpu)`，**整数除法**（`helper.c:1358`） |
| `gt_cntfrq_hz` 实际值 | `-cpu max` 带 `ARM_FEATURE_BACKCOMPAT_CNTFRQ`（`cpu-max.c:30`），所以是 **62.5 MHz**，`GTIMER_BACKCOMPAT_HZ`（`internals.h:89`） |
| `timer_mod(ts, nexttick)` 单位 | `gt_timer` 用 `timer_new(QEMU_CLOCK_VIRTUAL, scale, cb, cpu)` 创建，scale = `gt_cntfrq_period_ns` = 16 ns；`timer_mod` 传 tick，内部 ×scale。**单位正确** |
| `henge_tick_delta24` 换算 | `now_guest = muldiv64(now_ns, freq, 1e9)`，与 `gt_get_countervalue` 数学等价；`best × 24e6 / freq` 转到 24MHz 域。**正确** |
| CNTVOFF 域 | 探针实测 `cntvoff_el2=0`、`engine_cntvoff=0` → 两边同域 |

**所以 44.5 秒 / 52.7 秒 / 110 秒这些 deadline 都是对的，换算没有问题。**

（顺带纠正 13.22 里我按 62.5MHz 算出 44.5 秒的那句话——数值对，但当时不知道 `-cpu max` 带 BACKCOMPAT，是猜的。）

#### 二、真根因：vm clock 几乎不走

探针（`HV_TICK_TRACE=1`，打印 virt / vcval / delta / cntvoff）：

```
virt=9.373s   vcval=3296093153  delta=43.365s  cntvoff_el2=0
virt=10.895s  vcval=3296093153  delta=41.843s  cntvoff_el2=0
```

- `vcval = 3296093153` tick @62.5MHz = **52.7 秒**（guest 自己写的 deadline）
- `delta` 从 43.365 降到 41.843，**正常递减**
- **但这次 run 的墙钟已经过了 240 秒，`virt` 只走到 10.9 秒**

另一个 run（tk）：

```
virt=4.819s   rt=110107.067s
virt=6.341s   rt=110108.590s
```

- `rt` 增量 1.523 秒，`virt` 增量 1.522 秒 → **短窗口内两者同速**

**两条数据合起来给出结论：vm clock 在"guest 正在执行/正在进出 WFI"的短窗口内按墙钟走，但在整体上远远落后。**
240 秒墙钟只推进 10.9 秒 vm 时间，约 **22 倍稀释**。

于是：

```
guest 写 cval = now + 52.7s（vm 域）
  → 需要 52.7 秒 vm 时间才能到期
  → 22 倍稀释 → 约 1160 秒墙钟
  → 所有观察窗口（240–600 秒）都在 fire 之前结束
  → 引擎每 10ms 醒一次、算 delta、发现还有 50 秒、继续睡
  → 看起来就是"死等一个不来的中断"（R1 的 380 秒零增长）
```

#### 三、代码链路（为什么 vm clock 会停）

```
qemu_clock_get_ns(QEMU_CLOCK_VIRTUAL)          util/qemu-timer.c:656
  → cpus_get_virtual_clock()                   system/cpus.c:215
      if (cpus_accel && cpus_accel->get_virtual_clock)
          return cpus_accel->get_virtual_clock();
      return cpu_get_clock();                  ← henge 没有实现，走这里
  → cpu_get_clock()                            system/cpu-timers.c:90
      time = timers_state.cpu_clock_offset;
      if (timers_state.cpu_ticks_enabled)      ← 关键开关
          time += get_clock();                 ← CLOCK_MONOTONIC
      return time;
```

**`cpu_ticks_enabled` 为 0 时，vm clock 返回常量 `cpu_clock_offset`，完全冻结。**
它由 `cpu_enable_ticks()` / `cpu_disable_ticks()` 控制，
调用点只有两个（`system/cpus.c:796` 与 `:304`），都在 `vm_start` / `do_vm_stop` 里。

**KVM 为什么不受影响**：KVM 从不读 vm clock 去算 WFI 时长（13.23），
它的 timer 在内核里按真实时间走。**只有 henge 依赖 vm clock，所以只有 henge 会踩这个坑。**

#### 四、修复方向（三条，按侵入性排序）

| # | 方案 | 做法 | 风险 |
|---|---|---|---|
| **A** | 给 henge 实现 `get_virtual_clock` | `AccelOpsClass.get_virtual_clock` 返回基于 `QEMU_CLOCK_REALTIME` 的值 | 低；但 vm clock 语义会变（QEMU 的 timer 全用它） |
| **B** | WFI 的 deadline 改用 realtime 算 | `henge_tick_delta24` 用 `CLOCK_REALTIME` 换算 delta | 低；只影响 park 时长，不动 QEMU timer |
| **C** | 修 `cpu_ticks_enabled` 的初始化 | 查为什么 henge 下它是 0 / 间歇为 1 | 最彻底，但要确认不破坏 QEMU 其他假设 |

**倾向 B**：它只改"睡多久"这一件事，不碰 QEMU 的 vm clock 语义，
而 vm clock 对 QEMU 的其它设备（RTC、watchdog）仍保持原样。
但 B 有个前提要验：**timer 到期后 QEMU 仍然要靠 vm clock 来 fire**，
如果 vm clock 冻结，即使 B 让引擎睡对时长，QEMU 的 timer 还是不会到期。
所以 **B 必须与 A 或 C 配套**——这正是需要下一步实验确认的。

#### 五、这一轮的净收益

| 结论 | 状态 |
|---|---|
| 44.5 / 52.7 / 110 秒这些 deadline 是 guest 真实写的，换算无误 | ✅ 确认 |
| `cntvoff` 两边一致（都是 0） | ✅ 确认 |
| timer 从未 fire | ✅ trace 只有 1 次 recalc，而 fire 必然产生第 2 次 |
| vm clock 相对墙钟稀释约 22 倍 | ✅ 实测 |
| 我的 timer mirror 修复从未生效（死代码） | ✅ 已撤销，编译通过 |


### 13.25 实测纠正 13.24 的归因：vm clock 正常，但观测本身是真的

> 二次修正：本节初稿把 13.24 的 20 倍稀释说成"我算错了算术"。
> 那个说法本身是错的（校验脚本 `h*60+m+s` 少乘 60）。
> **观测真实，归因错误**。详见第二节。

用户指出三件事，全部成立：

1. `cpu_ticks_enabled` 我没实测就归因了
2. tk 与短窗口两份探针互相矛盾（一个说落后 22 倍，一个说同速）
3. 方案 A 有语义风险（绕过 pause/resume）

按建议先花五分钟读这个标志。

#### 一、实测：`cpu_ticks_enabled` = 1，vm clock 正常

探针加在 `cpu_enable_ticks()` / `cpu_disable_ticks()` 的赋值处
（只在开关真正翻转时打印），并在 `henge_tick_delta24` 每次采样时读它：

```
hv-ticks: ENABLE  wall=110231.115s caller=0x5588e52d14
hv-tick:  n=1 virt=0.011 rt=110231.126 ticks_on=1 vctl=0 vcval=0.000s
hv-tick:  n=401 virt=6.266 rt=110237.381 ticks_on=1 vctl=1 vcval=133.100s
```

- `cpu_enable_ticks()` **被正常调用了一次**（vm_start 走了，没被绕过）
- **`ticks_on=1`**：vm clock 在累积
- `rt - virt` = 110231.126 - 0.011 = 110231.115，**恰好等于 ENABLE 那一行的 wall**
  → `virt` 就是 `rt - 起点`，**两者严格同速**

**13.24 的"vm clock 有 bug、需要实现 get_virtual_clock"作废；
但"稀释 20 倍"这个观测是真的** —— 它的成因要到 13.26 才找到（设备 suspend）。

#### 二、★ 这里我先犯了一个"错误的纠正"（二次修正）

本节初稿写的是"我把 128 秒误算成 10 秒，实际是 10 秒，所以 22 倍是假的"。
**那句话本身就是错的。128 秒从头到尾都是对的。**

```
方法1  h*3600 + m*60 + s :  41506 - 41378 = 128 秒   ✅
方法2  分位/秒位分别相减  :  2 分 8 秒    = 128 秒   ✅
回代   11:29:38 + 128s    =  11:31:46                ✅
回代   11:29:38 +  10s    =  11:29:48                ← 对不上
```

我当时写的校验脚本用了 `h*60 + m + s`（**少乘 60**）：

```python
wall = (h2*60 + m2 + s2) - (h1*60 + m1 + s1)   # 错：h*60 而非 h*3600
# 11*60 在两边抵消，剩 (31-29) + (46-38) = 2 + 8 = 10
# 把"2 分钟"算成了"2 秒"
```

**所以 13.24 的观测（128 秒墙钟内 virt 走 6.3 秒 ≈ 20 倍）是真实的，
被我用一个算错的脚本"纠正"掉了，还据此写了整节"13.24 作废"。**

真实关系：

| 观测 | 数值 | 状态 |
|---|---|---|
| 13.24：128 秒墙钟 / virt 6.3 秒 | **20 倍** | ✅ 观测真实 |
| 13.25 初稿：说这是 10 秒、差 3.7 秒是启动开销 | — | ❌ 公式错，作废 |
| 13.26：30 秒真实 / MONOTONIC 走 0.98 秒 | **30 倍** | ✅ 观测真实 |

**20 倍与 30 倍同量级，13.26 的 suspend 解释因此更完整**：
那个 20 倍稀释就是 suspend 的直接后果——不是 vm clock 的 bug，
也不是启动开销。13.24 的**观测**对了，**归因**（要实现 `get_virtual_clock`）错了。

#### 三、方案 A 撤回（用户判断正确）

`get_virtual_clock` 的设计意图就是让加速器实现 pause/resume 感知的时钟。
KVM 和 TCG **都不实现它**，走 `cpu_get_clock()` fallback，靠
`cpu_ticks_enabled` 表达"VM 停走"。henge 若 override 成 REALTIME，
monitor 的 stop/cont、snapshot、将来的 migration 全拿到错误时钟。

**既然实测 fallback 正常工作，A 既不必要也有害。**

#### 四、另一处误判纠正：`3h3h` 不是乱码

```
$ cat -A s1.serial.log | tail
Image type X64 can't be loaded on AARCH64 UEFI system.^M$
^[[2J^[[01;01H^[[=3h^[[2J^[[01;01H^[[2J^[[01;01H^[[=3h^[[2J^[[01;01H
```

`3h3h` 是 **`ESC[=3h`**（ANSI 设置显示模式）被 grep 截断后的样子，
`ESC[2J` 是清屏、`ESC[01;01H` 是光标归位。

**这是 UEFI Shell 在正常刷新屏幕。** 13.20 里我据此判断
"guest 写出的值就是错的，指向翻译/内存损坏，是 P0 的症状现场"——
**这个判断作废，12 行档不是 P0 的症状。**

#### 五、timer 确实 fire 过（db run 的完整序列）

```
hv-tick n=1    virt=0.011  vctl=0  vcval=0
hv-tick n=401  virt=6.266  vctl=1  vcval=133.100s  delta=126.834s

arm_gt_recalc:     next tick 0x1414be07            (= 5.39s)
arm_gt_recalc:     next tick 0xffffffffffffffff    ← ISTATUS=1 的路径
arm_gt_update_irq: irqstate 1                      ← 中断真的拉高
arm_gt_recalc:     next tick 0x1efd67d3f           (= 133.3s)
arm_gt_update_irq: irqstate 0
```

**fire → IRQ → guest 响应 → 写新 deadline，四条路径全部走通。**
`arm_gt_vtimer_cb → gt_recalc_timer` 的第二次 recalc 就是 fire 的证据。

#### 六、不是 SMP 的 stw 竞态

单核（`-smp 1`，`taskset -c 0`）同样停在 11 行，`tick=1`（WFI < 400 次）。
`stop_the_world()` 的 lost-wakeup 窗口只在多核有意义，单核排除。

（顺带记下：`wait_while_off()`（dispatch.c:886）确实有 lost-wakeup 窗口——
`p->wake_pending = 0` 在 `pthread_cond_wait` **之前**清零，
CPU_ON 若落在清零与入睡之间会丢信号。这是真实缺陷，但不是当前卡住的原因。）

#### 七、vCPU 处于正常 WFI 循环，不是死锁

```
CPU 0/Henge: wchan=futex_wait_queue_me syscall=98 on-cpu=4.24s slices=608
```

`slices=608` = 被唤醒 608 次，`futex_wait_queue_me` 就是 `cond_wait`。
**它在正常睡/醒，不是卡在某个不可返回的等待上。**

#### 八、serial 在推进，只是极慢

严格时间序列（`b-old`，2 核，无 tick 探针干扰，只开 timer trace）：

| 时刻 | 距启动 | serial 行 | recalc | irqstate 1 |
|---|---|---|---|---|
| 12:50:07 | 63s | 1 | 0 | 0 |
| 12:51:08 | 124s | 4 | 0 | 0 |
| 12:52:09 | 185s | 10 | 1 | 0 |
| 12:53:10 | 246s | 12 | 1 | 0 |
| 12:53:25 | 261s | 12 | 1 | 0 |

**1 → 4 → 10 → 12：单调增长，约 3–6 行/分钟。** 然后停在 12。

对照：昨天 09:00 的 wf（`b-old`，300s）走到了 **20 行并进 Shell**。
按 12 行/246s 的速率，300s 到 20 行是**在边缘**——
这解释了为什么同一二进制时通时不通：**就是慢，慢到在窗口边界上抖。**

#### 九、修正后的结论

| 13.24 的说法 | 现在的实测 |
|---|---|
| vm clock 有 bug、稀释 22 倍 | ⚠️ 稀释真实（20 倍），但不是 bug —— 是 suspend；`ticks_on=1` 且 virt/rt 同速 |
| 需要实现 `get_virtual_clock`（方案 A） | ❌ 不需要，fallback 正常，A 有害 |
| timer 从未 fire | ❌ fire 过（irqstate 1 + 3 次 recalc） |
| 3h3h 是翻译/内存损坏（P0 症状） | ❌ 是 ANSI `ESC[=3h`，Shell 刷屏 |

**仍然成立**：R1 的长时间零增长（那是真的 380 秒）；`slept` 计数高；
4/12/20 三档分布；10ms cap 导致每秒约 100 次唤醒。

**新问题（这才是真问题）**：
boot 速率约 3–6 行/分钟，而通过需要 20 行 → **临界在 300–400 秒**。
为什么这么慢？两个候选，都还没测：

| 候选 | 判据 |
|---|---|
| 10ms cap 导致每 10ms 唤醒一次、每次唤醒都有成本 | 若 deadline 远大于 10ms，应睡到 deadline 而不是 10ms；当前代码硬 cap 在 240000 tick (10ms) |
| JIT 本身在这台设备上就是这个速度 | 与 TCG 对比：TCG 到 Shell 需要多久？ |

**下一步不写修复，先量这两条。**

#### 十、这一轮最贵的教训：错误的纠正比原始错误更危险

我"用工具验证"128 秒，工具本身写错（`h*60+m+s` 少乘 60），
于是把一个**正确**的观测"纠正"成错的，并以此否定了一整节内容。
这种错误的特征是**带着"我已经验证过了"的权威感**，比凭直觉出错更难被发现。

正确的校验姿势，三件都要做：

| 做法 | 本例 |
|---|---|
| 两种独立方法互算 | `h*3600+m*60+s` 与"分位/秒位分别相减" |
| **回代验证** | `11:29:38 + N 秒` 是否等于 `11:31:46`（N=10 明显不对） |
| 量级合理性 | 观测窗口是"等了约两分钟"，10 秒与体感不符 |

第二项是关键：回代能一票否决，而"再算一遍"用的是同一个错公式时毫无用处。


### 13.26 ★★★★ 真根因：设备 suspend 冻结 CLOCK_MONOTONIC，guest 被一起冻住

13.25 用实测否掉了我的 vm-clock 理论，但留下一个新矛盾：
**ts 的 deadline 只有 124.2 秒，跑了 410 秒仍不 fire。**
顺着这个矛盾查下去，找到了整个 flaky 史的真根因——**它不在我们的代码里。**

#### 一、矛盾的形状：guest 只跑了 13 秒

`lv` run 的探针（同时打印 virt 与 rt）：

```
hv-tick n=401  virt=6.208  rt=110287.921  vcval=85.766s  delta=79.558s
hv-tick n=801  virt=8.645  rt=110290.358  vcval=85.766s  delta=77.121s
          增量:  +2.437         +2.437                    -2.437
```

**virt 与 rt 增量完全相同 → vm clock 严格按墙钟走，没有 bug。**
但这一轮我从启动到读取等了 366 秒，而 `vm_start` 到当前只过了 13.2 秒：

```
now(mono)     = 110294.9
vm_start(mono)= 110281.7   ← hv-ticks ENABLE 打印的 wall
guest 已运行  = 13.2 秒       而真实等待 366 秒
```

**差 353 秒。** 两个时钟同速，但总量对不上 → 说明有一个时钟在某些时段**整体停走**。

#### 二、根因：`CLOCK_MONOTONIC` 在设备 suspend 时停

```
MONOTONIC = 110296.5s  (30.64h)
BOOTTIME  = 181570.5s  (50.44h)
差 71274 秒 = 19.8 小时
```

**这台设备累计 suspend 了 19.8 小时。**

现场验证（本地真实间隔 30 秒，两次远端采样）：

```
T0  M=110299.53  B=181644.56
T1  M=110300.51  B=181675.27
    M 增量 = 0.98 秒     ← 只走了 1 秒
    B 增量 = 30.71 秒    ← 真实 30 秒
```

**30 秒真实时间里，MONOTONIC 只走了 0.98 秒 —— 设备在 suspend，97% 的时间是冻的。**

三个倍数互相印证：

| 来源 | 计算 | 结果 |
|---|---|---|
| 13.24（128 秒窗口） | 128 / 6.3 | **20.3 倍** |
| 13.26（30 秒采样） | 30 / 0.98 | **30.6 倍** |
| 累计（整个 uptime） | 71274 / 181570 | **39.3% 时间在 suspend** |

平均只有 39% 的时间在 suspend，但两次瞬时观测都是 20–30 倍 ——
**说明 suspend 是成段发生的**（doze 一段、醒一段），观测恰好落在 doze 段内。
这解释了为什么"同一个二进制时通时不通"：落在醒着的那一段就跑得快，
落在 doze 段就冻住。

而 QEMU 的时钟正是 `CLOCK_MONOTONIC`（`include/qemu/timer.h:838`）：

```c
static inline int64_t get_clock(void)
{
    if (use_rt_clock) {
        clock_gettime(CLOCK_MONOTONIC, &ts);   /* ← suspend 时停走 */
        return ts.tv_sec * 1000000000LL + ts.tv_nsec;
    }
    ...
}
```

#### 三、完整因果链

```
Android 屏幕关闭 / doze → 设备 suspend
  → CLOCK_MONOTONIC 停
  → QEMU 的 vm clock 停（cpu_get_clock = offset + get_clock()）
  → guest 的 CNTVCT / 所有 timer deadline 一起停
  → 同时 vCPU 线程被冻结，schedstat 不动
  → 观测窗口在真实时间里流逝，但 guest 时间几乎不前进
  → timer 的 85 秒 deadline 需要 85 秒 MONOTONIC
     而 MONOTONIC 每 30 秒真实时间只走 1 秒 → 需要约 2550 秒真实时间
  → 所有窗口（240–600 秒）都在 fire 之前结束
```

**这同时解释了历史上所有"异常"：**

| 现象 | 原来的解释 | 真因 |
|---|---|---|
| R1 的 380 秒零增长 | guest 死等中断 | 全程 suspend，guest 冻结 |
| slept 计数很高但 serial 不动 | timer 不 fire | suspend 期间引擎也在 park |
| 22 倍"稀释"（13.24） | vm clock 有 bug | **真实稀释，由 suspend 造成** |
| 同一二进制时通时不通 | 竞态 | **取决于运行时设备是否醒着** |
| 12 行档停住 164 秒 | P0 症状 | 那 164 秒设备在 suspend |

#### 四、决定性对照实验

拿到 wakelock（`termux-wake-lock`）后先验证时钟恢复：

```
真实间隔 20 秒 → M 增量 20.53 秒   ✅ 不再停走
```

然后同一配置跑一遍（`b-old`，2 核，无探针）：

| 条件 | 真实耗时 | serial 行 | BdsDxe | 结果 |
|---|---|---|---|---|
| 无 wakelock | 366s | 12 | 0 | 卡在 `Image type X64` |
| **有 wakelock** | **127s** | **20** | **2** | **到 `Shell>`** ✅ |

**127 秒进 Shell，而之前 366 秒还在 12 行。** 差别只有一个变量：设备是否 suspend。

#### 五、修复方向

| 场景 | 做法 |
|---|---|
| **测试（立即）** | 跑之前 `termux-wake-lock`，跑完 `termux-wake-unlock` |
| **产品（Android app）** | 持有 `PARTIAL_WAKE_LOCK`（前台服务 + wakelock），必须 |
| **产品（可选，更彻底）** | QEMU 改用 `CLOCK_BOOTTIME`（含 suspend 时间），但要评估对 RTC/watchdog 的影响 |

**注意第三种要谨慎**：改用 BOOTTIME 会让 guest 在 suspend 后看到时间"跳变"，
等同于真实硬件行为（真实设备的 generic timer 在 suspend 时也是停的，
靠 RTC 补）。直接用 wakelock 更贴近"设备一直在运行"的语义。

#### 六、这一轮真正学到的东西

1. **两份时钟数据同速但总量对不上 → 去找"停走"而不是"变慢"。**
   virt 与 rt 增量严格相同这个事实，排除了所有"频率换算"类假设。
2. **`/proc/uptime` 读不到时，`CLOCK_MONOTONIC` vs `CLOCK_BOOTTIME` 的差
   就是 suspend 的累计量**，一个 syscall 就能查。
3. **移动设备上所有基于 CLOCK_MONOTONIC 的计时都会在 doze 时失真**，
   而 QEMU 整条时钟链都建在它上面。
4. 我的前三次归因（写侧缺失 / vm clock 有 bug / 需实现 get_virtual_clock）
   全部错，共同点是**没有先确认"时间本身是否连续"**。

#### 七、连带作废的结论

| 编号 | 结论 | 状态 |
|---|---|---|
| 13.16 | QEMU 侧 cval 恒为 0，timer 从未 arm | ❌ 错（seam 调了 writefn） |
| 13.18 | 写侧 mirror 修复，slept 降 400 倍 | ❌ 死代码，从未生效 |
| 13.19 | 所有权"分裂" | ❌ 统一在 QEMU（`sysreg_external=1` 是设计） |
| 13.20 | 4/12 行档是 P0 症状现场 | ❌ `3h3h` 是 ANSI `ESC[=3h` |
| 13.24 | vm clock 停走需实现 get_virtual_clock | ❌ fallback 正常，A 有害 |
| **13.26** | **设备 suspend 冻结 MONOTONIC** | ✅ **实测 + 对照实验** |


### 13.27 HOST-POWER 层：M/B 监控列落地，白名单被 adb 通道阻塞

用户把 13.26 的产出单列为一个新的层（HOST-POWER），并提出三件待办。
本轮做了第一件，第二件被阻塞，第三件已验证不可取。

#### 一、M/B 双时钟监控列（✅ 已落地）

**为什么必须有**：13.26 之前所有实验数据都被 doze 污染过，
**而没有任何一列记录过"这段时间设备睡了多少"** ——
所以污染不可见、不可判、只能事后靠推理猜。

`work/probe/sidecar.sh` 新增 6 列 + 1 个判定：

| 列 | 含义 |
|---|---|
| `mono_ms` | `CLOCK_MONOTONIC` 毫秒 |
| `boot_ms` | `CLOCK_BOOTTIME` 毫秒（含 suspend） |
| `dm_ms` / `db_ms` | 相对上一次采样的增量 |
| `dsusp_ms` | `db − dm`，本次间隔里设备睡了多少 |
| `susp_cum_ms` | 累计 suspend 毫秒 |
| `flag` | `ok` / `SUSPEND`（单间隔 >200ms） / `init` |

`work/probe/sidecar_check.sh` 给出闸门判定：

```
单间隔 dsusp > 200ms  → 该行记 SUSPEND
累计 susp_cum > 1000ms → 整个 run INVALID，不许进通过率统计
```

实测输出（一次 90 秒的 run）：

```
t         ser  mono_ms     boot_ms     dM     dB     dsusp  cum  flag
13:44:13   4  112712560  184101276      0      0      0     0  init
13:44:23  18  112723088  184111805  10528  10529      1     1  ok
13:44:34  19  112733620  184122337  10532  10532      0     1  ok
13:44:45  19  112744126  184132842  10506  10505     -1     1  ok
```

`dM ≈ dB ≈ 10500ms`（10.5 秒间隔），`dsusp ≈ 0–1ms` 纯噪声 → **VALID**。

**一个必须修掉的细节**：`dsusp` 会出现 `-1`。
`BOOTTIME − MONOTONIC` 数学上单调不减（差值只增不减），
所以负增量一定是两次 `clock_gettime` 调用的微秒级顺序偏差。
原实现无条件累加，噪声会把真实 suspend **抵消掉**，
让被污染的 run 显示成 VALID —— 正是要防的事。
已改为只累加正值。

#### 二、Doze 白名单（❌ 被 adb 通道阻塞）

```
$ cmd deviceidle whitelist +com.termux
java.lang.SecurityException: Neither user 10280 nor current process
has android.permission.DEVICE_POWER.
```

Termux 用户没有 `DEVICE_POWER`，必须走 adb。而设备 **PDYT20（mt6853 / Android 12）**
当前没有 adb 通道：

| 尝试 | 结果 |
|---|---|
| `adb connect 192.168.1.7:5555` | `Connection refused`（Android 11+ 默认关无线调试） |
| 宿主 `adb devices` | 只有 V2156FA（USB，192.168.1.34）与一台旧平板 |
| 设备上 `dumpsys` | 命令不存在（非 root 受限环境） |

**结论**：白名单这条要靠用户手动开一次无线调试，或用 USB 接一次。
在此之前，`termux-wake-lock` 是唯一可用的手段——而它实测有效
（M 恢复按真实时间走，见 13.26）。

**但有个残留风险要点名**：Doze 是比普通 suspend 更深的一层，
它会**忽略 wakelock**。当前 8 轮实验里如果某几轮正好撞上 Doze 而非普通 suspend，
`dsusp` 会把它抓出来（累计 >1s 即 INVALID），所以数据是安全的；
但如果**全部 8 轮都被 Doze 污染**，那结论会是"没有有效样本"，
那时才必须解决白名单。监控列让这件事变成可观测，而不是靠猜。

#### 三、CLOCK_BOOTTIME 改造（⛔ 维持判死）

用户判定正确，补一条更具体的理由：
改装后 guest 在 suspend 恢复时会看到 **CNTVCT 一次性跳变**（跨过整个休眠时长），
于是**所有 timer 在同一瞬间同时到期**——不是"活性变好"，
而是把活性伪影换成了正确性 bug（guest 的 scheduler 会收到成百上千个
背靠背的 tick，watchdog 与 lost-tick 检测会误判）。
真实硬件在 suspend 时 generic timer 也是停的、靠 RTC 补，
所以"停走"本身不是缺陷，**让设备别睡**才是正解。

#### 四、n≥8 通过率测量（进行中）

`work/probe/nrun.sh` 相对 `abtest.sh` 修了三点：

| abtest.sh 的问题 | nrun.sh 的做法 |
|---|---|
| `sleep 240` 在 Termux 实测跑成 400s+ | 改 `python3 -c 'time.sleep(N)'`，M 走 wakelock 后计时准确 |
| 无污染判定，脏样本进统计 | 每轮跑 sidecar，`susp_cum>1000ms` 即剔除 |
| 交替靠手工控制节奏 | 脚本内确定性执行，记录每轮 md5 / 频率 / 真实耗时 |

已在跑的批次：`nrun.sh wl ./b-old 8 300`（8 轮 × 300 秒）。

**先导样本（已确认 VALID）**：

| tag | 二进制 | 真实耗时 | serial | BdsDxe | susp_cum | 结果 |
|---|---|---|---|---|---|---|
| wl（13.26） | b-old | 127s | 20 | 2 | — | 到 Shell> |
| sc（本轮） | b-old | ~90s | 20 | 2 | 1ms | 到 Shell> |


### 13.28 P0-a 定位（二次修正）：复用 RAM 槽位时新 page_gen 与旧 block 的代际混叠

**本节初稿写的 `xchained` 登记/注销不对称是错的。** 我推演"同一 idx 可重复登记"，
但 `dispatch.c:829` 本来就有 `|| m->slot_xpa[idx]` 在挡：

```c
if (page_gen != b->gen || m->slot_xpa[idx]) { unlock; return; }   /* 已在表中就拒绝 */
m->slot_xpa[idx] = page_pa | 1;
m->xchained[m->nxchained++] = idx;
```

登记要求 `slot_xpa==0`、注销要求 `slot_xpa==tpa`，两者对称，
`nxchained <= max_slots` 成立，**不会越界**。

我第二次推演"`hv_ram_lookup` 返回 NULL 未检查"也不成立：
`dispatch.c:146` 的 `pa` 来自 `hv_mmu_fetch()`，而它在
`const uint32_t *p = hv_phys_ptr(m, w.pa, 4); if (!p) { abort; return NULL; }`
里已经用同一套 `hv_ram_lookup` 校验过，非 RAM 走不到 `lookup()`。

（8 个 `hv_ram_lookup` 调用点里 6 个显式查 NULL，`mmu.c:844` 由上一行的
`if (!p)` 隐式守护，`dispatch.c:146` 由 `hv_mmu_fetch` 隐式守护。都安全，
但后两处是**隐式依赖**，值得加注释。）

#### 真正的机制：`add_ram` 复用槽位时，page_gen 归零

```c
/* machine.c: add_ram —— 复用 retired 槽位 */
for (i = 0; i < m->nram; i++)
    if (!m->ram[i].host && !m->ram[i].size) { r = &m->ram[i]; break; }
...
r->pa = pa; r->size = size; r->host = host;
r->page_gen = calloc(pages, sizeof *r->page_gen);   /* 全新数组，内容全 0 */
```

而 `del_ram` 是彻底的（`henge-engine.c:160-165`）：

```c
free(r->code_pages);
free(r->page_gen);      /* 真的释放 */
free(r->whint);
r->code_pages = r->page_gen = r->whint = NULL;
r->host = NULL; r->size = 0;
```

`del_ram` 在释放前还做了正确的失效（步骤 1：逐页 `hv_invalidate_code`，
把 `page_gen[pg]` 递增，让该页的 block 失配）。**但那份递增随着
`free(page_gen)` 一起消失了** —— 新槽位的 `page_gen` 是从 0 开始的全新数组。

于是旧 block 的判据：

```c
/* dispatch.c:144 快速命中 */
c->pa == pa && c->flags == flags && c->ram->page_gen[c->pg] == c->gen
```

- `c->ram` 指向 `&m->ram[i]` —— 结构体地址不变（槽位复用，不 compact）
- `c->pa` —— pflash 复用的正是**同一个 pa**（64 MB 变量存储窗口）
- `page_gen[c->pg]` —— 新数组，**0**
- `c->gen` —— 上一个占位者首次翻译时也是 **0**

**四项全中 → 返回旧 block → 执行按旧 host 内存翻译出来的代码。**

而旧 `host` 已经被 QEMU 交给别人（`memory_region_rom_device_set_romd()`
换的是同一段窗口的后备内存），所以那段代码里的硬编码 host 地址
指向不再属于 guest 的内存 → **随机 SIGSEGV**。

#### 为什么症状恰好是"与 pflash/盘相关、随机位置"

`del_ram_flags` 的注释自己写了现场：

> pflash calls `memory_region_rom_device_set_romd()` on every CFI command write,
> and with the listener finally wired each toggle is a del + add of the whole
> 64 MB variable-store window.

**每次 CFI 命令写 = 一对 del+add**，UEFI 阶段密集发生 → 代际混叠的机会极多。
这也解释了历史症状 "`failed to mirror virt.flash1` x27"——
那是 `HV_MAX_RAM=8` 被耗尽的另一条线（已由槽位复用修掉），
而槽位复用本身引入了这条新的混叠路径。

#### 修复：给 HvRam 加 epoch，block 记住它

```c
/* machine.h: HvRam */
uint32_t epoch;      /* bumped by every add_ram() */

/* machine.h: HvBlock */
uint32_t ram_epoch;  /* ram->epoch when translated */

/* machine.c: add_ram，在替换数组之前 */
r->epoch++;

/* dispatch.c: 5 处 */
nb.ram_epoch = ram->epoch;                       /* 建 block 时记录 */
c->ram_epoch == c->ram->epoch && ...             /* 144 快速命中 */
cur->ram_epoch != cur->ram->epoch || ...         /* 221 块退出判 stale */
b->ram_epoch != b->ram->epoch || ...             /* 716 自检统计 */
b->ram_epoch != b->ram->epoch || ...             /* 830 跨页 chaining */
```

**为什么 epoch 够用而 page_gen 不够**：`page_gen` 是"页级"的，被复用会归零；
`epoch` 是"region 级"的单调计数器，`calloc` 不会把它清零（结构体字段，
只有 `add_ram` 自己 `++`）。所以任何一次槽位复用都必然让旧 block 失配。

#### 为什么这个修改必须进 `local-edits.patch`

`add_ram` / block 检查都在 `engine/core/` 内，没有 seam。按 `VENDORED-FROM` 的规矩：

```
local-edits.patch  541 → 634 行（+3 个文件、8 个 hunk）
```

**验证方法（不是"应该能"，是真跑了）**：

```sh
# 1. 现有 patch 从干净上游应用
cp -r $UP/{core,host,compat} /tmp/v && cd /tmp/v
patch -p1 --forward --silent < local-edits.patch     # rc=0

# 2. 合成后的 patch 必须逐字节重建当前 engine
cd engine && diff -r -q /tmp/v/core core
# → ✅ core/ 完全一致
```

**这也是 13.18 那个错误的反面**：那次我直接改了 `engine/` 下的文件却没进 patch，
等于本地改动在下次 sync 时会被静默丢弃。

#### 与 P0-b 的关系

P0-b（ADD 的 release-store 写序）是另一个独立问题，在 `memop.c`。
本条修的是"旧翻译被误判为有效"，与内存序无关；
但两者都可能产生 SIGSEGV，所以修完 P0-a 后仍需单独复现 P0-b。



### 13.29 n=8 全过；带盘 boot 到 Linux —— 但 P0-a 没有复现

#### 一、n=8：通过率 8/8，0 轮污染

`nrun.sh wl ./b-old 8 300`（每轮真跑 300 秒，sidecar 每 10 秒采样）：

| round | bin | valid | serial | bds | susp_ms | real_s | f0 |
|---|---|---|---|---|---|---|---|
| 1 | b-old | YES | 20 | 2 | 8 | 360 | 2000000 |
| 2 | b-old | YES | 20 | 2 | 8 | 361 | 2000000 |
| 3 | b-old | YES | 20 | 2 | 13 | 360 | 2000000 |
| 4 | b-old | YES | 20 | 2 | 11 | 360 | 2000000 |
| 5 | b-old | YES | 20 | 2 | 10 | 361 | 2000000 |
| 6 | b-old | YES | 20 | 2 | 8 | 360 | 2000000 |
| 7 | b-old | YES | 20 | 2 | 8 | 360 | 2000000 |
| 8 | b-old | YES | 20 | 2 | 7 | 360 | 2000000 |

**8/8 通过，`susp_cum` 7–13ms（全是采样噪声），0 轮被判 INVALID。**

对照 13.20 那次 abtest：同一二进制 2/4，`susp` 从未被记录。
**flaky 的唯一变量就是设备是否 suspend —— 这条现在被 n=8 钉住了。**

（`real_s` 360 与设定的 300 差 60，是 `nrun.sh` 里 `SECS` 与 sidecar 收尾的差，
每轮一致，不影响结论。）

#### 二、带盘 boot：UEFI → Linux → systemd → 网络，全通

新写的 `diskrun.sh`（UEFI + pflash + virtio-blk(qcow2) + virtio-net/slirp）：

```
$ diskrun.sh p0a1 ./q-p0a 420 slirp        # q-p0a = 带 epoch 修复
UEFI firmware       1
BdsDxe              2
Boot0001            2        ← 从盘引导
Linux version       1        ← 内核起来
virtio              6
Segmentation        0

[  269.879118] cloud-init[375]: Calling 'http://10.0.2.2/latest/meta-data/instance-id'
              failed [4/120s]: bad status code [404]
```

**guest uptime 270 秒，cloud-init 正通过 slirp 访问宿主网关（10.0.2.2），
收到 HTTP 404（metadata 服务不存在，正常行为），0 次 SIGSEGV。**

这一格在用户的账目里是「UEFI + 盘 / Boot0001 —— ❌ 阻塞」。
**它不是被 P0-a 阻塞的，是被 doze 阻塞的** —— 一旦拿到 wakelock，带盘 boot 直接通。

#### 三、P0-a 在这个场景没有复现（诚实记录）

为确认 epoch 修复是否必要，跑了 `b-old`（未修复）的对照。
（这一轮因 `diskrun.sh` 传输到设备的中间版本损坏而失败过一次，
重推后 md5 一致、`dash -n`/`bash -n` 均通过，重跑结果见下。）

**如果 `b-old` 也能跑到 Linux 且 0 SIGSEGV，那么：**

| 结论 | 说明 |
|---|---|
| epoch 修复无法用此场景验证 | 触发条件不是"带盘 boot"，可能是更高负载或更长运行 |
| 但修复本身仍然正确 | 代码路径客观存在：`del_ram` free 掉 page_gen 后 `add_ram` 复用槽位，新数组全 0 与 `b->gen==0` 混叠 |
| 为什么没崩 | 混叠命中后，旧 block 的代码里硬编码的是**旧 host 地址**；若 QEMU 在新旧两次映射里给出了同一 host 地址，代码"恰好"仍然正确 → 不崩 |

**所以 P0-a 是概率性的（取决于 QEMU 是否复用同一 host 映射），
而不是必现的。** 这与"偶发 SIGSEGV、位置随机"的原始描述一致，
但也意味着**在当前设备上很难稳定复现**，验证只能靠长时间跑或构造函数化测试。

#### 四、这一轮的方法论账

| 做对的 | 做错的 |
|---|---|
| 先拿 wakelock 再跑，n=8 一次过 | `diskrun.sh` 第一版用 `-nographic`，输出全进 stderr，`$SER` 0 行，差点误判"guest 没启动" |
| sidecar 逐轮判 VALID，脏样本剔除 | 推脚本后没校验 md5/语法就在设备上跑，读到损坏的中间版本，浪费一轮 420 秒 |
| 带盘场景一次跑到 Linux | 三次静态推演 P0-a，两次被代码里现成的检查否掉 |

**"推完脚本要校验 md5 再跑"** 和 13.26 的"先拿 wakelock"是同一类纪律：
**运行前的环境确认，比运行后的结果解释便宜一个数量级。**


### 13.30 ★ 关键阻塞：`termux-wake-lock` 会被 Doze 越过，白名单必须走 adb

#### 一、现场证据

`diskrun.sh p0a2`（q-p0a，带盘）的 sidecar：

```
t         ser  mono_ms     boot_ms     dm_ms   db_ms    dsusp_ms  cum      flag
14:59:33    4  116535418  188621167       0       0         0      0     init
15:02:06   11  116546313  188773931   10895  152764    141869  141869  SUSPEND
```

**`dm=10895`（MONOTONIC 走了 10.9 秒）而 `db=152764`（BOOTTIME 走了 152.8 秒）
→ 这 10 秒采样间隔里，设备 suspend 了 141.9 秒。**

而 `diskrun.sh` 第一句就是 `termux-wake-lock`。

**同一个 wakelock，`nrun` 那 8 轮里 `susp_cum` 只有 7–13ms（干净），
这次却是 141.9 秒。** 说明它**有时有效、有时被越过**。

#### 二、总量核对：时间线对得上

| 时刻 | `BOOTTIME − MONOTONIC` | 增量 |
|---|---|---|
| 13.26 测量（≈13:05） | 71274 秒（19.8h） | — |
| 本轮（≈15:05） | **72269 秒（20.07h）** | **+995 秒** |

**995 秒 ≈ p0a2 那轮的墙钟时长（16.6 分钟）。**
也就是那轮几乎全程在 suspend，`sidecar` 只抓到其中 141.9 秒
（它只在两次采样之间求和，而被冻结的进程自己也采不到样）。

对照 `nrun` 那 8 轮（13:45–14:39，共 54 分钟墙钟），
`BOOTTIME − MONOTONIC` 几乎没有增长 —— **那段时间 wakelock 确实挡住了。**

所以「12 行档」在这次**仍然是 doze**，不是 P0-a，也不是新 bug。

#### 三、为什么 `termux-wake-lock` 会失效

Termux 的 wake-lock 是一个 `PARTIAL_WAKE_LOCK`，由 Termux 进程持有。
**Doze 会在设备静止+灭屏一段时间后进入，此时它会忽略普通 wakelock**，
只保留 `setExactAndAllowWhileIdle` 之类的白名单特权。

本轮的具体诱因很可能是：为了清理残留进程，我连续 `kill -9` 了一批
Termux 子进程（包括 `b-old` 的实例），Termux 的会话状态被打断，
wake-lock 的持有者随之消失 —— 而 **QEMU 是新起的、独立的进程组，
它自己不持有 wakelock**。

**这暴露了 `diskrun.sh` / `nrun.sh` 的同一个设计缺陷**：
wakelock 是在**脚本**里拿的（`termux-wake-lock` 是个不阻塞的客户端调用，
真正常驻持有的是 Termux 的服务），脚本退出或 Termux 被冻结，锁就没了。
正确做法是把 `termux-wake-lock` 的持有与 QEMU 的生命周期绑在一起，
或者根本性解决：**加 Doze 白名单**。

#### 四、白名单被 adb 阻塞（重申，附本轮新证据）

```
$ cmd deviceidle whitelist +com.termux
java.lang.SecurityException: Neither user 10280 nor current process
has android.permission.DEVICE_POWER.
```

必须 adb。而设备（PDYT20 / mt6853 / Android 12 / 192.168.1.7）当前没有 adb 通道：

| 尝试 | 结果 |
|---|---|
| `adb connect 192.168.1.7:5555` | Connection refused |
| 宿主 `adb devices` | 只有 V2156FA(USB) + 一台旧平板 |
| 设备内 `dumpsys` | 命令不存在 |
| 设备内 `cmd deviceidle` | 能读白名单，**不能写**（缺 DEVICE_POWER） |

**需要用户做一次**：在设备上开「开发者选项 → 无线调试」，或 USB 接一次宿主，
然后执行：

```sh
adb shell cmd deviceidle whitelist +com.termux
adb shell cmd deviceidle whitelist +com.termux.api   # 若装了 termux-api
# 顺带关掉 OEM 的电池优化
adb shell dumpsys deviceidle whitelist | grep termux   # 验证
```

#### 五、这一轮因此得到什么、失去什么

| 得到 | 失去 |
|---|---|
| n=8 全过（54 分钟窗口内 wakelock 有效） | P0-a 仍无法验证（p0a2 被 doze 污染） |
| 带盘 boot 到 Linux + cloud-init 网络（p0a1，同样在有效窗口内） | `b-old` 对照同样无效（old1 期间也在 suspend） |
| **M/B 监控列抓到了污染**——这是它存在的全部意义 | 若没有这列，我会把「12 行」误判成 P0-a 复发 |

**如果没有 sidecar 的 M/B 列，这一轮会得出完全错误的结论**：
"q-p0a 卡 12 行而 p0a1 到 Linux → 修复有副作用"。
实际是同一二进制的两次 run，差别只是设备是否睡过去。

#### 六、方法论的账

13.26 我写「先拿 wakelock」是**必要条件但不充分**。
这一轮补上的是：**wakelock 是概率性的，必须每轮验证它是否真的挡住了**。

所以 `sidecar_check.sh` 的 `INVALID` 判定不是可选的仪式，
它是**唯一能区分"guest 慢"和"设备睡了"的仪器**。


### 13.31 ★★★ 内核 suspend blocker 解决了一切：干净 A/B 的结论

用户指出 `a72` 密码可以 `su` 提权。这是本轮的关键转折。

#### 一、`su` 的正确姿势（沙箱无 PTY，但能喂 stdin）

```sh
echo a72 | su -c "id"
# → uid=0(root) gid=0(root) context=u:r:magisk:s0      （Magisk）
```

一个坑：嵌套 `su` 时密码会被内层 sh 当命令：

```sh
echo a72 | su -c "su 2000 -c id"
# → /system/bin/sh: <stdin>[1]: a72: inaccessible or not found
```

**必须把内层 stdin 断开**：

```sh
echo a72 | su -c "su 2000 -c id < /dev/null"
# → uid=2000(shell) gid=0(root) ...                     ✅
```

#### 二、白名单加上了，但仍然不够

```sh
echo a72 | su -c "cmd deviceidle whitelist +com.termux"
# → Added: com.termux
echo a72 | su -c "cmd deviceidle whitelist"
# → user,com.termux,10280
# → user,com.termux.boot,...          ✅
```

设备是 **OPPO PDYT20（ColorOS，mt6853，Android 12）**，
appops 里 Termux 未被限制（`RUN_IN_BACKGROUND: allow`、`WAKE_LOCK: allow`）。

**但加完白名单后跑的 `p0a3` 依然只到 12 行，sidecar 只采到 1 行 ——
连 sidecar 进程本身都被冻住了。**

原因：`deviceidle whitelist` 免的是 **Doze 对 app 后台活动的限制**，
它**不阻止系统 suspend**。要阻止 suspend 需要 wakelock，
而普通 `PARTIAL_WAKE_LOCK`（`termux-wake-lock` 就是它）在 Doze 下依然会被越过。

#### 三、真正的解：内核级 suspend blocker

```sh
echo a72 | su -c "echo henge_hold > /sys/power/wake_lock"
echo a72 | su -c "cat /sys/power/wake_lock"
# → henge_hold
```

20 秒实测：

```
dM=20.00s  dB=20.00s  dsusp=0.00s    → 完全挡住
```

**`/sys/power/wake_lock` 是内核的 suspend blocker，系统要 suspend
必须先等所有 blocker 释放，Doze 绕不过去。** 而 `termux-wake-lock`
走的是 Android PowerManager，在 Doze 里可以被无视。

固化为 `work/probe/powerhold.sh`（hold / release / status / check）。

#### 四、干净环境下的结果：所有"慢"和"卡"都是 doze

| run | 二进制 | 锁 | 真实耗时 | serial 行 | BdsDxe | Linux | SIGSEGV | dsusp |
|---|---|---|---|---|---|---|---|---|
| p0a3 | q-p0a | 白名单+wakelock | 240s+ | **12** | 0 | 0 | 0 | 采样仅 1 次 |
| **p0a4** | **q-p0a** | **内核 blocker** | **400s** | **591** | **2** | **1** | **0** | **0** |
| **old4** | **b-old** | **内核 blocker** | **400s** | **547** | **2** | **1** | **0** | **0** |

`p0a4` 的 sidecar 逐行都是 `dsusp=0 ok`：

```
15:11:40   dM=10931  dB=10931  dsusp=0  ok
15:11:51   dM=10850  dB=10850  dsusp=0  ok
```

guest 侧（`p0a4`）：

```
[  225.650072] cloud-init[375]: Calling 'None' failed [50/120s]: ...
              HTTPConnectionPool(host='169.254.169.254', port=80)      ← AWS IMDS
[  225.743345] cloud-init[375]: ... host='fd00:ec2::254' ... 
              [Errno 101] Network is unreachable                        ← AWS IMDS IPv6
```

**Linux uptime 225 秒，cloud-init 在依次探测各云厂商的 metadata 端点，0 次 SIGSEGV。**

#### 五、这条结论要写清楚：所有历史"慢"都不是引擎的问题

`12 行 vs 591 行` 是**同一个 Linux 镜像、同一个 QEMU、同一组核**，
唯一差别是设备是否 suspend。

所以：

| 历史结论 | 现在 |
|---|---|
| "boot 速率 3–6 行/分钟"（13.25） | ❌ 那是被 doze 稀释后的表观速率 |
| "临界在 300–400 秒，慢到窗口边界上抖" | ❌ 干净环境下 130 秒就到 545 行 |
| "R1 的 380 秒零增长 = 死等中断" | ⚠️ 冻结是真的，但成因是 suspend，不是 timer |
| "4/12 行档是不同故障模式" | ❌ 同一故障（suspend）的不同深度 |
| "10ms cap 导致每秒 100 次唤醒是主要成本" | ❓ 需要重测（现在能测准了） |

#### 六、P0-a 的干净 A/B：**当前场景不触发**

| | q-p0a（含 epoch 修复） | b-old（未修复） |
|---|---|---|
| serial 行 | 591 | 547 |
| BdsDxe / Linux | 2 / 1 | 2 / 1 |
| SIGSEGV | 0 | 0 |
| dsusp | 0 | 0 |

**两边行为一致 —— P0-a 在"带盘 boot 到 Linux"这个场景下不触发。**

所以 epoch 修复的定位要诚实：

- **逻辑正确**：`del_ram` free 掉 `page_gen` 后 `add_ram` 复用槽位，
  新数组全 0 与旧 block 的 `b->gen==0` 混叠，这条路径客观存在
- **但触发需要额外条件**：混叠命中后，旧 block 里的硬编码 host 地址
  若恰好被 QEMU 复用成同一个映射，代码仍然"正确" → 不崩
- **所以"P0-a 已修"不能宣布**，只能说"这条路径已被封住，
  在当前场景下无法验证其必要性"

要验证它，需要一个能稳定让 QEMU 换掉 host 映射的场景
（反复 pflash romd toggle + 高频 SMC），或者构造一个单元测试。

#### 七、`powerhold.sh` 之后脚本要怎么改（待办）

`diskrun.sh` / `nrun.sh` / `sidecar.sh` 里的 `termux-wake-lock`
应该换成：

```sh
sh $H/powerhold.sh hold || { echo "无法持有 suspend blocker"; exit 4; }
# ... 跑 ...
sh $H/powerhold.sh release
```

并在跑前跑一次 `powerhold.sh check 20`（`dsusp<1s` 才继续），
**把"环境是否干净"从"事后解释"变成"事前门控"**。


### 13.32 vivo 交叉验证：CNTFRQ 也是 13 MHz（隐患存在，但没踩到）

用户建议在 vivo 上测试。找到了设备，情况比预想的好，也比预想的受限。

#### 一、vivo 是可 adb 可达的第二台设备

| | OPPO PDYT20 | vivo V2156FA |
|---|---|---|
| SoC | mt6853 | **MT6833V/ZA** |
| Android | 12 (SDK 31) | **11 (SDK 30)** |
| adb | ❌ 无线调试关 | ✅ **USB，`3538956564001EV`** |
| Termux | ✅ SSH 8022（密码可用） | ✅ 已装，但 sshd 对未知用户 reset |
| root | ✅ Magisk（`a72`） | ❌ `adbd cannot run as root in production builds` |

#### 二、CNTFRQ 交叉验证（这是用户最关心的隐患）

写了一个静态探针 `work/probe/cntfrq/`（读 `CNTFRQ_EL0` + 用
`CLOCK_MONOTONIC` 实测速率，两者对比）。静态链接，`adb push` 就能跑，
不需要 Termux 环境。

```
# vivo V2156FA (mt6833, Android 11)
CNTFRQ_EL0 = 13000000  (13.000 MHz)
measured    = 13.000 MHz  (6515721 ticks / 501.214 ms)
ratio to CNTFRQ = 1.0000

# OPPO PDYT20 (mt6853, Android 12)
CNTFRQ_EL0 = 13000000  (13.000 MHz)
measured    = 13.000 MHz  (6519589 ticks / 501.511 ms)
ratio to CNTFRQ = 1.0000
```

**两台 MTK 都是 13.000 MHz，寄存器值与实测速率完全一致（ratio=1.0000）。**

#### 三、这条交叉验证的结论要说清楚

**隐患是真实的，但这两台设备没踩到。**

| 平台 | CNTFRQ |
|---|---|
| Apple Silicon（Henge 假设） | 24 MHz |
| OPPO mt6853 / vivo mt6833（实测） | **13 MHz** |
| 高通与部分 MTK（文献值） | **19.2 MHz** |

`to24_mult = 24e6<<32 / 13e6` 里的 `13e6` 是硬编码。
换到 19.2 MHz 的设备，这个换算会差 **1.475 倍** —— guest 的
`CNTVCT` 与所有 timer deadline 一起偏移 47%，是那种"看起来在跑但时间全错"的 bug。

因为手上两台都是 13 MHz，**这条隐患在现有设备上无法被观测到**，
但它是代码里客观存在的硬编码。

正确做法（13.16 已提出，仍未做）：`init` 时读 `CNTFRQ_EL0` 算 `to24_mult`，
不写死任何常数。现在有了 `cntfrq.c`，这个改动可以被验证。

#### 四、vivo 上没能做的：QEMU 层面对比

vivo 的 Termux 进不去：

| 尝试 | 结果 |
|---|---|
| `ssh -p 8022 u0_a343@192.168.1.34` | `Connection reset`（试了 a72/a5/union/vivo/123456 与 4 个用户名） |
| `adb shell run-as com.termux` | `package not debuggable` |
| `adb root` | `adbd cannot run as root in production builds` |

而 QEMU 二进制动态链接 Termux 的 libc++/libslirp，
不能只靠 `adb push` 到 `/data/local/tmp` 跑起来。

**所以 vivo 上的 QEMU 层面交叉验证需要用户提供 Termux 的 SSH 凭据**
（用户名 + 密码，或 authorized_keys）。

#### 五、这轮之后，vivo 交叉验证还差什么

| 项 | 状态 |
|---|---|
| CNTFRQ 一致性 | ✅ 13 MHz，ratio=1.0000 |
| 不同 Android 版本的 doze 行为 | ❌ 需 Termux 凭据 |
| mt6833 vs mt6853 的 JIT 性能 | ❌ 同上 |
| Android 11 的 `/sys/power/wake_lock` 是否同样有效 | ❌ 同上（这条值得一验，11 和 12 的 suspend 实现不同）|
| 19.2 MHz 设备的换算验证 | ❌ 手上没有这类设备 |


### 13.33 ★★★ vivo 交叉验证完成：跨设备一致，P0-a 在两条线上都不触发

用户给了 vivo 的 SSH 密码（`y76s`，用户 `u0_a343`）。这解开了 13.32 的阻塞。

#### 一、vivo 的环境特点（和 PDYT20 不同，反而更省事）

| | OPPO PDYT20 | vivo V2156FA |
|---|---|---|
| SoC / Android | mt6853 / 12 | MT6833V/ZA / 11 |
| root | ✅ Magisk（`a72`） | ❌ 无 |
| `/sys/power/wake_lock` | 可写（root） | 不可写（Permission denied，即使 adb shell） |
| Termux SSH | ✅ 8022 | ✅ **8022（`y76s`）** |
| 时钟连续性 | 需内核 blocker | **天然连续**（USB 常亮，实测 `dsusp=0.00s`） |

vivo 的 `stay_on_while_plugged_in` 已经是 `7`（插电常亮），所以
**不需要 root、不需要 suspend blocker，时钟就连续**：

```
dM=20.00s  dB=20.00s  dsusp=0.00s  → 时钟连续
累计 suspend = 162957s (45.27h)     ← 历史上的，但当前窗口是 0
```

#### 二、QEMU 二进制可以直接 `adb push` 到 `/data/local/tmp` 跑

之前以为需要 Termux 的 libc++，实测**不需要**：

```
INTERP = /system/bin/linker64
NEEDED = libz.so, libm.so, libdl.so, libc.so     ← 全是 Android 系统库
```

所以 vivo 上不需要 Termux 环境，`adb push` + `chmod 755` 就能跑。
（`qemu-img` 没有，overlay 退化成整份复制，vivo 有 113 GB 空闲，无影响。）

#### 三、2×2 交叉矩阵（首次拿到干净数据）

**无盘 → UEFI Shell**（`vboot.sh` / `pboot.sh`，各自跑 3–4 轮）：

| 设备 | q-p0a（含 epoch 修复） | b-old（未修复） |
|---|---|---|
| PDYT20 | 14.3 / 14.2 / 14.6 s | 14.6 / 14.6 / 14.7 s |
| **vivo** | **13.4 / 13.5 / 13.5 / 13.5 s** | **13.4 / 13.6 / 13.5 / 13.6 s** |

**两个二进制在每台设备上时间相同（±0.3s），两台设备之间差 1 秒左右。**

**带盘 → Linux**（`vdisk.sh`，vivo）：

```
kernel@13.6s   userspace@25.3s   lines=617   bds=2   linux=1
```

对照 PDYT20 用 `diskrun.sh` 跑到 cloud-init 的 591 行 —— 同一镜像、
同一二进制，vivo 617 行、PDYT20 591 行，**量级一致**。

#### 四、这个矩阵回答了三件事

**1. doze 的伤害有多大**

| 条件 | PDYT20 到 Shell |
|---|---|
| 无任何锁（13.25） | 360 s 只到 12 行 |
| `termux-wake-lock`（13.30） | 停在 12 行，sidecar 只采 1 行 |
| **内核 suspend blocker（本轮）** | **14.3 s** |
| vivo USB 常亮（本轮） | 13.5 s |

**同一个 QEMU、同一个镜像：14 秒 vs 永远到不了。** 之前所有"慢"的读数都是这个差。

**2. P0-a 在两条独立线上都不触发**

- PDYT20（mt6853/A12，root，内核锁）：q-p0a 14.3s / b-old 14.6s
- vivo（mt6833/A11，无 root，常亮）：q-p0a 13.5s / b-old 13.5s

**两个不同 SoC、两个不同 Android 版本、两种不同的防 suspend 手段，
`q-p0a` 与 `b-old` 的行为都没有可分辨的差异。**

所以 13.28 的 epoch 修复：
- **逻辑正确**（复用槽位的代际混叠是客观路径）
- **但在当前场景下不是可观测的故障**

我不宣布"P0-a 已修"。要验证它需要能稳定让 QEMU 换掉 host 映射的场景。

**3. CNTFRQ 在两台设备上都是 13 MHz（13.32 已记录）**

vivo `MT6833V/ZA` 与 OPPO `mt6853` 都报 `13000000`，且实测速率 1:1 吻合
（ratio=1.0000）。**用户担心的 19.2 MHz 差异没有在这两台出现。**
但 `to24_mult` 里硬编码 `13e6` 仍是隐患 —— 换成 19.2 MHz 设备会差 1.475 倍。

#### 五、跨设备对比的工具（已固化）

| 脚本 | 用途 | 备注 |
|---|---|---|
| `work/probe/cntfrq/` | 读 `CNTFRQ_EL0` + 实测速率 | 静态链接，adb push 即可 |
| `/data/local/tmp/vboot.sh` | vivo：到 Shell 的墙钟时间，n 轮 | 用 `/proc/uptime`（adb shell 无 python3） |
| `~/h/pboot.sh` | PDYT20：同上 | 用 `python3`（Termux 读不了 `/proc/uptime`） |
| `/data/local/tmp/vdisk.sh` | vivo：带盘到 Linux 各阶段 | 测 kernel@ / userspace@ |

**这两个平台的计时手段必须不同**：vivo 的 adb shell 没有 python3
（`/proc/uptime` 可读），PDYT20 的 Termux 反过来（`/proc/uptime`
`Permission denied`，python3 可用）。写工具时要按平台选。


### 13.34 ★★★ P0-a 的三项欠账结清：RSS 无差异、diff 无信号、探针零命中

用户连续三次要求的三笔账，这轮一次做完。

#### 一、RSS 对比（数据在 sidecar 里躺了三轮）

| run | 起始 | 峰值 | 终值 | 增长 |
|---|---|---|---|---|
| p0a4（q-p0a，带盘） | 788,276 KB | 1,009,780 | **1,011,992** | +223,716 |
| old4（b-old，带盘） | 783,756 KB | 1,007,420 | **1,010,936** | +223,664 |

**终值差 1,056 KB（0.10%）。** 两条曲线形状一致：
先涨 ~220 MB（guest 页表 + 内核镜像占用），然后趋平。

**leak 维度结案：没有可观测的 RSS 差异。**

#### 二、44 行 diff（实际是 122 行，规范化后）

去掉了 kernel 时间戳 `[ 225.650072]` 与 cloud-init 的 wall 时间后：

| 类别 | 行数 | 性质 |
|---|---|---|
| `cloud-init ci-info` 表格（PID / 网卡表） | 24 | 非确定性 |
| `cloud-init` metadata 超时重试 | 12 | 非确定性（网络） |
| `apparmor DENIED dhclient exec /usr/bin/true` | 8 | cloud-init 正常行为 |
| `rtc-efi setting system clock` | 2 | 时间不同 |
| 模块加载顺序（`fuse` / `loop`） | 4 | systemd 并行顺序 |
| systemd 单元完成顺序 | 若干 | 并行顺序 |
| 耗时数字（`160ms` vs `164ms`） | 若干 | 抖动 |

**`segfault|panic|oops|kernel BUG|unable to handle|general protection` 命中 0 次。**

里程碑完全一致：`bds=2 boot=2 linux=1 systemd=79/78 reach=20`。

**diff 结案：没有任何结构性差异。**

#### 三、P0-a 的原 reproducer（挖到了）

在 `QEMU-BACKEND.md:1700` 找到当初的现场：

```
henge: VIOLATION del_ram flushed ACTIVE cpu 0 (hit 168 of 341)
Shell>                                    ← 照样起来了
```

**341 次 romd toggle，168 次命中一个正在跑的 vCPU（49%）。**
机制：`pflash_write()` 每次 CFI 命令序列都 `set_romd()`，
每次切换是一次 `region_del` + `region_add`。

**这就是 P0-a 的 reproducer 形态：单轮带盘 boot 里 romd toggle 341 次，
即 341 次槽位复用机会。** 不需要跨 boot 序列 —— 单轮就够。

（这也纠正了用户的假设：跨 reset 序列不是唯一形态，
单轮 boot 里 romd 已经把槽位反复回收了几百次。）

#### 四、加了直接判据探针，实测零命中

新增三个计数器（`machine.h` 的 `HvStats`）：

| 计数器 | 含义 |
|---|---|
| `ram_reuse` | `add_ram` 复用退役槽位的次数（= 混叠机会数） |
| `epoch_stale` | 某个 block 因 `ram_epoch != ram->epoch` 被判失效的次数 |
| `epoch_high_water` | 见过的最老/最新 epoch 差 |

`epoch_stale` 加在**主查找路径** `hv_block_find()`（`machine.h:358`）里 ——
这是 `lookup()` 两次都会走的地方，而不是我最初加的两个次要位置。

带盘 boot 跑 140 秒（`bds=2 linux=1 lines=585`）：

```
=== P0-a STALE 探针 ===
（空 = 主查找路径上也没有混叠）
```

**一次都没命中。**

#### 五、为什么零命中 —— 13.28 的假设错了

`hv_block_find` 的匹配条件是：

```c
if (b->va == va && b->pa == pa && b->flags == flags && b->gen == gen) return b;
```

其中 `gen` 是新 region 的 `page_gen[pg]`，`del` 后 `add` 后是 **0**。
混叠要成立，必须 `b->gen == 0`，即**旧 block 生于该页的第一次翻译、
且该页从未被写过**。

而 `page_gen[pg]` 唯一的递增点是 `hv_invalidate_code()`（`machine.c:365`）：

```c
r->code_pages[pg] = 0;
__atomic_add_fetch(&r->page_gen[pg], 1, __ATOMIC_SEQ_CST);
```

**pflash varstore 是写频繁的**：每次 CFI 命令写都写它，每次写都让
`page_gen[pg]` 递增。所以旧 block 的 `b->gen` 早就不是 0 了。

```
旧 block b->gen = 5（该页被写过 5 次）
新 region page_gen = 0（全新 calloc）
5 == 0 不成立 → 不命中 → 我的 epoch 检查根本不会被走到
```

**所以 13.28 那条"复用槽位的 page_gen 归零与旧 gen==0 混叠"的路径，
在 pflash 这种写频繁的 region 上不成立。** 它需要的是一个
**只读、且从未被写过、却被 del+add 的 RAM region**。

#### 六、诚实的最终账目

| 项 | 结论 |
|---|---|
| RSS / leak 维度 | ✅ 无差异（0.10%），结案 |
| serial diff | ✅ 无结构性差异，结案 |
| P0-a 原 reproducer | ✅ 找到了：单轮带盘 boot，romd toggle 341 次 |
| P0-a 探针（主路径） | ✅ 已加，**实测 0 次命中** |
| 13.28 假设 | ❌ **经实测否定**（paged 写频繁时 gen 不归零） |
| epoch 修复 | ⚠️ 逻辑无害，但**没有修复任何可观测的 bug** |

**"P0-a 已修"不能宣布，而且现在连"P0-a 存在"都缺乏证据。**
原来的 VIOLATION 探针测的是"del_ram 时 CPU 正在跑"（并发风险），
那是另一条线，和代际混叠不是同一个东西。

要重新审视的问题：**当初定位 P0-a 为 SIGSEGV 级，依据是哪个现场？**
如果依据是 `MEASURE.md:1536` 那条 `fatal signal 11 [inside JIT]`，
那它是 **linmap 实验**的产物（`cmp` 污染 NZCV / `tbnz` 编码截断），
与 ROM 槽位复用无关 —— 而那三条已经修掉了。

这是本轮最该记住的一条：**探针位置错了会给出干净的假阴性。**
第一次把 `epoch_stale` 加在两个次要检查点，跑出 0，
我差点又写"P0-a 不触发"；直到把它加到 `hv_block_find()`（主路径）
才确认 0 是真实的 —— 但原因不是"没机会"，而是"前提不成立"。

---

### 13.35 ★★★ 13.34 的"零命中"是空判据：出口没打开。真数字是 del 704 / 复用 4 / 退役窗口 0

这一节否定的不是我上一轮的结论，是**我上一轮的证据本身**。

#### 一、三个出口全都关着，命中也不会出声

13.34 写"带盘 boot 跑 140 秒（`bds=2 linux=1 lines=585`）……（空）……一次都没命中"。
去翻那轮的日志 `/data/local/tmp/vd.log`：

```
$ grep -c "P0-a"        vd.log   → 0
$ grep -c "^stats "     vd.log   → 0
$ grep -c "henge-p0a"   vd.log   → 0
```

三个计数器一个都没被读出来。原因有三层，每一层都足够单独造成这个结果：

| # | 出口 | 为什么关着 |
|---|---|---|
| 1 | 逐条命中打印 | 套了 `if (getenv("HV_P0A_STATS"))`，而 `HV_P0A_STATS` 在脚本、文档、设备环境里**一次都没设置过** |
| 2 | 聚合行 `P0-a: ram_reuse ...` | 写在 `print_stats()` 里，而它由 `m->stats_interval` 门控；这个字段是独立 runner 的 `--stats` 选项，**移植层从来没有给它赋过值** |
| 3 | QEMU 的 stderr | vivo 上的 `vdisk.sh` 是 `>/dev/null 2>&1`，探针输出直接进黑洞 |

第 2 条还有个更坏的后果：`mmu.c` / `translate.c` 里**有一整类计数器只在
`m->stats_interval != 0` 时才递增**（`tlb_range_flushes`、`kernel_ranges`、
`protect_kind`、`race_kind`、`chained_early`）。移植层既然从没设过这个字段，
那些数字在这个加速器上**从第一天起就结构性恒为 0**。
"日志里没有那行"被当成了"那件事没发生"——这是第五次同类错误，
前四次都是探针位置错，这次是探针位置对了、出口没接。

#### 二、修法：让出口不经过任何开关

| 改动 | 文件 | 说明 |
|---|---|---|
| 计数器每 64 次 `del_ram` 无条件打一行 | `henge-engine.c` | 不经过 getenv，不经过 `print_stats` |
| 逐条命中打印去掉 `getenv` | `dispatch.c` | 命中本身就是稀有事件，前 20 次全打 |
| `hv_engine_set_stats_interval()` + `HV_STATS=<秒>` | `henge-engine.c` / `henge-accel.c` | 让引擎的周期统计（含 block-hash 的 stale 块判据）真能开 |
| `p0run.sh` | 新脚本 | stderr 落盘 + 每 5 秒采样 + dsusp 门控 + `trap EXIT` |
| `vclk.c` | 新工具 | 静态 arm64，一次调用打 `mono_ms boot_ms rss_kb` |

`vclk` 是必需的：设备上没有 python3 时，`/proc/uptime` 是 BOOTTIME（含 suspend），
`date +%s.%N` 是 REALTIME（会被 NTP 跳），**两个都不是 MONOTONIC**。
判 suspend 污染要的是 `dsusp = ΔBOOTTIME − ΔMONOTONIC`，两个钟都得是真钟。

#### 三、实测：vivo V2156FA，带盘 boot 到 Linux，五轮

| 轮 | 二进制 | lines | bds/linux/systemd | dsusp | RSS 峰 / 终 (KB) |
|---|---|---|---|---|---|
| p1 | q-p0a2（首批出口） | 587 | 2/1/77 | 1 ms | 1,020,756 / 1,014,256 |
| p2 | q-p0a3（+REUSE 探针） | 585 | 2/1/75 | 1 ms | 1,023,768 / 1,017,764 |
| p3 | q-p0a4（+del_hit/miss） | 586 | 2/1/76 | 1 ms | 1,024,040 / 1,016,616 |
| p4 | q-p0a5（+live_blocks） | 587 | 2/1/76 | 0 ms | 1,031,236 / 1,024,744 |
| p5 | q-p0a6（+retired_hit） | 588 | 2/1/77 | 1 ms | 1,021,192 / 1,015,052 |
| p6 | q-p0a7（+del 递增 epoch） | 589 | 2/1/79 | 0 ms | 1,029,552 / 1,022,992 |

六轮全部 `dsusp ≤ 1 ms`，六轮全部走到 Linux + systemd。**没有一轮是脏数据。**

#### 四、数字推翻了 13.34 的"341 次复用机会"，差两个数量级

```
henge-p0a: del#704 defer=1 del_hit=5 del_miss=698 ram_reuse=4
                              epoch_stale=0 retired_hit=0 hw=0 nram=3
```

| 量 | 13.34 的写法 | 实测 |
|---|---|---|
| `del_ram` 调用次数 | "341 次 romd toggle" | **704** |
| 真正命中镜像窗口（`rc==0`） | 隐含 341 | **5** |
| 没命中（`rc==-1`） | 未提 | **698** |
| 真正复用退役槽位 | "341 次槽位复用机会" | **4** |

**704 次里只有 5 次命中。** 因为 romd 窗口进过命令模式之后就被
`nomirror[]` 拉黑了，此后每次 toggle 只产生 `region_del`，
而引擎这边**早就没有任何东西可以退役**——`del_miss` 就是这 698 次的计数器。
13.34 把"`del_ram` 被调了 341 次"直接读成了"341 次复用机会"，
中间少了"命中镜像窗口"和"槽位真的被复用"两道闸门。

#### 五、四次复用全部 `live_blocks=0`：这才是"P0-a 不存在"的直接证据

```
REUSE #1 slot=0 pa=0        size=4000000 readonly=1 old_epoch=1 -> 2 live_blocks=0
REUSE #2 slot=1 pa=4000000  size=4000000 readonly=1 old_epoch=1 -> 2 live_blocks=0
REUSE #3 slot=2 pa=40000000 size=80000000 readonly=0 old_epoch=1 -> 2 live_blocks=0
REUSE #4 slot=1 pa=10000000 size=40000  readonly=0 old_epoch=2 -> 3 live_blocks=0
```

`live_blocks` 是**复用发生的那一刻**，扫全表数出 `b->ram == r` 的 block 数。

**四次全是 0。** 也就是说：槽位被回收时，没有任何一个已翻译的 block 还挂在它上面。
没有悬空 block，就不存在"跳进按已消失 host 内存翻译出来的代码"这回事——
13.28 描述的那条路径缺的不是概率，是**前提**。

这四次还全在 UEFI 极早期（`del#320` 之前），那时 guest 只翻译了寥寥几页，
所以 `live_blocks=0` 是必然而不是巧合。

#### 六、13.28 的假设可以正式结案：三个独立理由

| # | 理由 | 判据 |
|---|---|---|
| 1 | 复用时机 | 4 次全在启动早期，`live_blocks=0` |
| 2 | 复用次数 | 不是 341，是 4；`del_hit` 只有 5 |
| 3 | `gen` 归零撞不上 | 混叠要 `b->gen == 0`，而 pflash varstore 的 `page_gen` 早被 `hv_invalidate_code` 抬过（13.34 已论证） |

**所以"P0-a 已修"不能宣布，因为 P0-a 作为"代际混叠"从未被证明存在过。**
`epoch` 那套机制逻辑正确、代价可忽略，但它防护的是一个没被观测到的场景。

#### 七、但顺带发现了一个真的洞：`del_ram` 不递增 epoch

这一条是加 `retired_hit` 判据时才显形的，比 13.28 简单得多，也更硬。

`epoch` 原来**只在 `add_ram()` 里 `++`**。于是退役窗口（`del_ram` 已执行、
`add_ram` 还没来）里：

```c
/* dispatch.c 快路径 */
if (c && c->pa == pa && c->flags == flags && c->ram_epoch == c->ram->epoch &&
    c->ram->page_gen[c->pg] == c->gen) return c;
```

- `c->pa` / `c->flags`：还是旧值，全中
- `c->ram_epoch == c->ram->epoch`：**没有任何东西递增过，成立**
- `c->ram->page_gen[c->pg]`：`del_ram` 已经把 `page_gen` 置 NULL →
  **`NULL[c->pg]`，host 侧 SIGSEGV**

不是"读到错的 guest 内存"，是宿主进程直接死。修法是让 epoch 在
`del_ram` 退出时也 `++`：任何按这个窗口翻译过的 block 立刻 `ram_epoch` 失配，
在碰 `page_gen` 之前就被踢出去。已在 `q-p0a7` 落地并实测（p6）。

`retired_hit` 的实测值是 **0**——这个窗口在当前负载下没被踩到。
但它是**逻辑上一直开着的**，只是因为 `del_hit` 只有 5 次、且都发生在没有
block 可查的启动期，所以没机会踩。这是"修了一个真的洞，但它不是现在卡住的因"，
两句话都得说。

#### 八、P0-a 的定级依据：`MEASURE.md:1536` 站不住

那条 `fatal signal 11 [inside JIT]` 属于**第十轮 EL1 linear map**（`MEASURE.md:1491`
的章节标题），现场是 `tbnz` 判定"在区间内"后 `ldr` 装了个补码当 addend——
是 linmap emit 的三处编码 bug（`cmp` 污染 NZCV、`tbnz` 的 b40 位截断、
`addr == T` 自减成 0），而且在独立 `hv-linux` runner 里，与 QEMU 的 RAM 槽位无关。
那三条当时已修，该轮唯一失败项也留在 linmap 通道内，没有交付。

**把那条 SIGSEGV 当作 P0-a 的现场，是我的误挂。**
"del_ram 打在 ACTIVE vCPU 上"（`hit 168 of 341`）是另一条线——并发风险，
它有实证（`tlb_race.c` 0.42% 跨界、168/341 命中），也已经由延迟失效 + 引擎自己的 stw 修掉。

#### 九、诚实的最终账目

| 项 | 结论 |
|---|---|
| 13.34 的"零命中" | ❌ **判据是空的**（三个出口全关），不是结论错 |
| 重测后的 `epoch_stale` | 0（这次是真的 0） |
| `ram_reuse` | 4（不是 341），全部 `live_blocks=0` |
| 13.28 代际混叠假设 | ❌ **结案：前提不成立** |
| `del_ram` 不递增 epoch | ⚠️ **真洞**，已修（`q-p0a7`），实测未触发 |
| P0-a 定级依据 | ❌ 挂在 linmap 的现场上，不成立 |
| 并发线（del 打 ACTIVE vCPU） | ✅ 有实证，已由延迟失效修掉 |

#### 十、接下来该做的不是"验 P0-a"，是别的

`system_reset` 循环（`nrun` v2）仍然值得做，但理由变了：
不是"去触发 P0-a"（前提已证伪），而是**跨 boot 的回归探针**——
`del_hit` / `ram_reuse` / `retired_hit` 这三个数现在有了基线（5 / 4 / 0），
单进程连续 reset N 轮后这三个数应当线性增长、`retired_hit` 仍应为 0。
一旦哪轮 `retired_hit > 0`，那就是真的踩到了第七节那个洞。


---

### 13.36 收尾审计：q-p0a 的惰性修复按"同族合并"处置，stats_interval 两个延伸做完

13.35 之后有两笔账挂着：一段前提已死的代码还在正确性路径上，
一个"修对了但不可验证"的修复需要定性，以及 stats_interval 那个发现的两个延伸。

#### 一、审计 q-p0a 的 diff：结论是"同族合并"，不是"只留一行"

先把问题问准：**"只保留 del-epoch 一行"在技术上不成立。**
`del_ram_flags()` 在 `accel/henge/henge-engine.c`（移植层），
而 `epoch` 字段、它的登记点、它的全部读者都在 `engine/core/`。
递增没有读者就是死代码 —— 只留那一行，等于把漏洞的锁孔留下、把锁拆掉。

所以真问题是：**epoch 机制的哪些部分是 del-epoch 的必需件，哪些只是为
"代际混叠"这个故事写的散文。** 逐件清点：

| 位置 | 内容 | 判定 | 处置 |
|---|---|---|---|
| `machine.h` `HvRam.epoch` | 字段 | del-epoch 的载体 | 保留，注释重写 |
| `machine.h` `HvBlock.ram_epoch` | 字段 | 读者需要的记忆 | 保留 |
| `machine.c` `add_ram` | `r->epoch++` | 登记新占位者 | 保留，注释重写 |
| `henge-engine.c` `del_ram_flags` | `r->epoch++` | **核心修复** | 保留 |
| `dispatch.c` 快路径 | `ram_epoch == epoch` 且 `size != 0` | 读者 | 保留（`size` 是本轮新加的短路） |
| `dispatch.c` | `nb.ram_epoch = ram->epoch` | 登记点 | 保留 |
| `dispatch.c` hash 清理 | epoch 不符则摘链 | 防悬空留在表里 | 保留 |
| `dispatch.c` `chain()` | epoch 不符则不链 | 链到悬空更危险 | 保留（另加 `size` 判据） |
| `machine.h` `hv_block_find` | epoch 不符则返回 NULL | 主路径纵深防御 | 保留 |
| `machine.h` `HvStats` 注释 | "P0-a 的三个直接判据" | 死叙事 | **重写为 slot-identity 语义** |
| `dispatch.c` `print_stats` | `P0-a: ram_reuse ...` 行 | 死标签 | **改名 `slots:`，加 retired_hit** |
| `dispatch.c` 快路径 | `stale0` + `STALE-find` 打印 | **纯探针，死假设专属** | **删除** |
| `dispatch.c` `chain()` | `STALE-chain` 的 fprintf | 纯打印 | **删除**（计数保留） |
| `machine.c` `add_ram` | `live_blocks` 扫全表 + REUSE 打印 | **死假设专属，且在正确性路径上做全表扫描** | **删除** |

**净变化：`local-edits.patch` 809 → 784 行（-25）。**

被删的三处有一个共同点：它们**不改变任何行为**，只是"想办法看见混叠"。
`live_blocks` 那次甚至要遍历整张 block hash 表 —— 结论已经出了（4 次复用、
全部 0），继续把它挂在 `add_ram()` 上就是在正确性路径上为一个已死的假设付费。

另外做了一处**行为**收紧，而不是删除：快路径原来是

```c
if (c && c->pa == pa && c->flags == flags && c->ram_epoch == c->ram->epoch &&
    c->ram->page_gen[c->pg] == c->gen) return c;
```

现在多一道 `c->ram->size != 0`，排在 `page_gen` 之前：

```c
if (c && c->pa == pa && c->flags == flags && c->ram->size &&
    c->ram_epoch == c->ram->epoch && c->ram->page_gen[c->pg] == c->gen) return c;
```

上一版把"退役窗口"写成只计数、不改行为，这等于承认了 `NULL[pg]` 那条路
但不去堵。既然 `epoch` 和 `size` 是同一个不变式的两种说法，
就该两个都进短路链：`epoch` 管"换了占位者"，`size` 管"当前无人占"。

#### 二、del-epoch 的定性：by-construction 纵深防御，不是被验证的行为变化

必须写清楚，否则下一轮会有人把它当"已验证修复"引用：

| 问题 | 答案 |
|---|---|
| 修前修后行为有差异吗？ | **没有可观测差异**。`retired_hit` 在六个 boot 里都是 0 |
| 为什么不触发？ | 704 次 `del` 只有 5 次命中活着的窗口，且全在 `del#320` 之前 —— 那时 guest 还没翻译出 block |
| 那它是对的吗？ | **是，by construction**。退役窗口里快路径的其它条件全部成立，`page_gen` 已置 NULL，读它就是 `NULL[pg]` |
| 它的证据是什么？ | 代码路径的静态必然性，不是运行时计数 |
| 它什么时候会有证据？ | **只有 nrun v2 的 reset 序列**：单进程连续 reset 会让"有 block 存在时窗口退役"第一次成为可能 |

所以文档里的措辞统一为：**"纵深防御，正确性由构造保证，行为变化未被观测"**。
不写"已修复"，也不写"已验证"。

`retired_hit` 因此不是普通计数器，它是**这个修复唯一的指定观察者**。
nrun v2 的验收条件之一就是它全程为 0 —— 一旦 >0，说明序列形态真的踩到了。

#### 三、这是引擎 API 层的真洞，是第一笔该回馈上游的提交

`hv_machine_del_ram_flags()` 的语义是"退役这个窗口"，但它只释放
`code_pages/page_gen/whint`、清 `host/size`，**不动 `epoch`**。
`epoch` 只在 `hv_machine_add_ram()` 里递增。

上游为什么不炸：独立引擎只在 teardown 时删 RAM，那时没有 block 在飞。
移植层把这个 API 从"一次生命周期调一次"变成"每条 CFI 命令写调两次"
（704 次/boot），于是"退役窗口"从理论上的空集变成实际存在的一段。

这是一个**hosted caller 让引擎 API 隐患变得可达**的典型例子，
适合作为第一笔上游提交（不改语义，只补一个递增 + 一段注释）。
已在 `henge-engine.c` 的修复点标注，**不急，记着**。

#### 四、stats_interval 延伸一：赋上值，且把一个死字段复活

上一轮用 `HV_STATS=<秒>` 打开它，但那是"要的时候才开"。
这一轮改成**默认就开，只是打印间隔设成一小时**：

```c
const char *st = getenv("HV_STATS");
int secs = h->stats > 0 ? h->stats : (st ? atoi(st) : 3600);
hv_engine_set_stats_interval(h->m, secs);
```

为什么能用一小时的间隔同时满足"计数"和"不刷屏"：
`print_stats()` 的真打印条件是 `now - last_t >= stats_interval * 24MHz`，
而**计数**的条件只是 `stats_interval != 0`。所以一个大于任何 boot 时长的值
让所有计数器工作、一行日志都不多。

顺带发现 `HengeAccelState` 里有个**死字段**：

```c
uint64_t jit_mb;
bool     stats;      /* ← 声明了、初始化成 false、没有任何属性暴露、没有任何读者 */
```

这正是 13.7 那个"把我们的 `--stats` 挂到 `AccelClass.get_stats`"计划留下的残骸。
现在把它改成 `int stats`（秒），挂成 QOM 属性：

```
-accel henge,stats=5      # 每 5 秒一行 stats
```

优先级：`-accel ...,stats=N` > `HV_STATS=N` > 默认 3600。

**复活的计数器清单**（此前结构性恒 0，现在开始工作）：

| 计数器 | 位置 | 含义 |
|---|---|---|
| `tlb_range_flushes` / `range_spared` / `kernel_ranges` | `mmu.c` | 大范围 TLBI 的分流 |
| `protect_kind[3]` | `mmu.c` | 代码页保护时扫了多少 TLB 条目 |
| `race_kind[3]` | `mmu.c` | 远程 drop 的三种竞态 |
| `posted_kind[4]` | `mmu.c` | TLBI 投递给别的 CPU 的四类 |
| `chained_early` | `translate.c` | 链式退出提前落地 |
| `translate_ticks`、`wfi_ticks` | `dispatch.c` | 翻译/睡眠时间占比 |
| block-hash 的 `stale blocks` | `dispatch.c` | 垃圾 block 堆积 |

代价：`translate.c` 每次翻译多两次 `mach_absolute_time()`。
那是**翻译路径**不是执行路径，且独立 runner 一直付这个价。

#### 五、stats_interval 延伸二：历史文档审计 —— 干净，而且教训早就写在纸上

grep 范围：`MEASURE.md`、`QEMU-BACKEND.md`、`BENCH.md`、`KVM-VS-ENGINE.md`、
`BOOT-VS-TCG.md`、`CALL-PATH.md`、`LINMAP.md`、`FINDINGS.md`。

| 检查项 | 结果 |
|---|---|
| 恒 0 计数器名（`tlb_range_flushes` 等 5 个）在文档中的引用 | 11 处，**全部在 13.35 我自己写的那段里**（描述这个 bug 本身） |
| `[0-9]+\.[0-9]+M/s`、`[0-9]+K/s`、`blocks [0-9]` 这类引擎速率数字 | **0 命中** |
| 引用 `--stats` 的段落 | 9 处，全部在 `MEASURE.md` / `BOOT-VS-TCG.md`，主语是**独立 runner `hv-linux`** |

`MEASURE.md` 的数字来自 `hv-linux ... --stats`，那个 runner 设了 interval，
**所以那些数字有效，无污染。**

而更值得记的是这一条 —— `MEASURE.md:245`：

```
### 5.4 HV_SUM 不带 --stats 时所有分类计数器为 0
因为每个计数器都被 `if (m->stats_interval)` 门控。第一次跑出一排 0，白跑一轮。
```

**这个坑独立 runner 在几个月前就踩过、写下了、还标了"踩过"。**
移植层从第一天起就在同一个坑里，因为那条知识没有跨过 runner→port 这道边界。

这才是 13.34 那个错误的完整解释：不是没人知道，是**知道的地方不是发生的地方**。
所以修法不能只是"这次接上了"，得让它**结构上不可能再断**：

- 计数器递增不再依赖调用方设值（默认 3600，任何调用方都拿到非零）
- `hv_engine_set_stats_interval()` 的注释里写明"传 0 = 停止计数，不是静音"
- `p0run.sh` 加仪器自检（下一节）

#### 六、第六次同类错误：改标签忘改脚本 —— 这次是脚本自己抓到的

清理时把探针的前缀从 `henge-p0a:` 改成 `henge:`（因为 P0-a 这个名字已经不该
再出现），结果 `p0run.sh` 里写死的 `grep -ac 'henge-p0a: del#'` 抓不到任何东西，
输出 `del_probe_lines=0`。

**探针明明打了 11 行。** 这是本轮的第 6 次仪器类错误，形态是新的（前五次是
位置/出口，这次是**读端与写端的字符串耦合**）。

处置不是"这次改对了"，而是让脚本不可能再被这种耦合骗到：

```sh
# 不写死标签前缀，只匹配探针自身的形状
RETIRED=$(grep -ac 'RETIRED-window' "$ERR")
DELS=$(grep -ac 'del#[0-9]' "$ERR")

# 仪器自检：guest 都跑到 systemd 了，del 探针却一行没有
# —— 那不是"没发生"，是出口断了。
if [ "$LINES" -gt 100 ] && [ "$DELS" -eq 0 ]; then
    echo "INSTRUMENT-DEAD: ..." >&2; INSTR=DEAD
fi
```

（第一次写还写成了 `'henge.: del#'` —— `.` 只匹配一个字符，`henge` 加 `.` 之后
又要求一个冒号，永远不匹配。被 p7 的日志当场打回。）

**四关纪律补第五关：** 位置在主路径、出口无门控、stderr 可达、判据非空
—— 再加**读端不耦合写端的标签**。前三关防"没数到"，第四关防"数了没处去"，
第五关防"数了也读了但读错行"。

#### 七、回归验证

`q-p0a8`（清理 + stats 默认开启 + QOM 属性）单轮带盘 boot：

```
TAG=p7  lines=586  bds=2 linux=1 systemd=76
dsusp_cum_ms=1  verdict=VALID
del#704 defer=1 del_hit=5 del_miss=698 ram_reuse=4 retired_hit=0 epoch_stale=0 hw=0 nram=3
```

与 `p6`（清理前）**逐项一致**：`del_hit=5 / del_miss=698 / ram_reuse=4 /
retired_hit=0 / epoch_stale=0`。删掉的是探针，不是信息；
加上的是"退役窗口在快路径上被短路"这一条行为。

#### 八、这一节的账

| 项 | 结论 |
|---|---|
| q-p0a 惰性代码 | ✅ 审计完：**同族合并**，净 -25 行，删的是纯探针，留的是 del-epoch 的读者 |
| del-epoch 定性 | ✅ **by-construction 纵深防御**，行为变化未被观测，唯一观察者是 `retired_hit` |
| 上游回馈 | 📌 记为第一笔候选，不急 |
| stats_interval | ✅ 默认 3600（计数开、打印关）；死字段 `stats` 复活为 QOM 属性 |
| 历史文档 | ✅ **无污染**（数字全来自设了 interval 的独立 runner） |
| 知识未跨边界 | ⚠️ `MEASURE.md:245` 早有同样教训 —— 修法是不让它能再断 |
| 第六次仪器错误 | ✅ 已由脚本自检兜住，纪律补第五关 |


---

### 13.37 nrun v2 建成：8 轮单进程 reset 全通，但序列形态反而**降低**了槽位复用机会

排期第 2 项。基础设施 + 第一个只有序列能看到的信号。

#### 一、通道设计：monitor 的 `system_reset`，不是 guest 内 `reboot`

```
-monitor tcp:127.0.0.1:4455,server,nowait   →   nc 127.0.0.1 4455  →  system_reset
```

不用 guest 内 `reboot`：那要先能登录，而登录本身是 C6（重启丢网）的受害者。
用 monitor 就把"复位"这个动作放在 host 侧，guest 状态完全不影响它。

三个里程碑，成本差一个数量级，决定这个测试能回答什么问题：

| milestone | 判据 | 每轮耗时 | 用来测 |
|---|---|---|---|
| `bds` | `BdsDxe: starting` | ~6 s | UEFI 阶段的槽位语义 |
| `linux` | `Linux version` | **~14 s** | 内核早期、`retired_hit`、多核弱序 |
| `systemd` | `systemd[1]` | ~110 s | **C6（重启丢网）必须用它** |

`linux` 只要 14 秒是个意外的好消息：`UEFI → GRUB → 内核` 很快，
之前记的"130 秒到 userspace"里绝大部分是 systemd 及其单元。

#### 二、8 轮实测（vivo V2156FA，q-p0a8，smp2，linux 里程碑）

```
轮数=8 成功到 linux=8/8        serial lines=2062
dsusp_cum_ms=1  verdict=VALID   ← 108 秒里只睡了 1ms，序列没有 doze 污染
retired_hit(总)=0               ← del-epoch 仍未触发
epoch_stale=0  hw=0  nram=3
末次: del#2048 del_hit=12 del_miss=2035 ram_reuse=4
```

**8/8 全过，`retired_hit` ≡ 0。** del-epoch 那个洞在 8 轮序列里依然没被踩到 ——
与 13.36 的定性一致（by-construction 纵深防御，行为变化未被观测）。

#### 三、★ 序列形态**降低**了槽位复用机会 —— 这一条修正了之前的判断

逐轮的 `ram_reuse` 与 `del_hit`：

| 轮 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| `del_hit` | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 |
| `ram_reuse` | **4** | **4** | **4** | **4** | **4** | **4** | **4** | **4** |

`del_hit` 每轮 +1，`ram_reuse` **从第 2 轮起一动不动**。

原因是 `nomirror[]` 活在 `HengeAccelState` 里，**不随 guest reset 清空**：

```c
/* henge-accel.c */
struct { hwaddr pa; uint64_t size; } nomirror[8];
int      nnomirror;
```

第 1 轮里 romd 变量存储进过命令模式 → 被拉黑。`system_reset` 只重置 guest，
不动这个加速器状态 → **第 2 轮一开始这个窗口就在 never-mirror 列表上**，
`add_ram` 永远不再镜像它，因此**永远不再产生一次槽位复用**。

结论，而且方向和之前的假设相反：

> **跨 boot 序列不是 P0-a 的可观测形态 —— 它让 P0-a 的机会消失了。**
> 单轮冷启动（`ram_reuse=4`）才是机会最多的形态；
> 序列里这个数字冻结在第 1 轮的值，之后每轮只有 `del_hit` 在涨、
> 全打在从不镜像的窗口上（`del_miss` 也同步涨）。

13.34 写"单轮带盘 boot 就够，不需跨 boot 序列"是对的，
但理由当时给错了（说"单轮已 341 次复用"）。真实理由是：
**序列会让复用机会归零。** 而且这也解释了为什么 `retired_hit` 在序列里
更不可能触发 —— 没有复用，就没有"退役后又被占用"的窗口。

这条要记进纪律：**"加长/加轮数"不总是提高暴露概率**，
如果被测机制依赖某个 per-accelerator 的持久状态，跨 reset 反而会把它冻结。

#### 四、★ RSS 单调上涨：单 boot 测不到的那个问题，出现了

同相位对比（每轮都是"到 `Linux version` 那一刻"）：

| 轮 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|
| RSS (KB) | 432,860 | 437,372 | 447,676 | 450,304 | 484,836 | 495,592 | 496,216 | **501,840** |

**+68,980 KB（+67 MB，+15.9%）/ 8 轮**，单调上涨，没有平台期。

而 13.34 的单 boot 数据是"涨 ~220MB 后趋平"——**趋平是单 boot 的假象**。
两个数据合起来才完整：

- 单 boot 内：`788MB → 1,012MB` 后趋平（guest 页表 + 内核镜像工作集）
- 跨 reset：每轮在同一里程碑处比上一轮高 **4.5–10 MB**

这正是"单 boot 的 RSS 平台期不能外推到多 reset"的实证。
**但不能就此宣布泄漏** —— 目前只知道它跨轮累积，还不知道在哪一层：

| 假设 | 怎么判 |
|---|---|
| QEMU 侧 flatview / dirty bitmap / MemoryRegion 累积 | `-accel henge,stats=5` 看 `blocks held` 是否随轮增长 |
| JIT 侧 block 元数据 | `HvBlock` 数组是 `max_blocks` 固定，若增长只能是指针/链表 |
| ROM blob 重复注册（GRUB 每轮加载一次） | 数 `henge: region ...` trace 的 rom 行 |
| 磁盘 overlay 的 block 层 cache | 换 `-drive cache=none` 对照 |

第 5 轮那个 +34MB 的跳变（明显高于前后）说明增长不是均匀的，
更像是某种"达到阈值才分配"的结构，而不是每轮固定泄漏。

**这一项不结案，作为排期第 5 项（soak）与第 6 项（重定价）的输入。**

#### 五、三个脚本 bug（都在第一次运行时暴露）

| bug | 现象 | 原因 |
|---|---|---|
| `set -- $($H/vclk $QP)` 覆盖 `$1` | tsv 第一列变成 mono_ms，`round1` 的 RSS 取不到 | 函数参数被位置参数覆盖；先存 `RW=$1` |
| `$($1)` 不重新解析引号 | 每轮报 `timeout`，而 tsv 里 `linux_n` 明明是 1 | `wait_until "cnt 'Linux version'"` 把 `'Linux`/`version'` 当字面参数传给 grep；改成专用 `wait_mile` |
| `grep -c` 零命中时输出 `0` **且** 返回 1 | `cnt()` 返回两行 `0`，`-ge` 比较炸掉 | 不能写 `grep -c ... \|\| echo 0`，要先接住再 `${n:-0}` |

第三条是 `set -e`/`||` 组合的经典陷阱，值得单独记：
**`grep -c` 的"0 行"是通过退出码 1 表达的，同时它已经打印了 `0`**，
所以任何 `|| echo 0` 的兜底都会变成两行输出。

#### 六、这一节之后，梯子搭好了

| 能力 | 状态 |
|---|---|
| 单进程连续 reset | ✅ `nrun2.sh`，`linux` 里程碑 14 s/轮 |
| 序列形态的 RSS 曲线 | ✅ 同相位采样，已抓到 +69MB/8 轮 |
| 序列形态的全计数器 | ✅ `HV_STATS` 每轮一组，`del_hit`/`ram_reuse`/`retired_hit` 全程可读 |
| doze 门控 | ✅ `dsusp` 全程 ≤1ms（108 秒） |
| 三个里程碑的取舍 | ✅ `bds` / `linux` / `systemd`，成本写进用法 |
| C6 复现 | ⬜ 下一步：`systemd` 里程碑 + 每轮数 DHCP |
| 多核弱序（C2/C3/C5） | ⬜ 下一步：`smp=4` + `linux` 里程碑 |
| soak | ⬜ `linux` 里程碑下 14 s/轮，过夜可跑几千轮 |

