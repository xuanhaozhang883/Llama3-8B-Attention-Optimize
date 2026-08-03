# v3.0 XCZU15EG 实体板通过记录

## 配置

- 版本：`v3.0-online-softmax-exact-denominator-board-pass`
- 8 GQA groups，32Q/8KV，SEQ_LEN=128，HEAD_DIM=128，BF16
- QK_LANES=2，CAPTURE_TILE=4，PV_LANES=2
- Vivado/Vitis 2024.2，XCZU15EG-FFVB1156-2-I
- 测量范围：START MMIO pulse 至 ST_DONE
- Host Q/K/V load 与 cache flush 不计入加速器延迟
- warm-up 1 次，正式测量 10 次
- 判据：`abs_error <= 1e-4 OR BF16_distance <= 1 ULP`

## 正确性

```text
Correct runs              : 10 / 10
Deterministic result runs : 10 / 10
Exact mismatches          : 225853 / 524288
Strict abs failures       : 7
Strict failures rescued   : 7
Combined failures         : 0
Maximum absolute error    : 0.000122070
Maximum BF16 distance     : 1 ULP
Error detail bitmap       : 0x00000000
Causal error flags        : 0x00000000
```

错误分布与已通过的 v2.6 数值基线一致。此前 Online 四路归约产生的两个 2/4 ULP 点已经通过精确分母校正消除，未修改黄金向量或容差。

## 性能

```text
Minimum latency       : 429.393123 ms
Average latency       : 429.393630 ms
Maximum latency       : 429.394143 ms
Latency stddev        : 0.000252 ms
Peak-to-peak jitter   : 0.001020 ms
Total PL cycles       : 64,408,268
Inferred PL clock     : 149.998 MHz
Context throughput    : 1,220,996 elements/s
GQA group rate        : 18.630 groups/s
Effective QK+PV rate  : 0.625 GFLOP/s
```

相对 v2.3/v2.4 的 1843.689 ms，端到端加速约 4.29×。相对 v2.6 原数值通路的 430.002 ms，v3.0 略快约 0.608 ms。

## 平均硬件计数

| 指标 | 结果 |
|---|---:|
| Total PL cycles | 64,408,268 |
| Core run cycles | 64,339,288 |
| B+C/RoPE-QK-Softmax busy | 60,218,547 |
| Real PV busy | 32,964,608 |
| Softmax busy | 1,819,064 |
| B+C / real-PV overlap | 28,844,026 |
| Context transfer | 524,288 |
| DDR read commands / beats | 5,121 / 196,608 |
| DDR write commands / beats | 1,024 / 131,072 |
| Context words accepted | 524,288 |

固定架构计数：

| 指标 | 实测 | 预期 | 状态 |
|---|---:|---:|---|
| QK tiles computed | 2,112 | 2,112 | PASS |
| QK tiles skipped | 1,984 | 1,984 | PASS |
| Masked QK tiles emitted | 1,984 | 1,984 | PASS |
| PV terms computed | 4,227,072 | 4,227,072 | PASS |
| PV terms skipped | 4,161,536 | 4,161,536 | PASS |
| Native TILE4 vectors | 4,194,304 | 4,194,304 | PASS |

## 实现签核

| 指标 | 结果 |
|---|---:|
| WNS / TNS | +1.327 ns / 0 ns |
| WHS / THS | +0.010 ns / 0 ns |
| DRC Error / Critical Warning | 0 / 0 |
| Total LUT | 32,797 |
| FF | 66,443 |
| RAMB36 / RAMB18 | 173 / 5 |
| DSP | 267 |
| Vectorless power | 4.490 W |

## 最终产物

- BIT：`export/fpt_attention_board_v30_causal_dualtile.bit`
- XSA：`export/fpt_attention_board_v30_causal_dualtile.xsa`
- 哈希：`doc/V3_0_RELEASE_SHA256.md`
- 串口日志：`logs/v3.0_online_softmax_exact_denom_10run_pass.txt`
- Vivado 报告：`reports/v2.6_causal_dualtile/`（内部兼容目录名）

## 结论

v3.0 在 XCZU15EG 上完成实体板闭环验证：warm-up PASS、10/10 正确、10/10 确定、Combined failures=0，全部结构计数、时序和 DRC 满足交付要求。

