# 状态

## 当前已验证版本：v2.4-profile-counters-board-pass

`FPT_XCZU15EG_Attention_Board_v2.0` 是历史目录名。当前最新实体板通过版本为
**v2.4-profile-counters-board-pass**；**v2.3-board-profile** 继续保留为
不可破坏的回退基线。

## v2.4 已完成

- 8 Group、32Q/8KV、SEQ_LEN=128、HEAD_DIM=128、BF16 完整链路；
- RoPE → QK → causal mask → Softmax → real PV → Context DDR；
- GPIO page 27～39 细粒度计数器及 A53/Python 解析链路；
- Vivado 2024.2 RTL elaboration、综合、实现、DRC、Bitstream 和 XSA；
- Vitis 2024.2 A53 应用构建、JTAG 编程和 ELF 下载；
- XCZU15EG 实体板预热 1 次、正式测量 10 次；
- 正确运行 10/10，确定性结果 10/10，Combined failures = 0；
- 最大绝对误差 0.000122070，最大 BF16 距离 1 ULP；
- 平均延迟 1843.689 ms，平均 PL 周期 276,550,484；
- 实测 PL 时钟 149.998 MHz，WNS +1.146 ns，TNS 0；
- LUT 51,679，FF 36,888，BRAM Tile 99.5，DSP 136。

相对 v2.3，v2.4 增加 455 LUT（约 0.89%）和 92 FF（约 0.25%），
BRAM/DSP 不变；平均延迟和总周期基本不变，满足“观察逻辑不改变数值通路、
资源增量小于 1%”的验收目标。

## v2.4 主要 Profiling 结论

- B+C / real-PV overlap：0 cycles，当前跨阶段调度仍为串行；
- Real-PV feed stall：115,605,520 cycles，占总周期 41.802%；
- QK busy：133,431,296 cycles，占 48.248%；
- Softmax busy：4,916,224 cycles，占 1.777%；
- DDR read/write master busy 均低于总周期 0.2%；
- Context transfer：524,288 cycles，等于每次接收的 Context word 数；
- Error detail bitmap：每次均为 0。

因此阶段2应优先实现 B+C/PV 跨 Group 双缓冲，并消除 Real-PV feed stall；
DDR 和单独 Softmax 不是当前首要瓶颈。

## 验证证据

- v2.3 原始记录：`logs/v2.3_hardware_profile_10run.txt`
- v2.4 UART 机器可读记录：`logs/v2.4_hardware_profile_10run.txt`
- v2.4 逐次 CSV：`reports/profile_v2.4/v24_performance_runs.csv`
- v2.4 硬件计数器 CSV：`reports/profile_v2.4/v24_hardware_profile_runs.csv`
- v2.4 汇总：`reports/profile_v2.4/v24_board_test_summary.md`
- 板级通过记录：`doc/V2_4_BOARD_PASS_RECORD.md`

## 正确性表述

v2.4 使用以下组合判据：

```text
abs_error <= 1e-4 OR BF16_distance <= 1 ULP
```

Exact mismatches 为 225,853 / 524,288，其中 7 个严格绝对误差失败均被
1 ULP 判据挽救。因此结论是“通过组合误差判据”，不得描述为 bit-exact。
