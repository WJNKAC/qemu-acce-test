# EL1 linear map：设计约束与验证计划

> 状态：**通道已接通（refills 593041 → 226，命中路径确认在工作），但窗口配置错误，
> guest 3239 条指令即 halt。未交付。**
>
> 本文记录三件在启用前必须处理的事，其中第一件是我原方案里的逻辑错误。

## 0. 已确认的进展（不是从零开始）

| | tlb_refills | fetch_walks | guest_insns |
|---|---|---|---|
| 不给 `--linmap` | 593,041 | 580 | 461,587 ✓ 跑完 |
| 给 `--linmap`（48 位窗口） | **226** | 24 | **3,239** 即 halted |

refills 掉到 226 说明**命中路径真的在拦截**（前一版是完全不命中，那是另一个 bug）。
剩下的问题是窗口覆盖了 δ 不成立的 VA。

## 1. ⚠️ 保险丝在结构上观察不到它要验证的访问（我原方案的逻辑错误）

我原本打算"在 `tlb_fill` 里校验 `host + (pa − ram->pa) − va == delta`"。这个设计是**错的**：

> **窗口命中的定义就是"不产生 fill"。** fast path 在 TLB 探测之前就把访问接走了，
> 所以 `tlb_fill` 能看到的窗口内 VA，只剩 store（若 gate 含 store）和旧块残留。
> 一旦 loads-only，它对 load **完全失明**——而 load 恰恰是要加速的大头。

因此：

- **"首检拒绝"不能作为唯一防线**，它只覆盖非命中路径。
- **必须有一次 linmap 关闭的启动**，让 fill 路径自然观察到全部 EL1 访问。
  这就是 §3 的学习 pass，**不是可选项**。

保险丝的职责要拆成三个角色，各归各位：

| 角色 | 挂在哪 | 作用 |
|---|---|---|
| 诊断 | `tlb_fill` 成功后，EL1 + kernel-range，**linmap 关闭时** | 产出 δ 直方图 → 窗口边界（§3） |
| 保险丝 | 窗口级、首 N 次 fill 校验 | 失配则**关该窗口**，不关 feature |
| 修复 | 按日志配窗口 | 从实测簇来，不从内核版本号推 |

## 2. gate 必须排除 store（已确认代码里本来是关的，但理由要写清）

**现状**：`tools/patch_linmap.py` 的 gate 从第一版起就有 `&& !op.store`（第 122、127 行），
所以 linmap 一直是 loads-only。当时是照抄 bank 的决定，**现在有具体理由了**：

内核通过 **linear 别名**打补丁——`alternatives`、`ftrace`、module 的 text poke
都走 linear alias（这正是 text 的 linear 别名存在的理由）。这条路径上：

```
TLB 路径的 store  → 触发 whint → page_gen++ → JIT 块失效   ✓
linmap 路径的 store → 什么都不触发 → 陈旧块继续执行        ✗
```

`test_smc_mp` 抓不到它，因为测试用的 VA 不在窗口里。

**代价**：store 留在慢路径（启动期页表构建的写是大头）。但这与 bank 是同一个决定
——写撤销是页粒度的，块粒度的加速通道承载不了它。

### 还要写进文档的语义边界

> **`va ∈ 区间` ⇒ "已映射且全权"**（这是 linmap 替 guest 回答的问题，而 guest 没问）

- bank 表项是 **fill 证明过的**（逐块、含 SMC 排除）；
- linmap 是**纯算术**，没有任何证据。

对 **load**："未映射本该 oops" 的分歧可容忍（两边都是内核 bug 场景）。
对 **store**：不可容忍（RO 别名静默写穿 + whint 旁路）。

**loads-only 把两条都收进了可容忍边界**——这是它不只是"抄 bank"的理由。

## 3. 窗口边界：现在是推断，必须变成观察

"3239 条指令 + 226 次 refill" 指向 MMU 刚开、`paging_init` 前后：linear 半建、
image/fixmap/vmalloc 混用的窗口期。三个假设：

| 假设 | 内容 | 判别特征 |
|---|---|---|
| **H1** 区间污染 | image/vmalloc 的 VA 落在窗口内，δ 不同 | 窗口内出现**第二个稳定 δ 簇** |
| **H2** 算术错 | delta 公式错（ram_pa 没减 / RAM 表首段 ≠ pa_base） | 全部 fill 的 implied δ **偏同一常数** |
| **H3** 语义 | 窗口覆盖了 guest 尚未映射或权限受限的 VA | δ 全对，但行为仍发散 |

### 判别实验（linmap 关闭，零风险，一次启动）

`tlb_fill` 成功后，对 **EL1 + kernel-range** 记 `(va, pa, implied_δ = host_ptr − va)`。

**不要 printf** —— 5.1M 行会把启动拖死。内存里按 δ 建直方图：

```c
/* per-CPU 或全局，固定 4096 项，δ 哈希到桶 */
struct { uint64_t delta, count, va_min, va_max; } hist[4096];
```

退出时 dump。**预期 2–4 个紧簇**：linear、kimage、vmalloc 散点。
**簇的 VA 区间就是窗口边界的实测值。**

同一份日志免费回答"EL1 fill 有多少落在 linear 簇" ——
这是 linmap 值多少钱的**一阶估计**（fill ≠ 访问，二阶等启用后用 refills 差值）。

### 窗口配置两条规则

1. **窄前宽后**：第一段从实测簇的**核心**开始（宁窄勿宽，配错会静默损坏），
   第二段留给扩展。
2. **首中即用**：emit 已是顺序回退结构（`for lw in 0..nlinmap` 依次比较），
   先命中的段生效——CLI 已支持两段，这一点无需改代码。

**配置从实测簇来，不从内核版本号推。**（`.config` 写 `VA_BITS=52`，实际 Image 是 48 位，
这就是教训。）

## 4. 启用前的验收三件套

1. **knee 三档不变**（EL0 隔离）：72.5 / 74.0 / 113.9 ns，±2%
2. **启动 `--linmap` 对照**：用实测出来的 PAGE_OFFSET 和窗口边界
3. **Linux guest 侧 fill 分布**：EL1 的 refills 应显著下降，且**不出现新的 halt**

## 5. 与 QEMU 后端的关系

linmap 是**引擎内**的加速，与 QEMU 后端正交：
QEMU 后端只改"PA→host 由谁提供"，linmap 改"哪些 VA 不需要查表"。
两者可以独立推进，但**不要同时改** —— 出问题时无法归因。

当前建议顺序：先把 linmap 按 §3 的实验收尾（半天，零风险），再动 QEMU 后端。
