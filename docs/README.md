# docs —— 分析与说明

这里放**给人读的分析/说明**；逐轮证据在 [../labs/STATE-2026-11-19.md](../labs/STATE-2026-11-19.md)，
可复跑的脚本在 `../labs/recon/`，引擎移植的逐坑记录在
[../port-android/README.md](../port-android/README.md)。

## 当前（QEMU + henge 加速器）

| 文档 | 内容 |
|---|---|
| [DESIGN-degraft.md](DESIGN-degraft.md) | 去嫁接设计：三态（OFF/SHADOW/AUTHORITY）、census 定稿、范围清单、价格表 |
| [VERDICT.md](VERDICT.md) | 判决书：四条 KVM 不变量 → 实现 → 证据；A1–A6 / Phase B 判据；被否决方案 |
| [TERMUX-TESTING.md](TERMUX-TESTING.md) | Termux 上的对齐口径（Tier A/B/C）与测试矩阵 |
| [QEMU-BACKEND.md](QEMU-BACKEND.md) | QEMU 后端：引擎怎么接进 QEMU（最长的一篇，按调用路径组织） |
| [configure-diff.md](configure-diff.md) | 与 Termux 包的 configure 差异（每个开关为什么） |

## 引擎直跑期（历史数据，结论仍可参考）

| 文档 | 内容 |
|---|---|
| [BENCH.md](BENCH.md) | 微基准 + 开机速度（引擎直跑，非 QEMU 形态） |
| [BOOT-VS-TCG.md](BOOT-VS-TCG.md) | 为什么比 TCG 快：块链 + 间接跳转缓存，逐次块转移拆解 |
| [KVM-VS-ENGINE.md](KVM-VS-ENGINE.md) | 四方对比：原生 / KVM / 加速器 / TCG |
| [CALL-PATH.md](CALL-PATH.md) | `call` 的成本拆解（影子栈为何没用、该往哪走） |
| [MEASURE.md](MEASURE.md) | 测量方法 + TLB knee 曲线（64 MB 处 30× 断崖） |
| [FINDINGS.md](FINDINGS.md) | 机制层面的发现（MMU、块链、时基、SB 改写…） |
| [FRONTEND-CHOICE.md](FRONTEND-CHOICE.md) | 前端选型（UEFI vs 直接 Image） |
| [LINMAP.md](LINMAP.md) | 线性映射与地址布局 |
| [vs-termux.md](vs-termux.md) | 与 Termux 自带 QEMU 包的对比 |
| [henge-seam-structure.md](henge-seam-structure.md) | 接缝结构分析（2026-11-19，影子期；所有权矩阵与证据） |

## 读法建议

- 想知道**现在架构为什么是这样**：先 [VERDICT.md](VERDICT.md)，再 [DESIGN-degraft.md](DESIGN-degraft.md)；
- 想知道**某个结论的证据**：`../labs/STATE-2026-11-19.md`（按轮次，带计数器与命令）；
- 想**复跑**：`../labs/recon/`（`corpus.sh` 六病人、`a5wall.sh` 墙、`bench.c` 并行基准）；
- 历史文档里的绝对性能数字是**引擎直跑**的，不要和 QEMU 加速器形态混着引用。
