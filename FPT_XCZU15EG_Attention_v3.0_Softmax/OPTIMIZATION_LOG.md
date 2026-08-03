# Attention 优化实验记录

## 固定测试口径

| 项目 | 固定值 |
|---|---|
| 板卡 | XCZU15EG |
| Vivado/Vitis | 2024.2 |
| 模型切片 | 32Q / 8KV / 8 Groups / S128 / D128 / BF16 |
| 测量范围 | START MMIO pulse → ST_DONE |
| 运行次数 | 预热 1 次，正式测量 10 次 |
| 正确性 | `abs_error <= 1e-4 OR BF16_distance <= 1 ULP` |
| FLOPs/run | 268,435,456（仅 QK+PV） |

## 版本总表

| 实验 | 唯一主要改动 | 10-run | 中位延迟 ms | PL cycles | GFLOP/s | 相对上一版 | 相对 v2.3 | WNS ns | LUT / FF / BRAM / DSP | 决策 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|---|
| BASE-v2.3 | 实体板 Profiling 基线 | 10/10 | 1843.689 | 276,550,520 | 0.1456 | 1.000× | 1.000× | +1.023 | 51,224 / 36,796 / 99.5 / 136 | 冻结 |
| OBS-v2.4 | 细粒度性能计数器 | 10/10 | 1843.689 | 276,550,484 | 0.1456 | 1.000× | 1.000× | +1.146 | 51,679 / 36,888 / 99.5 / 136 | 保留并冻结 |
| INT-v2.6 | Causal + 双QK + 原生TILE4 + 双PV | 10/10 | 429.394 | 64,408,268 | 0.625 | 约 1.00× | 4.29× | +1.327 | 32,797 / 66,443 / 175.5 / 267 | 通过 |
| REL-v3.0 | Online Softmax 跨行隔离 + 精确分母 | 10/10 | 429.394 | 64,408,268 | 0.625 | 1.00× | 4.29× | +1.327 | 32,797 / 66,443 / 175.5 / 267 | 发布 |

## REL-v3.0：Online Softmax 精确分母发布版

- 日期：2026-08-03
- 对外版本：`FPT_XCZU15EG_Attention_v3.0_Softmax`
- 修复路径：首次实板 Context 全零；跨行状态修复后剩余 2 个超出 1 ULP 的点；精确分母修复后 Combined failures 降为 0。
- 回归结果：行级延迟 443 cycles、连续 512 行输入/输出、完整后端 65,536 概率和 524,288 Context 均通过。
- 实现结果：Vivado 2024.2，WNS `+1.327 ns`、WHS `+0.010 ns`、DRC `0 Error / 0 Critical Warning`。
- 板测结果：1 次预热 + 10 次正式运行，正确性与确定性均为 `10/10`，最大误差 `1 ULP`。
- 决策：作为 v3.0 对外提交版本；内部 v26 工程标识继续保留以兼容构建链。

## INT-v2.6：Causal Dual-Tile

- 日期：2026-07-31
- 源码版本：`2.6-causal-dualtile-source`
- 频率目标：150 MHz，不在本版提频；
- 直接基线：v2.5 Ping-Pong源码；
- 集成改动：Causal QK Tile Skip、双4×4 QK、原生TILE4、Causal PV
  逐行有效、双4×4 PV；
- Host静态检查：PASS；
- Vivado 2024.2 实现：PASS；WNS `+1.327 ns`，DRC 无 Error/Critical Warning。
- XCZU15EG 板测：最终 v3.0 精确分母修复版 10/10 PASS。
- 决策：主体架构通过；以 REL-v3.0 作为正式提交版。

## BASE-v2.3：实体板 Profiling 基线

- 日期：2026-07-28
- 原始日志：`logs/v2.3_hardware_profile_10run.txt`
- 修改内容：无；冻结当前稳定版本。
- 优化假设：不适用。

| 指标 | 结果 |
|---|---:|
| 正确性通过次数 | 10 / 10 |
| Combined failures | 0 |
| 最大绝对误差 | 0.000122070 |
| 最大 ULP | 1 |
| 中位/代表延迟 | 1843.689 ms |
| PL cycles | 276,550,520 |
| GFLOP/s | 0.1456 |
| B+C cycles | 156,648,602 |
| PV cycles | 119,799,808 |
| Overlap cycles | 0（现有调度基本串行） |
| 实际频率 | 149.998 MHz |
| WNS | +1.023 ns |
| LUT / FF / BRAM / DSP | 51,224 / 36,796 / 99.5 / 136 |

- 是否保留：是，作为不可破坏的回退基线。
- 结论：DDR 不是当前主要瓶颈；下一步拆分计算阶段计数器。

---

## OBS-v2.4：细粒度性能计数器

- 日期：2026-07-29
- 源码版本：`2.4-profile-counters-board-pass`
- Bitstream SHA-256：
  `6332eefe6db4addad53d87e93a491b887e01a596c5a3c7fc65aca6c5d7c63278`
- 唯一主要改动：增加可观测信号、32-bit 计数器、GPIO pages 27～39、
  A53日志和Python解析；不修改计算数据通路和调度。
- 优化假设：本版本不追求加速，只用于准确定位阶段2双缓冲前的瓶颈。

验收结果：

- 静态 RTL/C/Python 契约：PASS；
- Vivado RTL elaboration、综合、实现、DRC：PASS；
- 时序：150.015 MHz，WNS +1.146 ns，TNS 0；
- 资源：51,679 LUT / 36,888 FF / 99.5 BRAM Tile / 136 DSP；
- XCZU15EG：预热 1 次、正式 10 次，正确与确定性均为 10/10；
- Combined failures：0；最大 BF16 距离：1 ULP；
- 平均延迟：1843.689 ms；平均 PL cycles：276,550,484；
- 是否保留：是，作为阶段2优化的已验证观测基线。

| 关键计数器 | 平均周期 | 占总周期 |
|---|---:|---:|
| QK busy | 133,431,296 | 48.248% |
| Softmax busy | 4,916,224 | 1.777% |
| B+C replay busy | 133,712,712 | 48.350% |
| Real PV busy | 119,799,808 | 43.319% |
| B+C / real-PV overlap | 0 | 0.000% |
| Real-PV feed stall | 115,605,520 | 41.802% |
| DDR read master busy | 412,457 | 0.149% |
| DDR write master busy | 156,832 | 0.057% |

- 相对 v2.3：延迟和 PL 周期基本不变；
- 资源增量：+455 LUT（+0.89%）、+92 FF（+0.25%），BRAM/DSP 不变；
- 结论：DDR 和单独 Softmax 不是当前主瓶颈；阶段2优先增加跨 Group
  B+C/PV overlap，并消除 Real-PV feed stall。

---

## 实验模板

复制本节并替换 `EXP-XXX`：

```markdown
## EXP-XXX：优化名称

- 日期：
- 源码版本：
- Bitstream SHA-256：
- 唯一主要改动：
- 优化假设：

| 指标 | 上一版 | 当前版 | 变化 |
|---|---:|---:|---:|
| 正确性通过次数 |  |  |  |
| Combined failures |  |  |  |
| 最大绝对误差 |  |  |  |
| 最大 ULP |  |  |  |
| 中位延迟（ms） |  |  |  |
| PL cycles |  |  |  |
| GFLOP/s |  |  |  |
| B+C cycles |  |  |  |
| PV cycles |  |  |  |
| Overlap cycles |  |  |  |
| 实际频率（MHz） |  |  |  |
| WNS（ns） |  |  |  |
| LUT / FF / BRAM / DSP |  |  |  |

- 相对上一版加速：
- 相对 v2.3 总加速：
- 是否保留：
- 结论与下一步：
```
