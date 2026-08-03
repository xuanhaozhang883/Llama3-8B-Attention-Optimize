# FPT 当前状态

## 当前正式版本：v3.0-online-softmax-exact-denominator-board-pass

对外交付名称：`FPT_XCZU15EG_Attention_v3.0_Softmax`。

v3.0 基于 v2.6 Causal Dual-Tile，通过跨行 ready/valid 修复和精确分母校正关闭了 Online Softmax 的两个板级问题。最终硬件、Vitis 应用和实体板 10-run 已形成闭环。

## 完成状态

- RTL 修复：完成；
- Vivado 2024.2 XSIM：全部通过；
- 与归档旧 Softmax：1024/1024 BF16 概率逐比特一致；
- 完整 Softmax→PV：65536 概率、524288 Context 通过；
- XCZU15EG 综合、实现、时序、DRC：通过；
- BIT/XSA：生成并固定哈希；
- Vitis platform、FSBL、PMUFW、A53 ELF：重建通过；
- warm-up correctness gate：通过；
- 正式运行：10/10 正确、10/10 确定；
- Combined failures：0。

## 板测摘要

| 指标 | v3.0 结果 |
|---|---:|
| Exact mismatches | 225853 / 524288 |
| Strict abs failures | 7 |
| 1 ULP rescued | 7 |
| Combined failures | 0 |
| 最大 BF16 距离 | 1 ULP |
| 最小延迟 | 429.393123 ms |
| 平均延迟 | 429.393630 ms |
| 最大延迟 | 429.394143 ms |
| Total PL cycles | 64,408,268 |
| PL 时钟 | 149.998 MHz |
| Effective QK+PV | 0.625 GFLOP/s |
| Error bitmap / causal flags | 0 / 0 |

固定计数：QK `2112/1984`，PV `4227072/4161536`，Native TILE4 `4194304`，Context `524288`。

## 实现签核

| 指标 | 结果 |
|---|---:|
| Vivado/Vitis | 2024.2 |
| Part | xczu15eg-ffvb1156-2-i |
| WNS / TNS | +1.327 ns / 0 ns |
| WHS / THS | +0.010 ns / 0 ns |
| DRC Error / Critical Warning | 0 / 0 |
| Total LUT / FF | 32,797 / 66,443 |
| RAMB36 / RAMB18 | 173 / 5 |
| DSP | 267 |

## 最终产物

- BIT：`export/fpt_attention_board_v30_causal_dualtile.bit`
- XSA：`export/fpt_attention_board_v30_causal_dualtile.xsa`
- SHA-256：见 `doc/V3_0_RELEASE_SHA256.md`
- 串口日志：`logs/v3.0_online_softmax_exact_denom_10run_pass.txt`
- 报告：`reports/v2.6_causal_dualtile/`

内部工程/Tcl 继续使用 v26 名称，这是构建兼容标识，不代表当前发布版本。

## 历史状态

- v2.3：冻结功能基线，1843.689 ms；
- v2.4：Profiling counters 板级通过；
- v2.5：跨 Group Ping-Pong；
- v2.6：Causal Dual-Tile 板级通过，约 430.002 ms；
- v3.0：Online Softmax 精确分母最终交付，429.393630 ms。

