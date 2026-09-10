# CATS-R4 成员 A 完成情况统一交接

日期：2026-09-10
接收人：成员 A、成员 B、成员 C/队长、成员 D/独立验证职责

## 交付身份

- owner：成员 A
- branch：`agent/cats-r4-a2-row-handoff`
- base SHA：`7a36930a83ec716349b3dbc6b0bca2856cce7011`
- head SHA（生成本文档时的本地文档 HEAD）：`efa1497ea570b366f7617f1016d5e337a400e0d2`
- A2 technical evidence SHA：`051559ef1edf03e7b3aeed9010c1b4c5bfa577a5`
- 生成本文档时的远端 HEAD：`91984c47747ae2d282529574a29c59930d0f6c57`
- consumed interface tag：`CATS_R4_INTERFACE_V3_COMMIT`
- interface tag resolved SHA：`4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`
- work status：`IN PROGRESS`（A2 工作包已完成；仅保留评审缺陷修复和跨成员集成支持）
- signoff：**A 单元/OOC READY；整板/生产集成 NOT READY**

本文档的 READY 只覆盖成员 A 负责的 QK、scheduler、score/max、formatter、
row handoff 和对应 OOC 证据，不代表 B、C、D 已确认，也不授权直接合并 `main`。

## A 已完成的工作

- 32-lane QK scheduler、FP32 service 边界和 backpressured score FIFO。
- Q-slab need/ready/retire 生命周期，覆盖完整 256 个 slab 和 6144 个 engine job。
- `1/sqrt(128)` FP32 scaling、BF16 RNE score formatter 和全局 row max。
- 三 slot row assembly、score store、A→B row/score 双通道交接。
- A/B slot ownership、最终释放后复用、reset/clear 和旧 epoch 丢弃。
- token/key/last、非有限 score 和协议错误的 buffered abort 通知。
- legacy lane-1/2/4/8 Icarus elaboration 问题修复及等价性回归。
- full-size causal score golden candidate 生成器、产物和一致性测试。
- Vivado 2025.2 real Floating Point IP 150 MHz OOC 综合和证据归档。

主要源码：

- `rtl/core/bc/qk/cats_r4_qk_32lane_scheduler.sv`
- `rtl/core/bc/qk/cats_r4_qk_32lane_engine.sv`
- `rtl/core/bc/qk/cats_r4_qk_q_slab_client.sv`
- `rtl/core/bc/qk/cats_r4_qk_score_formatter.sv`
- `rtl/core/bc/qk/cats_r4_qk_row_assembler.sv`
- `rtl/core/bc/qk/cats_r4_qk_ab_handoff.sv`
- `rtl/core/bc/qk/cats_r4_qk_slot_lifecycle.sv`
- `rtl/core/bc/qk/cats_r4_qk_row_abort_arbiter.sv`
- `rtl/core/bc/qk/cats_r4_qk_row_handoff_wrapper.sv`
- `rtl/core/bc/qk/cats_r4_qk_a2_row_pipeline.sv`

详细文件、TB 和 runner 清单见
`docs/CATS_R4_A2_HANDOFF_TO_C_2026-09-09.md`。

## 冻结的 A→B 接口

Row channel 使用 `valid/ready`：

`epoch[15:0], group[2:0], global_q_head[4:0], row[6:0], slot_id[1:0], numeric_mode[1:0], row_max_bf16[15:0]`

Score channel 使用 `valid/ready`、同一组 token，以及：

`key[6:0], score_bf16[15:0], last`

已验证：row max 覆盖全部合法 `key=0..row`；score 严格递增；`last` 仅在
`key=row`；score/max 已经过 BF16 RNE；backpressure 时 payload 稳定；
numeric mode 在行开始锁存；最终 score 握手和 matching owner handoff 后
A→B；matching `final_release` 后 slot 才能复用。

## 验证结果和 counter

| 项目 | 预期 | 实际 | 状态 |
|---|---:|---:|---|
| full workload rows | 4096 | 4096 | PASS |
| valid causal scores | 264192 | 264192 | PASS |
| Q slabs | 256 | 256 | PASS |
| engine jobs | 6144 | 6144 | PASS |
| legacy equivalence scores | 2048 | 2048 | PASS |
| candidate golden scores | 264192 | 264192 | PASS（完整性）；未冻结 |
| Python golden tests | 2 | 2 | PASS |
| OOC WNS | `>=0 ns` | `+1.816 ns` | PASS |
| OOC TNS | `0 ns` | `0.000 ns` | PASS |
| synthesis errors / critical warnings | `0 / 0` | `0 / 0` | PASS |

11 组 A2 回归已全部通过，包括 deterministic/random backpressure、reset、
首末行、full workload、XSim raw-row pipeline 和 legacy multilane。

## tool / device / clock

- Vivado：2025.2 build 6299465
- device：`xczu15eg-ffvb1156-2-i`
- OOC top：`cats_r4_qk_32lane_engine`
- target clock：150.015 MHz（150 MHz 门禁）
- OOC utilization：20166 CLB LUT、44983 CLB register、128 DSP、0 BRAM、0 URAM
- 其他验证：Icarus Verilog、XSim、Python unittest

## numeric mode / error thresholds

- candidate golden numeric mode：`1`
- arithmetic：staged BF16 RoPE、FP32 RNE MAC、FP32 scale
  `0x3DB504F3`、BF16 RNE
- causal ordering：`global_q_head → row → key_0_through_row`
- 协议、ownership、epoch、key/last 和非有限值错误允许数：`0`
- 本交付未定义 B Softmax/PV 的最终数值阈值；该阈值由 B 与 D 的冻结参考决定。

## input hashes / log hashes

- 完整回归日志及 11 个 SHA-256：
  `artifacts/cats_r4_a2_regression_2026-09-10/manifest.json`
- OOC 输入、日志、Tcl、timing/utilization report SHA-256：
  `artifacts/cats_r4_a2_ooc_2026-09-09/manifest.json`
- golden 输入、ordering、numeric mode 和输出 SHA-256：
  `artifacts/cats_r4_a2_score_golden_2026-09-10/manifest.json`
- candidate golden 输出 SHA-256：
  `F2949704CB683D22EBBEE5C6F2ED6B05D1E16149DA3844A2C3E53EEE4515D565`

## reproduction commands

```powershell
tests/run_cats_r4_qk_32lane_engine_iverilog.ps1
tests/run_cats_r4_qk_q_slab_client_iverilog.ps1
tests/run_cats_r4_qk_score_formatter_iverilog.ps1
tests/run_cats_r4_qk_row_assembler_iverilog.ps1
tests/run_cats_r4_qk_ab_handoff_iverilog.ps1
tests/run_cats_r4_qk_slot_lifecycle_iverilog.ps1
tests/run_cats_r4_qk_row_abort_arbiter_iverilog.ps1
tests/run_cats_r4_qk_row_handoff_wrapper_iverilog.ps1
tests/run_cats_r4_qk_a2_row_pipeline_xsim.ps1
tests/run_v312_qk_multilane_checks.ps1
python -m unittest -v tests.test_cats_r4_a2_score_golden

$env:XILINXD_LICENSE_FILE = 'C:/Software/AMD/lic/25.2/vivado.lic'
$env:LM_LICENSE_FILE = $env:XILINXD_LICENSE_FILE
$oocOut = Join-Path $env:TEMP 'cats-r4-a2-ooc-member-review'
tests/run_cats_r4_qk_32lane_engine_realip_ooc.ps1 `
  -VivadoRoot C:/Software/AMD/vivado25.2/2025.2/Vivado `
  -OutputRoot $oocOut
```

## PASS / FAIL / NOT RUN

- PASS：A2 单元、协议、full workload、random backpressure/reset、XSim raw-row、
  legacy multilane、golden 完整性、real-IP OOC。
- FAIL：当前已归档验收集中无失败项。
- NOT RUN：A+B+C production compute-wrapper 全尺寸数值比对、整板 synthesis、
  implementation、timing、DRC、BIT/XSA/ELF。
- failure seed：无失败 seed；已执行用例均 PASS。随机回归日志身份以 regression
  manifest 为准。

## known issues

1. Full-size score golden 状态仍为 `CANDIDATE_NOT_FROZEN`；需要 C/D 独立验证、
   确认或替换后冻结，不能当作项目最终黄金参考。
2. 仓库全局 A 门禁文字仍混有 B-owned FP32 weight 条目，因此本次不修改
   `docs/CATS_R4_RELEASE_GATE.md`；A READY 以本交付的 A-owned 范围为准。
3. A/B/C 尚未在共享集成结果中证明共同消费同一个已解析 interface tag。
4. 当前 READY 不覆盖 production manifest、board top、BD 或 constraints。

## 各成员下一步

- member A：冻结本交付；仅处理可复现的 A-owned 缺陷、评审意见或经协调的
  interface 最小变更，并为任何 RTL 变化重新出具证据。
- member B：基于冻结 row/score channel 接入 Softmax、Accuracy FP32 weight 和
  PV；证明 token、numeric mode、key/last、abort 和 final-release 契约。
- member C/队长：核对本分支与 interface tag，把通过评审的提交分阶段纳入
  `codex/cats-r4-local-integration`；继续 memory/banking、DMA、CDC、output、
  compute wrapper、board 和 Vivado 集成门禁。
- member D/独立验证职责：独立复算或审计 full-size golden、数值阈值、日志来源、
  report hash、异常路径和端到端失败计数。

## next dependency

近期依赖是 C/D 冻结 full-size golden、B 提供 B2/B3 可审查 SHA，以及 C 在共享
集成分支完成 A/B/C wrapper 对接。完成单元和集成证据后，才进入 150 MHz 整板门禁。

本分支可以供 B/C/D fetch、review 或选择性集成，但不得直接合并 `main`；最终主线
合入由 C/队长依据 `docs/CATS_R4_RELEASE_GATE.md` 决定。
