# henge 与 QEMU 接缝的结构性分析

> 结论：问题不在"缺什么功能"，而在**所有权结构**。
> henge 被嫁接进 QEMU 当 accel 时，**GIC 在 QEMU、投递在引擎**，
> 而 ARM 的 `CPU_INTERRUPT_HARD` 设计隐含"GIC 与投递者能同步操作同一个 CPUState"这一前提。
> 这个前提在嫁接后不成立，于是同一个电平在两侧各有一份，靠 5 个点位显式拷贝弥合。

实测日期：2026-11-19
对照对象：TCG / KVM / henge(嫁接) / henge(AppleVM 独立)

---

## 一、所有权矩阵

| 资源 | TCG | KVM/ARM | henge 嫁接（本工程） | henge 独立（AppleVM） |
|---|---|---|---|---|
| 指令翻译 | TCG | 硬件(客机) | **引擎** | **引擎** |
| MMU / TLB | TCG softmmu | 硬件 | **引擎** | **引擎** |
| GIC | **QEMU** | **内核** | **QEMU** | **引擎** |
| PCI / ECAM | QEMU | QEMU | **QEMU** | **引擎** |
| virtio-blk | QEMU | QEMU | **QEMU** | **引擎** |
| virtio-gpu / xhci / ACPI | QEMU | QEMU | **QEMU** | **引擎** |
| 中断投递 | QEMU(`cpu_exec_interrupt`) | 内核 | **引擎**(`hv_check_interrupts`) | **引擎** |
| 中断电平 | 1 份(`env->irq_line_state`) | 内核(用户态无副本) | **2 份**(QEMU + `HvPerCpu.irq_line`) | 1 份(`HvPerCpu.irq_line`) |
| 睡眠/唤醒 | QEMU(`halt_cond`) | 内核 | **2 套**(引擎 `park` + QEMU `halt_cond`) | 引擎(`park`) |

**关键读数**：只有「henge 嫁接」这一列出现"跨栈双份"。其余三者都是单一所有者。

---

## 二、结构性差异（不是能力差异）

### TCG 的结构
```
设备 ──qemu_set_irq──► QEMU GIC ──arm_cpu_set_irq──► env->irq_line_state
                                                          │
                                          cpu_exec 每 TB 边界
                                                          ▼
                                        cpu_handle_interrupt → arm_cpu_exec_interrupt
                                                          │
                                          do_interrupt（投递）
```
- 投递与电平在**同一线程、同一事件循环**内
- `arm_cpu_set_irq(level=0)` 由 GIC 下降沿驱动，**同步**清位
- `has_work()` 的假设成立：HARD=1 ⟺ 真有中断待交付

### KVM/ARM 的结构
```
设备 ──qemu_set_irq──► KVM_IRQ_LINE ioctl ──► 内核 VGIC ──► 硬件注入
                    └──► arm_cpu_set_irq（影子，仅用于 kick）
```
- **用户态没有电平副本**（`kvm-all.c` 里 `interrupt_request` 零命中）
- `kvm_arch_pre_run()` 根本不碰中断（`target/arm/kvm.c:1334` 只处理 ext_dabt）
- `has_work()` 在 KVM 下不承担正确性责任——中断由内核注入

### henge 嫁接的结构
```
设备(QEMU) ──qemu_set_irq──► QEMU GIC ──arm_cpu_set_irq──► env->irq_line_state
                                                              │
                                              henge_sync_irq（仅 5 个点位！）
                                                              ▼
                                             HvPerCpu.irq_line ──► hv_check_interrupts
                                                                        │
                                                              引擎内投递（投递后不清 HARD）
```
- **电平有两份**，靠 `henge_sync_irq()` 拷贝
- **投递绕过了 QEMU 的 `do_interrupt`**，所以 `arm_cpu_exec_interrupt` 永不运行
- 而 ARM 的 `HARD` **本来就不在投递函数里清**（见下节），它依赖 GIC 下降沿
- 于是"GIC 下降沿 → 清位 → 同步给引擎"这条链**每一次都必须显式走一遍**

---

## 三、ARM 的特殊性（决定性证据）

全树统计「在投递函数里清 `CPU_INTERRUPT_HARD`」的次数：

| 架构/后端 | 次数 | 位置 |
|---|---|---|
| SPARC | 1 | `int32_helper.c:98` |
| LoongArch | 1 | `cpu.c:72` |
| HPPA | 1 | `int_helper.c:35` |
| i386 / KVM | 1 | `kvm.c:5958` |
| i386 / WHPX | 2 | `whpx-all.c:2033,2051` |
| i386 / HVF | 1 | `x86hvf.c:412` |
| **ARM** | **0** | — |

ARM 是**唯一**不在投递函数里清 `HARD` 的架构。

原因（`target/arm/cpu.c:834-857`）：
```c
if (level) {
    env->irq_line_state |= mask[irq];
} else {
    env->irq_line_state &= ~mask[irq];
}
...
if (level) cpu_interrupt(cs, mask[irq]);
else      cpu_reset_interrupt(cs, mask[irq]);
```

`HARD` 的**唯一清零点就是 `arm_cpu_set_irq(level=0)`**，即 GIC 拉低线的那一刻。
这与「GIC 保持线高直到 guest ack」的 ARM 语义一致。

**推论**：ARM 的这套设计隐含前提是「GIC 与投递者能直接、同步地操作同一个 `CPUState`」。
- TCG 满足（同线程）
- KVM 不需要（内核负责）
- **henge 嫁接不满足**（跨栈，且投递者不看 `CPUState`）

---

## 四、与 QEMU accel 接缝的清单

`AccelCPUClass` 只有 3 个钩子（`include/accel/accel-cpu.h`），真正的契约分散在三处：
`CPUClass`、`SysemuCPUOps`、以及**未被接口化但被隐含依赖**的约定。

### A. 已被接口化、henge 已履行的

| 契约 | 接口 | henge 实现 | 评价 |
|---|---|---|---|
| CPU 类改写 | `AccelCPUClass.cpu_class_init` | 有 | 合规 |
| 实例初始化 | `.cpu_instance_init` | 有 | 合规 |
| 目标校验 | `.cpu_target_realize` | 有（拒绝非 aarch64） | 合规 |
| 状态回写 | `cpu_synchronize_state` | 有（`hv_engine_save_state`） | 合规 |
| 寄存器读写 | `get_pc`/`set_pc`/`memory_rw_debug` | 复用 ARM 默认 | 合规 |
| 迁移 | `legacy_vmsd` | **主动拒绝迁移** | 明确不合规（有意） |

### B. 已被接口化、henge 语义偏离的

| 契约 | 接口 | TCG/KVM 语义 | henge 实际 | 后果 |
|---|---|---|---|---|
| `has_work` | `SysemuCPUOps.has_work` | HARD=1 ⟺ 有中断待交付 | 同样代码，但 HARD 可能陈旧 | **`cpu_thread_is_idle()` 误判，永不停 park** |
| `cpu_exec` | `CPUClass.cpu_exec` | 返回 `EXCP_HALTED` 交还宿主 | 引擎内自睡（`return 0`） | 宿主 park 机制被旁路 |
| kick | `CPUState.kick` | 保证能打断执行 | `exit_req` 只表示"让另一核" | 用 `halted` 冒充返回宿主 |

### C. 未被接口化、但被隐含依赖的（真正的裂缝）

这些不在任何 QEMU 接口里，但 ARM/TCG/KVM 的实现都默认它们成立：

| 隐含约定 | TCG/KVM 如何满足 | henge 嫁接 | 状态 |
|---|---|---|---|
| `arm_cpu_set_irq(level)` 是 `HARD` 的唯一所有者 | 天然满足 | GIC 在 QEMU，但投递在引擎 → 需要显式 sync | **5 个点位显式拷贝** |
| GIC 下降沿能立刻被投递者看到 | 同线程 | 需 `henge_sync_irq` | 依赖 sync 时机 |
| 中断投递后不需要清位 | ARM 不需要（电平语义） | **成立** | 但前提是下降沿能到达 |
| `has_work()` 返回值可信 | 成立 | 依赖 HARD 新鲜度 | **不成立** |
| WFI 语义 = 交还宿主 | `EXCP_HALTED` | 引擎自睡 | 语义分叉 |

### D. 5 个同步点（`henge_sync_irq` 的唯一调用处）

| 行号 | 触发时机 | 覆盖面 |
|---|---|---|
| 302 | 每次重进引擎前（主循环顶部） | 覆盖"从宿主返回"的情形 |
| 367 | `SYSREG_EXT`/`PSCI_EXT` 服务后（含 ICC 写=EOI） | 覆盖 guest ack |
| 373 | `dispatch_exit` 前 | 覆盖退出路径 |
| 473 | `henge_kick_vcpu_thread`（跨线程 kick） | 覆盖设备线程拉高 |
| 547 | `henge_sync_irq_current` ← MMIO 回调 | 覆盖引擎内 MMIO 拉高 |

**裂缝**：若 vCPU 从不返回宿主（引擎自睡 + WFI 立即返回形成内循环），
则 302/367/373 都不执行；此时只有 473（外部 kick）能救场。
而 473 只在**别人踢它**时跑——guest 自己在 idle 循环里转圈时，没人踢。

---

## 五、AppleVM 为什么没有这个问题

结构性答案：**它根本不是 QEMU 插件**。

证据（`source/windowsios-full.patch`）：

| 指标 | 数值 |
|---|---|
| `CPU_INTERRUPT_HARD` 出现次数 | **0** |
| `devices/` 改动行数 | **3282**（15 个文件） |
| `core/`（引擎核心）改动行数 | **100**（6 个文件） |
| `host/` 改动行数 | 87 |

`devices/` 里是**引擎自己实现的完整设备栈**：
`virtio.c`、`virtio_gpu.c`、`virtio_gpu3d.c`、`xhci.c`、`acpi.c`、`fb_display.c`、`winvirt.c`

即：**AppleVM 的引擎 = 完整机器（CPU+MMU+GIC+PCI+virtio+xhci+ACPI+fb），QEMU 完全不存在。**
宿主只提供 GUI（Metal 显示、JIT 使能）。

所以它的中断流是**单栈闭环**：
```
设备(引擎) → hv_pci_set_intx → 引擎 GIC → hv_check_interrupts → 引擎投递
```
没有第二份电平，没有同步点，没有接缝。

**henge 97% 的改动在设备层，CPU 核心只动了 100 行**——这恰好说明：
AppleVM 认为"给 henge 加能力"= 加设备；而本工程走的是相反的路（加适配层）。

---

## 六、结论：三类结构性债务

### 债 1：电平双份 + 同步点有限（阻塞项）
- 根因：GIC 在 QEMU、投递在引擎，ARM 的电平语义要求二者同步
- 表现：活锁（幽灵电平）、park 死锁、83% 卡住——同一根因的三个时序窗口
- 两条出路：
  - **窄**：把"下降沿必须立刻同步"做成不变量（在每个可能改线的地方强制 sync）
  - **正**：把 GIC/INTx 搬进引擎（= 方案 2，对齐 AppleVM 结构）

### 债 2：`has_work` 语义借用但前提不成立（阻塞项）
- `arm_cpu_has_work()` 只看 `HARD`，不看 `PSTATE.I`
- TCG/KVM 下成立，因为 HARD 新鲜
- henge 下不成立 → `cpu_thread_is_idle()` 永假 → 不 park
- **这一条与债 1 是同一根因的两个面**：HARD 新鲜度

### 债 3：WFI 语义分叉（中）
- TCG 用 `EXCP_HALTED` 交还宿主，宿主 park
- henge 在引擎内 `park`，与宿主 park 并存两套
- 实测：改成交还宿主（`return -1`）反而让早期引导活锁——说明两套 park 互相干扰

### 非阻塞的结构债
- 调试（单步/硬件断点/gdbstub）整块缺失
- 迁移主动拒绝、无快照
- 无 EL2（客机内不能跑 KVM）、无 SVE/SME
- 无内存区域热移（AppleVM 为 virtio-gpu BAR 新增）

---

## 七、对方案 2 的结构性修正

原方案 2 描述为"INTx 走引擎自己的 PCI/GIC"。按本文分析，应修正为：

**方案 2 的本质 = 让 `HARD` 这个电平**只有一个所有者**，即恢复 ARM 设计隐含的前提。**

三条可能路径：

| 路径 | 做法 | 代价 | 是否对齐上游 |
|---|---|---|---|
| 2a | INTx 全部搬进引擎（AppleVM 做法） | 需在引擎实现 virtio/xhci/ACPI 全套（3282 行规模） | 是 |
| 2b | 只搬 GIC 的**输出线**，设备仍留 QEMU | 中等；仍需引擎有 INTx 汇聚 | 部分 |
| 2c | 让引擎每次取线都问 QEMU（消除副本） | 小；但需保证无锁、无重入 | 否（仍有跨栈查询） |

**方案 2a 的工作量证据**：AppleVM 用了 3282 行才让引擎自给自足。
本工程若走 2a，等于重做一遍那些设备——但可以直接参考其实现。

---

## 八、待验证项（不猜，实测）

1. `hv_check_interrupts` 在 WFI 循环内是否真的每轮都跑（`dispatch.c:1126` 的位置）
2. guest 在 `cpu_do_idle` 循环里，`PSTATE.I` 是否真的从未变 0（需 PC 轨迹而非采样）
3. 5 个同步点之外，是否存在第三条改线路径（如 GIC 的 `qemu_set_irq` 直连、非 GIC 源如 timer）
4. `has_work` 返回 true 时，`cpu_thread_is_idle()` 的实际调用频率（确认 park 从未发生）
