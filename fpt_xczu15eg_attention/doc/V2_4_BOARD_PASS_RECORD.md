# v2.4 XCZU15EG 实体板通过记录

验证日期：2026-07-29  
版本：`v2.4-profile-counters-board-pass`

## 配置与口径

- 8 GQA Groups、32 Q Heads、8 KV Heads；
- SEQ_LEN=128、HEAD_DIM=128、BF16；
- 测量范围：START MMIO pulse 到 ST_DONE observed；
- Host Q/K/V load 和 cache flush 不计入加速器延迟；
- 预热 1 次、正式测量 10 次；
- 正确性判据：`abs_error <= 1e-4 OR BF16_distance <= 1 ULP`。

## 正确性

| 指标 | 结果 |
|---|---:|
| 正确运行 | 10 / 10 |
| 确定性运行 | 10 / 10 |
| Exact mismatches | 225,853 / 524,288 |
| Strict abs failures | 7 |
| 1 ULP 挽救 | 7 |
| Combined failures | 0 |
| 最大绝对误差 | 0.000122070 |
| 最大 BF16 距离 | 1 ULP |
| Error detail bitmap | 0x00000000 |

结果通过组合误差判据，但不是 bit-exact。

## 性能

| 指标 | 结果 |
|---|---:|
| 最小延迟 | 1843.688 ms |
| 平均延迟 | 1843.689 ms |
| 最大延迟 | 1843.689 ms |
| 标准差 | 0.000 ms |
| 峰峰抖动 | 0.001 ms |
| 平均 PL 周期 | 276,550,484 |
| 实测 PL 时钟 | 149.998 MHz |
| Context throughput | 284,368 elements/s |
| GQA Group rate | 4.339 groups/s |
| Effective QK+PV | 约 0.1456 GFLOP/s |

## 细粒度计数器

| Counter | Average cycles | 占总周期 |
|---|---:|---:|
| RoPE busy | 156,648,571 | 56.643% |
| QK busy | 133,431,296 | 48.248% |
| Mask/reorder busy | 133,266,432 | 48.188% |
| Softmax busy | 4,916,224 | 1.777% |
| B+C probability replay | 133,712,712 | 48.350% |
| TILE2→TILE4 capture | 156,648,555 | 56.643% |
| Real PV busy | 119,799,808 | 43.319% |
| Context transfer | 524,288 | 0.189% |
| B+C / real-PV overlap | 0 | 0.000% |
| Core stage idle | 2 | 0.000% |
| Real-PV feed stall | 115,605,520 | 41.802% |
| Inter-stage wait | 24 | 0.000% |

Busy、wait、stall 和 overlap 计数允许重叠，不能相加作为排他阶段。

## PPA

| 指标 | v2.3 | v2.4 | 增量 |
|---|---:|---:|---:|
| LUT | 51,224 | 51,679 | +455（+0.89%） |
| FF | 36,796 | 36,888 | +92（+0.25%） |
| BRAM Tile | 99.5 | 99.5 | 0 |
| DSP | 136 | 136 | 0 |
| WNS | +1.023 ns | +1.146 ns | +0.123 ns |

## 结论

v2.4 已完成 XCZU15EG 实体板闭环验证，满足 10/10 正确、确定性、
时序收敛和资源增量小于 1% 的验收标准。计数器证明当前主要优化机会不是
DDR，而是缺少 B+C/PV overlap 以及 41.802% 的 Real-PV feed stall。

证据：

- `../logs/v2.4_hardware_profile_10run.txt`
- `../reports/profile_v2.4/v24_performance_runs.csv`
- `../reports/profile_v2.4/v24_hardware_profile_runs.csv`
- `../reports/profile_v2.4/v24_board_test_summary.md`
