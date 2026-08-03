# v3.0 Online Softmax 优化与验证记录

## 1. 目标与最终结构

v3.0 基于 v2.6 Causal Dual-Tile，仅修改 Softmax 内部实现和相关验证。模块接口、BF16 数据格式、causal mask、元数据和上下游结构保持不变。

最终实现包含：

- 两级弹性输入流水，每周期接受一个 score；
- 输入过程中记录最终全局最大值并保存 score/mask；
- 流水化精确分母扫描，按列序累加 `exp(max-score)` 的 Q1.15 LUT 值；
- restoring divider 生成 Q1.30 倒数；
- 六级可停顿输出流水，每周期输出一个 BF16 概率。

单行仿真延迟为 443 cycles，归档旧版约 1202 cycles，减少约 63.1%。

## 2. 问题发现与修复

### 2.1 跨行 ready/valid

初版 Online Softmax 在上一行最后输出握手时清除 raw/load valid，导致已经被 `in_ready` 接收的下一行前两个元素丢失。板级错误表现：

- Context 524288/524288 不匹配且实际为零；
- PV MAC 和 DDR write 为 0；
- error bitmap `0x000004C0`；
- metadata 从 col2 开始。

修复原则：正常行结束不清除已握手流水拍；仅复位和异常恢复清空。

### 2.2 四路 Online 分母精度

结构修复后，完整计算链路恢复，但四路 `(m,l)` 的定点重标定改变舍入顺序。板级 warm-up 有 9 个严格绝对误差点，其中 7 个为 1 ULP，另外两个为 2/4 ULP，Combined failures=2。

最终改为精确分母校正扫描。每个分母项、EXP 地址和整数累加顺序与归档旧 Softmax 一致；判据和黄金数据不变。

## 3. 仿真证据

| 测试 | 结果 |
|---|---|
| BF16 Softmax 功能与背压 | PASS |
| 元数据及全 mask | PASS |
| 连续 4 行 | 512 输入 / 512 输出 PASS |
| 完整 Softmax→PV | 65536 概率 / 524288 Context PASS |
| 归档旧版完整行等价 | 1024 / 1024 BF16 逐比特一致 |
| v2.6 架构静态检查 | PASS |

归档参考 Softmax SHA-256：

`f82a506f0c45d4f849cf5de011edf84a28dcb0d241d3b1372bc7d6ad753c87af`

最终 Softmax SHA-256：

`a75940db10016ed5e330f7e35ed3fa690f4eea47a7a643185440a790c4571249`

## 4. Vivado 2024.2 签核

目标：`xczu15eg-ffvb1156-2-i`，150 MHz。

| 指标 | 结果 |
|---|---:|
| WNS / TNS | +1.327 ns / 0 ns |
| WHS / THS | +0.010 ns / 0 ns |
| DRC Error / Critical Warning | 0 / 0 |
| Total LUT / FF | 32,797 / 66,443 |
| RAMB36 / RAMB18 | 173 / 5 |
| DSP | 267 |
| Power | 4.490 W（vectorless） |

最终产物：

- BIT SHA-256：`a770ccb457e30b32bcb7aa4270f2bca4a8c784369b752370b0631841628db31f`
- XSA SHA-256：`a1956de4a740be0b06c2824cc74e6eb03dce904775ca07daaf60caef713ec8f1`

## 5. 板级结果

warm-up 及正式 10-run 全部通过：

| 指标 | 结果 |
|---|---:|
| Correct / deterministic | 10/10 / 10/10 |
| Exact mismatches | 225853 / 524288 |
| Strict failures / 1 ULP rescued | 7 / 7 |
| Combined failures | 0 |
| Max ULP | 1 |
| Average latency | 429.393630 ms |
| Total PL cycles | 64,408,268 |
| Softmax busy | 1,819,064 cycles |
| Effective QK+PV | 0.625 GFLOP/s |

相比四路近似分母结构的 429.369 ms，精确校正几乎不增加整机延迟，因为 Softmax 与其他阶段高度重叠；相比旧数值通路的 430.002 ms 仍略快。

## 6. 可复现命令

```powershell
powershell -ExecutionPolicy Bypass -File tests/run_online_softmax_vivado.ps1 \
  -VivadoRoot C:\Software\AMD\vivado24.2\Vivado\2024.2

powershell -ExecutionPolicy Bypass -File tests/compare_online_softmax_to_archive.ps1 \
  -VivadoRoot C:\Software\AMD\vivado24.2\Vivado\2024.2
```

完整构建继续使用内部兼容入口 `scripts/build_profile_foreground_ipfix.tcl`。每次 XSA 变化后必须重建 Vitis platform 和 ELF。

## 7. 结论

v3.0 同时关闭协议正确性和数值正确性问题。在不放宽容差的前提下恢复旧版逐比特概率，并保留明显优于归档旧 Softmax 的模块吞吐。最终实体板达到 10/10 正确和 10/10 确定。

