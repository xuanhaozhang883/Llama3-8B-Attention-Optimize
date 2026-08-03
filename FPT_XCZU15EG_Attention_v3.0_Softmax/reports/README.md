# Vivado 与板测报告索引

## 当前 v3.0 发布

`v2.6_causal_dualtile/` 保留内部工程兼容目录名，当前五份主要报告来自最终 v3.0 精确分母版 Vivado 2024.2 实现：

- `timing_summary_impl.rpt`：WNS +1.327 ns、WHS +0.010 ns、TNS/THS 0；
- `utilization_impl.rpt`：32,797 LUT、66,443 FF、173 RAMB36、5 RAMB18、267 DSP；
- `utilization_synth.rpt`；
- `drc_impl.rpt`：0 Error、0 Critical Warning；
- `power_impl.rpt`：4.490 W vectorless estimate。

`v2.6_causal_dualtile/archive_online_2025_2/` 保存最终修复前的 Online Softmax 2025.2 报告，仅用于历史对照，不对应 v3.0 BIT/XSA。

最终实体板结果见：

- `../doc/BOARD_PASS_RECORD.md`
- `../logs/v3.0_online_softmax_exact_denom_10run_pass.txt`
- `../doc/V3_0_RELEASE_SHA256.md`

## 历史报告

- `baseline_v2.3/`：v2.3 冻结基线；
- `profile_v2.4/`：v2.4 Profiling counters 板级通过记录；
- `online_softmax_ooc_proxy/`：早期 Online Softmax OOC 代理器件验证。

