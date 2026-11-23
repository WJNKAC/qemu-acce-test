# 去嫁接设计 —— 把 GIC 搬回引擎（KVM vGIC 同栈形态）

状态：设计稿（代码未动；`engine/devices/gicv3.c` 是"复原基线、未接管"）
前置数据：IAR 双峰（77% 2–20 µs 算法地板；11% ≥160 µs 跨栈争用）、
smp2 74 s / smp4 90 s / TCG 373 s、seam 总账 ~2.8 s/run。

---

## 第 0 章 不变量（先重推，代码在它之后）

### 0.1 单真值

- 现架构：线的权威 = QEMU `env->irq_line_state`；引擎在块边界经 hook 读。
- 新架构：线的权威 = 引擎 `HvPerCpu.irq_line`（`hv_gicv3_update_body` 写）；
  **QEMU 侧不再有第二份**。设备 IRQ → `hv_gicv3_set_irq` → 引擎线 → 块边界判定。
- 迁移规则：任何时刻只允许一个写者。翻权威那一刻必须停掉 QEMU GIC 的线写路径
  （`qemu_set_irq` 到 arm CPU 的 PPI/SPI 不再产生），否则双写。

### 0.2 C1 有界汇合（必须带门）

- 老代码 `translate.c:1448-1452` 有无条件 DAIFClr exit（C3 删了它 → 挂死类出现）；
- 修复 = **门控复原**：只读同线程 tracked daif（刚写入）+ 单字真值 line，
  条件 `line != 0 && (daif & I) == 0` 才 OOL exit；
- **搬 GIC 回去时必须带门**，且门的读源改为引擎自己的线字（新拓扑下同一份真值）；
- 判据：无条件 DAIFClr exit = 0；门控 exit ≈ 事件率（不是 2.3M/s）。

### 0.3 C2 睡眠正确性（本章最难，见第 2 章）

动机（为什么 C2 当初要搬）：GIC 权威在 QEMU，唤醒必须与 BQL 协调，所以睡到 halt_cond；
去嫁接把权威搬回引擎，**搬家的理由消失，锁序跟着回去**——第 2 章是推导，不是选择。

- 现架构：vCPU 睡在 QEMU `halt_cond`（BQL 保护）；census 的论证
  "检查与等待同在 BQL 下 ⇒ parked ⇒ 无 pending" 成立；
- 新架构：GIC 在引擎、设备 IRQ 不经 BQL，若仍睡 BQL 保护的 halt_cond，
  无 BQL 的 IRQ 路径无法安全通知 → 丢唤醒窗；
- 结论：**park/wake 必须整体迁到引擎自己的锁序**（老 `hv_cpu_wake` 模板：
  exit_req + SEV + cond_signal），census 论证随之重写：
  新不变量 = "引擎线写 + 唤醒在 GIC 锁内成对；睡眠者在引擎锁内重查线"。

### 0.4 可观测性

- 四戳链（fire_late / wake_late / timeout_ended）跟着搬；
- IAR/EOI 序列 trace diff 是行为等价的主仪器（无逐字节可验）。

---

## 第 1 章 切口：切在设备线上，不切在 GIC 中间

**为什么搬整个 GIC**：半搬（只 ICC）会在 GICD 与 ICC 之间发明一条内部边界，
每次优先级判定都跨线，比现状更糟。老代码 GIC 是完整的（distributor + redistributor + ICC），
模板在手。

**边界**：QEMU 设备 → `hv_gicv3_set_irq(intid, level)`（低频、老签名现成）。
- 设备模型仍在 QEMU（virtio/blk/net/gpu…），完成时调这个适配器；
- 适配器内部取引擎 GIC 自己的锁（`g->mu`），**不取 BQL**；
- 客机 GICD MMIO：引擎未映射的 MMIO 转发给 QEMU？反过来：GICD 的地址区间
  由引擎 GIC 处理（配置期低频，走引擎自己的 MMIO 分发）；其余设备 MMIO 仍转发 QEMU。
- 热路径（ICC 系统寄存器）从此刻起不 exit。

**代价**：GICD 配置期访问仍要一次引擎内处理（低频，可接受）；
QEMU 侧不再有 GIC 状态（拆旧路径见第 4 章）。

**ITS/LPI 范围旗标（未决，翻权威前必须定）**：老引擎 GIC 无 LPI/ITS。
需确认目标跑（UEFI/Debian + PCI virtio）是否实例化 ITS；若走 MSI→LPI，
翻权威那一刻会静默断链。当前 `-M virt` 默认 its=off（PCI 设备回落 INTx），
v2（virtio-mmio）安全；翻权威前按实际机器配置复核。

---

## 第 2 章 睡眠/唤醒的所有权迁移（核心）

### 现状
- vCPU 线程：`qemu_process_cpu_events()` → `while (cpu_thread_is_idle(cs)) qemu_cond_wait(halt_cond, &bql)`；
- 唤醒：`cpu_interrupt` → `qemu_cpu_kick` → broadcast + accel kick；
- census 关账的依据：检查与等待都在 BQL 下，写线者（gic update/SGI/vtimer/设备）也在 BQL 下。

### 新拓扑的问题
- 引擎 GIC 的设备 IRQ 路径（`hv_gicv3_set_irq`）不持 BQL；
- 若睡眠者仍用 halt_cond/BQL，IRQ 路径不能安全地 signal（拿 BQL 才有序，但那正是要消掉的成本）；
- 因此：**park/wake 迁到引擎自己的锁序**。

### 新协议（照老代码模板）
```
写线者（GIC 锁内）:
    p->irq_line = level;
    if (raised) hv_cpu_wake(cpu);         // exit_req + SEV + cond_signal
vCPU 睡眠:
    while (!wake_pending && !exit_req && !有工作)
        pthread_cond_wait(&p->wake_cv, &p->wake_mu);   // 引擎 condvar
    wake_pending = 0;
```
- 不变量：**线的写与唤醒在同一把 GIC 锁内成对**；睡眠者在自己的锁内重查线；
- 与 QEMU 的关系：vCPU 线程仍需在 QEMU 的线程框架里（stop/关机/pause），
  但"睡多久"由引擎 condvar 决定；QEMU 的 kick 变成"打断引擎睡眠"的辅助通道；
- census 重写：新论证 = "GIC 锁内写线+唤醒；睡眠者持 GIC 锁重查线" ⇒ parked ⇒ 无 pending；
- 必须验证：pause/shutdown（QEMU stop）仍然能打断引擎睡眠（老代码的 stop 路径）。

### 迁移步骤（影子期可双跑）
1. 引擎 condvar 睡眠作为**辅助**通道（与 halt_cond 并存，knob）；
2. 双通道验证无丢唤醒（四戳链 + 唤醒原因）；
3. 翻权威：引擎 condvar 为主，halt_cond 仅在 stop/pause 时使用。

---

## 第 3 章 vtimer 引擎化

- 老代码注释："the CPUs' ICC registers and timers do not need [the device lock]" —— 引擎 timer 有模板；
- 范围：CNTV_CTL/TVAL/CVAL 进快窗（读 ISTATUS 现算，写时重算 deadline）；
- fire：引擎 timer 到点 → `hv_gicv3_set_ppi(27, 1)`（引擎内，不 exit）；
- 与 QEMU 的关系：QEMU 的 `gt_timer[GTIMER_VIRT]` 停用（否则双 PPI）；
- 四戳链的 armed-deadline 记账跟着搬（deadline 域 = 引擎 24 MHz 时钟，与 wall 1:1）；
- 判据：CNTV seam 访问 = 0；fire_late 直方图不劣化。

---

## 第 4 章 验证：影子先行

### 4.1 影子适配器规格（六件 + 治理）

1. **镜像三类输入**：
   (a) 全部 set_irq 线变迁（设备 SPI + vtimer PPI，per-CPU 标签）；
   (b) 客机 GICD MMIO 写（enable/route/priority/targets/icfgr）；
   (c) ICC exit 读写值。引擎 GIC 用同一套输入独立算线，**只算不叫醒**。
2. **diff 点 = 块边界 + 每次 exit**，diff 对象 = 单字线状态；
   两边界之间的瞬态分歧不可见、不需可见（决策时刻只在边界和 exit）。
3. **edge int 的 pending 锁存**：ICFGR 配成边沿的 intid，引擎影子必须同样锁存 pending
   再算线——**diff 仪假阳性头号来源**，先写进代码注释。
4. **reset 对齐**：引擎 GIC 复位态与 QEMU 一致，从第一个块开始 diff。
5. **mismatch 处置**：按类分桶计数 + 首次 mismatch 全量双 dump + knob 停机；
   100% 匹配是硬判据无容差（BQL 下同临界区写镜像，无竞态）。
6. **knob 纪律**：SHADOW=0 时零行为变化（编译期裁剪最好）；shadow=1 的 wall 开销入账。

**治理**：`gicv3.c` header 的"禁止零碎接线"补豁免——**只读影子豁免**；
翻权威需过 census 重推门。防止两种误用：引用注释反对影子 / 引用影子豁免正当化真接线。

**vtimer 影子同构**：镜像 CVAL 写，引擎侧算 fire 时刻与 QEMU 实际 fire 事件 diff；
clock 域注释写明——影子期借 QEMU virtual clock（advisory 只读），翻权威时换引擎自己的域
（属第 3 章，影子期不顺手做）。

### 4.2 影子模式（knob：HENGE_GIC_SHADOW）

实现约束（影子期）：
- **走真适配器**：QEMU→引擎 `hv_gicv3_set_irq` 适配器先建好，影子期在 BQL 下调用；
  引擎 GIC 只算线、**不叫醒**；
- 镜像写入与 QEMU 线写入在**同一临界区**（BQL）→ 无竞态 →
  "匹配率 100%" 是**硬判据**，不设容差；
- 唤醒/锁序迁移**不在影子期**：census 重推（parked ⇒ 无 pending，引擎锁序下）
  是翻权威的门条件。
- 引擎 GIC 先以观察者身份跑：镜像两类输入
  （seam 出来的 ICC/GICD 访问；QEMU 的 `set_irq` 线事件）；
- 引擎独立算出"本该拉的线"，与 QEMU 实际线在**块边界** diff；
- 输出：匹配率、首个不一致的 (pc, intid, level, 两侧状态)；
- 达标门槛（预注册）：连续 boot 全矩阵匹配率 100%，且不一致为 0。

### 4.3 翻权威（knob：HENGE_GIC_AUTHORITY）
- 引擎线成为唯一真值；QEMU GIC 停写线（保留 MMIO 转发到引擎）；
- 全矩阵 + 门槛五件 + IAR/EOI trace diff（行为等价）。

### 4.4 拆旧路径
- 删除 QEMU 侧 GIC 的线写路径与我们的 seam 钩子（O1/O2 退役）；
- 保留：设备模型、GICD MMIO 转发（若引擎 GIC 接管则删除）、
  以及 **DAIFClr 门**（读引擎线字）。

### 4.5 参考数据集与 golden fixture

`HENGE_EXIT_DUMP=1` 跑 v2 到自然结束（不 SIGKILL），一次收齐 decide:take + IAR/EOI 序列：
它同时是第 4 章 trace diff 的**行为基线**，并关掉 v2 五件清单最后一个 ⚠️。
vtimer 同构：CVAL 影子 + fire 时刻 diff。

**计数器 ≠ 序列**：take 计数器验"无丢失"；trace diff 需要 **IAR 返回 intid 全序 + EOI 全序**。
翻权威前存 golden fixture（v2 一跑 + UEFI 短跑，EXIT_DUMP 完整走完不 SIGKILL），
翻权威后同映像同负载复现比对。计数器验无丢失、序列验行为等价，两样都要。
迁移/savevm 明确 out of scope。

### 4.6 矩阵
- v2/v3 `-kernel`、UEFI、TCG oracle、安装器+桌面启动；
- **RT 病人**：本环境无 RT 镜像（images 只有 Image/debian12/20/overlay）——
  移交到交接层的验证矩阵（注入路径重写时最有意义），不静默销账。

---

## 附：价格与判据（预注册）

| 指标 | 现状 | 目标 |
|---|---|---|
| IAR 均值 / 重尾 | 67 µs / 11% ≥160 µs | 均值 ≤15 µs、重尾 <1% |
| seam 总账 | ~2.8 s/run | ≤0.5 s |
| smp4 wall | 90 s | **硬门：≤90 s（不回归）**；"≤ smp2"降级为期望（TCG 对照证明通用 per-CPU 成本） |
| IAR 尾 / cpuif 方差 | 11% ≥160 µs；9.7→58 µs spread | **硬门：尾 <1%、方差塌缩** |
| Δ(smp4−smp2) | +16 s | 软目标：收缩 |
| DAIFClr 无条件 exit | 0 | 0（门控 ≈ 事件率） |
| 丢唤醒 / 挂死 | 0 | 0（影子→翻权威全程） |

## 翻权威前的 census 重推（2026-11-23，ITS soak 后）

影子期 census（"check 与 wait 都在 BQL 内 ⇒ parked ⇒ 无 pending"）绑定的是
**QEMU GIC 作权威**的拓扑。翻权威后，线的更新源分成三类，census 必须分别覆盖：

| 源 | 线程/锁 | 翻权威后的唤醒路径 |
|---|---|---|
| 设备 IRQ（set_irq tap） | 主循环 / 设备线程，**BQL 内** | 引擎 GIC update → 需桥接到 `qemu_cpu_kick`/`cpu_interrupt`（当前 tap 走的是 QEMU GIC 的输出线，翻转后消失） |
| vtimer（主循环 tick） | 主循环，BQL 内 | 同上 |
| ITS doorbell / 客机 MMIO（vCPU 线程） | vCPU 线程自身 | 无需唤醒（CPU 正在跑）；但 census 的"无 pending"必须允许该源的并发更新 |

结论（翻权威门条件）：

1. **唤醒桥**：引擎 GIC 的 `hv_gicv3_update` 在置线后必须调用 QEMU 的
   `cpu_interrupt`/`qemu_cpu_kick`（accel 侧桥），否则 parked vCPU 不会醒
   （引擎的 `hv_cpu_wake` 只 signal 引擎自己的 cv，不碰 QEMU 的 halt_cond）；
2. **MMIO 路由**：引擎的 dispatcher 目前只对 RAM 直读直写、MMIO 兜底给 QEMU；
   翻权威需要引擎的 MMIO 表先于 QEMU 的 address space 被查询（否则 GIC MMIO 仍到 QEMU GIC）；
3. **census 条件**：parked ⇒ 无 pending 仍成立，**前提**是唤醒桥覆盖所有 BQL 内的置线源，
   且 vCPU 线程自身的置线源在 census 采样时持有同一把 GIC 锁（或 seqlock）。

以上三条未实现前，翻权威会以"parked 但线已高"的形态挂死——这是 census 重推的产物，
不是猜测。

## 模式契约表（翻权威的诊断方法：契约缺行，不是孤 defect）

| 职责 | shadow 模式 | authority 模式 |
|---|---|---|
| tap 接收 | 开（镜像到影子 GIC） | 开（路由到 `g_auth_g`）——已修 row 1 |
| level→pending latch | 影子 GIC 的 update | 引擎 GIC——row 2 头号嫌疑 |
| hppi 重算触发 | ?（怀疑靠 settle 轮询搭车） | tap 后必须显式 kick |
| 线→vCPU 交付 | QEMU GIC（真身） | 引擎 percpu 线 |
| vCPU 唤醒 | kicker 桥 | 待定（row 5） |
| QEMU GIC 角色 | 权威，状态有效 | 退场，状态失效 |
| 仪器（settle/seqlock/in_flight） | 对 QEMU 比 | **对象已死，必须显式关** |
| ITS | 观察（门铃镜像） | 引擎真交付 MSI（新面） |

grep 结果（`henge_shadow_active` 消费者，2026-11-23）：

- 仪器类：`dispatch.c` BB diff、`henge-cpu.c` settle/ICC/ITS 元组、`henge-accel-ops.c` 线钩 diff
  ——权威模式下仍在跑，比较对象是 QEMU 的死状态 → 必须按模式显式关；
- tap 类：`hw/intc/arm_gicv3{,_dist,_redist,_its}.c` ——权威模式必须开（row 1）；
- 路由类：`henge_shadow_spi/ppi` 的 `g_auth_g` 分支。

结论：一个布尔两个主人（`henge_shadow_active` 在权威模式下名不副实，`g_auth_g` 是第二旗标）
→ 重构为三态 enum（OFF/SHADOW/AUTHORITY），tap/仪器/路由全部 switch on mode。

---

## census 定稿（authority 落地后，2026-11-24）

上一节（"翻权威前的 census 重推"）是**翻之前的推演**，三条门条件后来都落了：
(1) 唤醒桥 = kicker 线程的 `cpu_interrupt`/`qemu_cpu_kick`（`henge-accel-ops.c`）；
(2) MMIO 路由 = 引擎 MMIO 表先于 QEMU 地址空间（设备 MSI 走 tap 进引擎 ITS，见第 142 轮）；
(3) census 条件 —— 本文就是它的定稿，取代影子期那句
"check 与 wait 都在 BQL 内 ⇒ parked ⇒ 无 pending"。

### 实际停车点（不是猜的）

```
system/cpus.c: qemu_process_cpu_events()
    while (cpu_thread_is_idle(cpu))          // 持 BQL
        qemu_cond_wait(cpu->halt_cond, &bql); // 释放 BQL 睡
```

`cpu_thread_is_idle()` 在 `!cs->halted` / `cpu_has_work()` 之后调用
`henge_vcpu_thread_is_idle()`；authority 态下后者**只读引擎线**
（`henge_auth_line(ci,0/1)`，原子读，不取 g->mu）。

### 三条线源与它们各自的唤醒

| 源 | 线程/锁 | 置线 → 唤醒 |
|---|---|---|
| 设备 IRQ（SPI/PPI tap） | 设备线程或主循环，**持 BQL** | `henge_auth_spi/ppi` → 引擎 GIC `hv_gicv3_update_body`（g->mu 内）→ wake hook |
| vtimer（PPI27） | 主循环，持 BQL | `henge_auth_tap_ppi` → 同上 |
| ITS 设备 MSI（LPI） | 设备线程持 BQL；或 vCPU 线程（客机写 MSI-X 表，无 BQL） | `henge_shadow_its_msi` → 权威 ITS → `lpi_pending` → `hv_gicv3_update_body`（g->mu 内）→ wake hook |
| 客机 SGI（ICC_SGI1R 跨核） | **vCPU 线程，无 BQL** | 引擎 ICC → 目标 CPU 的线 → wake hook |

wake hook = `henge_wake_bridge`：**只**在 `wake_mu` 内置 `p->wake_pending = 1` + signal
引擎 cv，并置 kicker 标志；**不在 GIC 线程里直接 `qemu_cpu_kick`**（踩过段错误）。
kicker（2.5 ms）在 BQL 内 `cpu_interrupt(HARD)` + `qemu_cpu_kick`。

**协定的另一半（第 143 轮补）**：`qemu_cpu_kick()` 的 broadcast 也必须**在 BQL 内**发。
睡眠者以 BQL 作 mutex 在 `qemu_cond_wait()` 上等，无锁 broadcast 会落在
"检查 idle → 进入 wait" 的窗口里丢掉——CPU_ON 的次核桥就这样丢过：PSCI 返回成功、
次核永不运行、客机 6 秒后报 `CPU1: failed to come online`（修前 2/6 次，修后 6/6 通过）。
判据：所有 `qemu_cpu_kick` 调用点都必须持 BQL（或经 `cpu_interrupt` → `generic_handle_interrupt`
这条自带 BQL 的路径）。

### 不变量（新的表述）

> 一个已 park 的 vCPU 不可能有"看不见的 pending"：
> 它在 **BQL 内**读引擎线并进入 `cond_wait`；持 BQL 的写者被这一步串行化，
> 不可能落在"读到 0"和"睡下"之间；不持 BQL 的写者（客机 SGI）和它的
> wake 标志都由 kicker 在 BQL 内**按当前线**再判一次，
> 所以最坏情况是**晚一个 kicker 周期（≤2.5 ms）才醒**，不是丢唤醒。

推论：
- 旧的"parked ⇒ 无 pending"依赖的是**写者与检查都在 BQL 下**；这条拓扑已经不成立
  （SGI/ITS 可以在 vCPU 线程置线），所以 census 的正确陈述是上面那句
  **"parked ⇒ 无看不见的 pending，且新置线在一个 kicker 周期内变成 kick"**；
- 计数器判据：`auth-irq masked/taken`、`sgi_acc`、`ppi_taken` 与"唤醒原因"直方图
  （`henge-wake`）必须对得上；丢唤醒会表现为 `parked 且 line=1` 持续 > 一个周期
  ——这就是 A5 的墙要抓的形态。

## 范围清单（authority 覆盖 vs 排除）

| 面 | 状态 | 证据 |
|---|---|---|
| 客机：v3（`-kernel Image` + initramfs，含 `its=on`） | 覆盖 | g1 g2 g3 h-v3its：→ `/myinit` → Power down |
| 客机：UEFI-INTx（edk2 + virtio-blk/net） | 覆盖 | a3-intx-auth → `gdm.service` |
| 客机：UEFI-ITS（`its=on`，virtio-net-pci MSI） | 覆盖 | i1（gdm）、i3（898 个 auth door） |
| GIC | GICv3 dist/redist/ICC + ITS/LPI | 同上；GICv2 在 accel 入口显式拒绝 |
| 中断源 | 设备 SPI/PPI、vtimer PPI27、ITS 设备 MSI、跨核 SGI | `auth-funnel`：sgi_sent=1000 sgi_acc=301/699、ppi_taken=4778/1519 |
| 唤醒 | 引擎 cv + kicker 桥（本文件上一节） | g2/g3 心跳 + 全通 |
| PSCI | in-engine：VERSION/FEATURES/CPU_ON/CPU_OFF/AFFINITY/SYSTEM_OFF/RESET | `HV_PSCI_LOG`；SYSTEM_* → `HENGE_EXIT_HALT` → QEMU shutdown/reset |
| SMP | 2 vCPU | sgi_acc 双侧、CPU1 用户态 |
| **排除** | GICv2（拒绝）；migration/savevm；EL2/EL3 客机（引擎只有 EL0/EL1）；`-smp 4` 未测；RT 镜像环境里没有 | 代码拒绝 + STATE 第 2050 行 |
