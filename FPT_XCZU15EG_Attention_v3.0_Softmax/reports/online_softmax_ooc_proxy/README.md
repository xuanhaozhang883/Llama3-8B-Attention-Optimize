# Online Softmax OOC 代理实现对比（历史探索记录）

> 本目录记录 2026-08-02 精确分母最终修复之前的代理器件实验，仅用于说明优化演进；v3.0 签核结果以 `reports/v2.6_causal_dualtile/` 和实体板日志为准。

验证日期：2026-08-02  
工具：Vivado 2025.2  
代理器件：XCZU3EG-SBVA484-1-E（Zynq UltraScale+，速度级 -1）  
时钟约束：150 MHz / 6.666 ns  
参数：`MAX_LEN=128`，其余为 `softmax_bf16` 默认参数

归档基线使用修改前工程 ZIP 内 SHA-256 为 `f82a506f0c45d4f849cf5de011edf84a28dcb0d241d3b1372bc7d6ad753c87af` 的 Softmax。表中的 Online 版本是当时的实验快照，不是当前 v3.0 RTL；两者使用相同 LUT、约束、Vivado 版本和实现脚本。

## 结果

| 指标 | 原 Softmax | Online Softmax | 变化 |
|---|---:|---:|---:|
| 128 元素行周期 | 1202 | 332 | **-72.38%** |
| 150 MHz 行处理率 | 124,792 rows/s | 451,807 rows/s | **3.62x** |
| Post-route WNS | +1.797 ns | +0.257 ns | 两者均通过 |
| CLB LUT | 815 | 1249 | +434 / +53.25% |
| LUT as Memory | 100 | 69 | -31 / -31.00% |
| CLB Register | 390 | 937 | +547 / +140.26% |
| DSP | 2 | 2 | 不变 |
| BRAM | 0 | 0 | 不变 |
| 未布线网络 | 0 | 0 | 通过 |
| DRC errors | 0 | 0 | 通过 |

按 post-route WNS 粗略反推的代理器件极限频率约为原版 205.38 MHz、Online 版 156.03 MHz。即使让两版分别运行在该代理实现的估算极限频率，Online 行处理率仍约为原版的 **2.75x**。该 Fmax 推算仅用于趋势比较，不是签核频率。

## 结论与边界

Online Softmax 在较慢的 Zynq UltraScale+ -1 代理器件上完成真实布局布线并满足 150 MHz，因此“周期减少但频率不足”的风险已得到实证排除。它保持 DSP 和 BRAM 数量不变，并删除了原版 128x16 `exp_mem`，代价是在线状态和弹性流水线增加 LUT/寄存器。

代理 OOC 实现不包含整机拥塞、跨模块布线和目标 XCZU15EG 的器件上下文，不能替代 XCZU15EG-FFVB1156-2-I 的整机 implementation、bitstream 和板级测试。

原始证据：

- `baseline/utilization_route.rpt`
- `baseline/timing_summary_route.rpt`
- `baseline/drc_route.rpt`
- `online/utilization_route.rpt`
- `online/timing_summary_route.rpt`
- `online/drc_route.rpt`
