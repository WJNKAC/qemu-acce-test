# 探针清单

每个探针都是为了**证伪一个具体假设**，不是"跑起来看看"。它们都必须在
henge 与 tcg 下打印同样的东西；对拍不是礼貌，是判据。

| 文件 | 验证什么 | 失败长什么样 |
|---|---|---|
| `probe.S` | 取指 + 执行 + MMIO catch-all + WFI | 什么都不打印，或停在入口 |
| `sysreg.S` | GICv3 的 ICC_* 经 cp_regs 转发 | `SYSREG-BAD-IAR`（引擎自答返回 0） |
| `idreg.S` | ID 组三型存储（CONST/CONST/fieldoffset） | 值不等于 TCG（引擎报 A76，QEMU 报 a57） |
| `timer.S` | CNTFRQ 与 CNTVCT 增量 | CNTFRQ 是 0x16e3600（24 MHz 硬编码） |
| `timerirq.S` | **闭环**：CVAL → gtimer → IRQ → 引擎异常 | 只打印 `TIMER-ARMED`，无 `TIMER-IRQ` |
| `smp.S` | PSCI CPU_ON 经 QEMU 的 psci.c，context 传递 | 只有 cpu0 打印；或 CONTEXT=0 |
| `smc.S` | 改代码页后执行新指令（code_pages 位图） | `SECOND=` 仍是 0x1111 |
| `mmio-rd.S` | MMIO **读**：UARTFR + 4 GiB 以上的 ECAM | 读回 0xffffffff 或 0 |
| `edu.S` | 完整 PCIe 枚举 + edu 设备 BAR 分配 | `EDU-ID-MISMATCH` 或 BAR 回读不对 |
| `dma.S` | 外部 agent 写代码页（gdbstub 路径） | 只到 `WAITING` |

## 为什么 `timerirq.S` 是唯一能抓到 raw-vs-guest 语义的东西

`CNTV_CVAL_EL0` 的 `.writefn` 会调 `gt_recalc_timer()`，`.raw_writefn` 只是
存数字。走错那一个，寄存器读回全对、CNTFRQ 一致、CNTVCT 单调 ——
**除了中断不来**。任何"读回比对"型测试都会放它过去。

同样，`smp.S` 的 `CPU1-CONTEXT` 是唯一能抓到 `env->regs` vs `env->xregs`
和 CPU_ON 写 env 时序问题的观测点。

## 两个"读不到"的教训

`mmio-rd.S` 存在的理由：`probe.S` 只测了 MMIO **写**，读路径从没测过，而
ECAM 枚举完全依赖它。第一次写 ECAM 探针时它读回 0，我以为是引擎的 MMIO 读
坏了 —— 实际是 `puts`/`hex` 破坏了 `x9`，而我把 ECAM 基址留在 `x9` 里。

**探针自身的寄存器纪律**：`puts`/`hex` 用 `x0/x1/x2/x3/x9/x10`。跨调用要
保留的值一律放 `x19`-`x28`。这条不是风格问题——它已经造成过一次误判。

## 编译与运行

宿主（x86_64）没有 aarch64 交叉工具链，所以汇编在容器里做：

```sh
../henge-lifecycle.sh          # 全部 8 项 + tcg 对拍
../henge-probe.sh              # 只跑 probe.S（最快的一条）
```
