# 判决书 —— henge 引擎对标 KVM 架构修复（Phase C）

日期：2026-11-24。范围：`/data/用户/项目/qemu-acce`，QEMU 11.1.3 + henge 加速器。
目标形态：`-accel henge` + `HENGE_GIC_AUTHORITY=1`（引擎 GIC 为唯一真值）。
本文件是 A1–A6 与 Phase B 的收口判决，不是设计稿（设计过程见 DESIGN-degraft.md，
逐轮证据见 STATE-2026-11-19.md）。

---

## 0. 一句话结论

移植的可运行性问题**不是** GIC 语义，而是**同一份状态有第二个写者**：
seam 的 env 往返（PSCI/ICC/线拷贝）在唤醒、CPU_ON、ITS 三条路径上各修了一次，
修完后 authority 形态在 v3 / UEFI-INTx / UEFI-ITS 三个病人上全绿，
wall 不回归（smp2 69–71 s，smp4 82.7 s ≤ 90 s），语料回放 0 失败。

## 1. 四条 KVM 不变量 → henge 实现 → 证据

| KVM 不变量 | henge 实现 | 证据 |
|---|---|---|
| 一个 vCPU 状态所有者（vcpu fd） | 引擎 `HvCpu`；`CPUARMState` 只是 seam 点快照，唤醒路径**不重装** | 第 139 轮：删掉唤醒重载；重载曾把已完成的 HVC 重放（+0x10 之谜的真因） |
| PSCI 在 EL2 内处理（`arch/arm64/kvm/psci.c`） | HVC 在引擎 `psci()` 内处理，块继续；只有 SYSTEM_OFF/RESET 经 `HENGE_EXIT_HALT` 出到 QEMU 的 shutdown/reset | 第 139–140 轮；A6 删除 seam 后 3/3 smp2 |
| `kvm_vcpu_reset` + `kvm_vcpu_kick` | 引擎 CPU_ON reset（`off/parked_off`）+ kicker 桥（BQL 内 `halted=0`, `power_state=ON`, `qemu_cpu_kick`） | 第 140 轮；修后 12/12 次 CPU1 online |
| GIC 单所有者 + 注入路径唤醒 | 引擎 GIC 唯一写线；设备 SPI/PPI、vtimer、ITS 设备 MSI 三条 tap 都喂它；kicker 唤醒 | 第 140/142 轮；`sgi_acc=301/699`、`ppi_taken=4778/1519`、898 个 auth door |

## 2. A1–A6 判决

| 阶段 | 判决 | 关键计数器/来源 |
|---|---|---|
| A1 输出腿（唤醒） | 通过 | `hv_engine_note_irq` 在 authority 早退（第 138 轮）；`henge_irq_push` 同规则（第 140 轮）；boot 0.15 s → 0.9 s |
| A2 SMP（CPU_ON/env-reload/CPU1） | 通过 | `CPU1: Booted secondary`、`Brought up 1 node, 2 CPUs`；12/12（第 143 轮）；sgi 双侧 1000 发 301/699 收 |
| A3 权威回归（3 病人含 its=on） | 通过 | v3 → `/myinit`；UEFI-INTx → gdm；UEFI-ITS → gdm（第 142 轮；修前停在 GRUB 后） |
| A4 census + 范围清单 | 通过 | DESIGN "census 定稿" 节：实际停车点 `qemu_process_cpu_events`；新不变量"parked ⇒ 无看不见的 pending；新置线 ≤1 kicker 周期"；`henge_shadow_active` 退休 |
| A5 post-flip 墙 | 通过（wall 硬门） | smp2 69.4/70.9 s（基线 74）；smp4 82.7 s（硬门 ≤90）；IAR 口径已换（见 §4） |
| A6 去嫁接 | 通过 | PSCI seam 整体删除；sysreg seam、ICC/ITS taps、O1 钩子保留；回归全绿（第 145 轮） |
| Phase B 语料回放 + 影子常驻诊断 | 通过 | `corpus.sh` 六病人 0 失败；影子 176128 diffs mismatch=0、32249 settle bad=0、153786 bb、22349 edge、unexplained=0 |

## 3. 被数据否决/回退的方案（连同理由一起留档）

1. **QEMU 侧 PSCI seam**（`arm_handle_psci_call` + `run_on_cpu` 重同步）：
   它是 vCPU 状态的第二个所有者；`psci_resume` 只推引擎 pc 不推 `env->pc`，
   唤醒重载于是重放已完成的 HVC。已删除（A6）。
2. **env → 引擎的唤醒重载**：+0x10 之谜的真因。已删除（第 139 轮）。
3. **`henge_irq_push` 在 authority 下拷贝 QEMU 死线**：kick 刚叫醒的线被写回 0。
   已改为 authority 早退（第 140 轮）。
4. **事件驱动唤醒器**（condvar + waker 线程，替代 2.5 ms kicker）：
   全 CPU 版每中断踢运行中的 vCPU（`exit_req`→多一次宿主往返），wall 69.4 → 117.5 s；
   只踢 parked 版 wall 79.0 s 但 IAR 尾部不降（尾巴主因是客机自屏蔽）。
   **保留 kicker**，数字记入本文件，不保留未证明收益的机制（第 144 轮）。
5. **把 ITS 病人退化为 INTx**：不需要。设备 MSI 是设备侧地址空间路径，
   `henge_shadow_its_msi` 的 authority 分支把原始 `(devid,eventid)` 喂给引擎 ITS 即可，
   病人仍走 MSI/LPI（第 142 轮，898 door）。

## 4. 范围与残留（不静默销账）

| 项 | 状态 |
|---|---|
| GICv2 | 入口显式拒绝（`OUT OF SCOPE`），未做 |
| migration / savevm | 明确 out of scope |
| EL2/EL3 客机 | 引擎只有 EL0/EL1，入口拒绝 |
| `-smp 4` | **只测了 wall**（82.7 s），三个病人的 smp4 全矩阵未跑 |
| RT 病人 | 环境无 RT 镜像；IAR 指标因此不能闭环。新的 `HENGE_IAR_LAT`（线升→IAR）测得均值 350–614 µs、≥160 µs 尾巴 24–39%，但其中包含客机自屏蔽时间（同跑 `masked=1094 / taken=1404`），与旧的 QEMU GIC 侧 67 µs 不可比；**拆分 masked/unmasked 移交交接层 RT 矩阵** |
| 旧的 `HENGE_IAR_SPLIT` | authority 下不再适用，仅保留给影子期对照 |
| A0 oracle | 未单独做轨迹采集；其目的由**影子 diff** 覆盖（对活 QEMU GIC 的 17.6 万次边界比对，mismatch=0） |

## 5. 复现

```bash
# 手机侧（Termux），q-henge 已部署到 ~/qa/bin/
cd ~/qa && ./scripts/corpus.sh -q      # 六病人回放，退出码=失败数；-q=UEFI 100 s，默认 120 s
./scripts/a5wall.sh 2 a5 120           # time-to-GDM + IAR 直方图（authority）
HENGE_GIC_SHADOW=1 ... -accel henge    # 影子诊断：mismatch/bad/unexplained 必须 0
```

判据（预注册，改口径要同时改这里和 DESIGN）：
- 语料：每个病人的 PASS 条件见 `labs/recon/corpus.sh` 的 `chk` 行；
- wall：smp4 ≤ 90 s 硬门、smp2 不高于 74 s 基线；
- 影子：mismatch/bad/unexplained 必须 0，`race` 是独立桶；
- 丢唤醒/挂死：语料 + 12/12 CPU_ON 样本，0 次。

## 6. 提交索引（本轮工作）

| 提交 | 内容 |
|---|---|
| `fd373e5c5e` | A6：删除 PSCI seam |
| `39645925a8` | A5：IAR 仪器（waker 已回退） |
| `524c5bee84` | A4：三态退休 + BQL kick |
| `f9f9d7a755` | A3：设备 MSI → 权威 ITS |
| `e73900d260` | A2：power_state 桥 + 线写者清理 |
| `414af65`、`e375b67`、`a1bd18b`、`89a8a7b` | STATE/DESIGN/语料/判决书 |
