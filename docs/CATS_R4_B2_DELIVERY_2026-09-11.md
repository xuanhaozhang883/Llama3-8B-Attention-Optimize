# CATS-R4 B2 成员 B 最终本地交付记录（2026-09-11）

## 状态

- 阶段：`B2 整行 Softmax / exp / sum / reciprocal / shared stager`。
- 状态：`B-OWNED GATES PASS / READY TO COMMIT / B3 ENTRY APPROVED`。
- 分支：`member-b-cats-r4-a2-integration`。
- 测试基线 HEAD：`a26cdc5ee64e12884fc9e529213ba6630202356b`。
- 接口基线：`4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`
  (`CATS_R4_INTERFACE_V3_COMMIT`)。
- A 的 abort/cancel commit `a26cdc5ee64e12884fc9e529213ba6630202356b`
  仍需 A/队长完成独立接收；这是团队集成项，不改变 B-owned B2 算术与时序门禁结论。
- 未接 production manifest、公共 top 或 board top；没有把软件结果写成硬件结果。

本记录替代 2026-09-10 记录中的负 WNS checkpoint。Accuracy exp 流水、shared
stager counter path 和 reset 语义修复后，Icarus、XSim 与 150 MHz OOC 均已重跑。

## 冻结实现

- Compatibility：保留项目 BF16 score/max、Q15 exp、BF16 weight 与既有倒数语义。
- Accuracy：BF16 RNE score/max 输入；固定范围缩减、33 项 Q31 LUT 与线性插值生成
  FP32 weight；FP32 key-order row sum 与 RNE reciprocal。
- Compatibility/Accuracy 在 finalize 前仲裁，并共享唯一 `3×128×32-bit` scheme-A
  stager。128 个 weight、sum 和 inv_sum 全部成功后才开始发布；错误行对 C 零写。
- mode 在 row/slot owner 建立时锁存；不按输入内容、row 或测试身份重选模式。
- score/exp issue 的持续三行回归实测 II=1；reciprocal 行尾 stall 有独立 counter。
- `rst_n` 保持异步复位，`clear/counter_clear` 为同步清除；已消除综合报告中的同优先级
  set/reset 风险。

关键源码 SHA-256：

| 文件 | SHA-256 |
|---|---|
| `cats_r4_b2_shared_stager_v3_wrapper.sv` | `FE3F3BD8749B0F66573CB36214093AD848A26D4A3F88AD9E5E231B86CAC1C68D` |
| `cats_r4_b2_weight_stager.sv` | `946E073137F6E1E145316EB8AF88911ECDD6F57E0AEF08176F62BBE7B09652E6` |
| `cats_r4_row_softmax_accuracy.sv` | `B7D1F82B457D369CAE7F878A5B606909A36FB4992D5E932315E3CFB293F26C34` |
| `cats_r4_row_softmax_compatibility.sv` | `2A353FAB24EC68FE07DCA657F9A46F461CF56D0862645BF5BFB623E93B96C6A8` |
| `cats_r4_b2_accuracy_fixed_model.py` | `90C0C936DC7EA0F72806101E786622DE50F88F377A97C9B390FBDA80E5BC325B` |

## 数值与协议结果

软件 Accuracy stress（seed `20260905`）覆盖 32 cases/4096 elements：
`combined_failures=0`。软件 full 覆盖 4096 rows、264192 exp、524288 Context
elements：`combined_failures=0`；最坏绝对误差 `0.0001220703125`，不同结果和严格
失败统计见 2026-09-10 记录。以上是软件候选结果，不是 RTL/硬件 bit-exact 结论。

Icarus 五 seed `7,19,73,101,313` 协议回归全部 PASS。覆盖 row/score/C-side 随机
反压、mode busy 期间变化、三槽、clear、旧 epoch、错误 token/mode/last、错误行零写、
publish/commit/release 守恒。直接算术单测与 A serializer 的 Compatibility/Accuracy
系统回归保持 PASS。

Vivado 2025.2 XSim：

| 回归 | rows | scores | writes | commits/releases | error |
|---|---:|---:|---:|---:|---:|
| Accuracy equal full | 4096 | 264192 | 524288 | 4096/4096 | 0 |
| Accuracy stored Q/K/RoPE full | 4096 | 264192 | 524288 | 4096/4096 | 0 |
| Compatibility full | 4096 | 264192 | 524288 | 4096/4096 | 0 |
| shared protocol stress | 3 | 6 | 256 | 2/3 | 定向错误计数与预期一致 |

原始 XSim 证据：

- `artifacts/b2_shared_accuracy_full_xsim_equal_20260911_154500/xsim.log`
- `artifacts/b2_shared_accuracy_full_xsim_stored_20260911_154200/xsim.log`
- `artifacts/b2_shared_compatibility_full_xsim_20260911_154700/xsim.log`
- `artifacts/b2_shared_protocol_stress_xsim_20260911_160000/xsim.log`

## Vivado 2025.2 OOC

- top：`cats_r4_b2_shared_stager_v3_wrapper`
- part：`xczu15eg-ffvb1156-2-i`
- constraint：`6.666 ns`，报告频率 `150.015 MHz`
- synthesis：Complete
- WNS/TNS：`+0.320 ns / 0.000 ns`
- setup failing endpoints：`0 / 41869`
- unconstrained path table：空
- 最坏 data path delay：`6.336 ns`（logic `1.586 ns`，route `4.750 ns`）
- CLB LUT：`12747`（3.74%）
- CLB Registers：`16858`（2.47%）
- DSP48E2：`3`（0.09%）
- BRAM/URAM：`0/0`
- Vivado summary：`0 Errors / 0 Critical Warnings / 115 ordinary Warnings`

证据目录：`artifacts/b2_shared_ooc_final_resetfix_20260911_181000/`。这些是 OOC
综合面积和时序估计，不称为实现后 PPA；实现后 placement/routing 与基于活动文件的 power
仍属于 B4/system integration 证据。

## 可复现命令

```powershell
tests/run_cats_r4_b2_accuracy_fixed_model.ps1
tests/run_cats_r4_b2_shared_stager_v3_iverilog.ps1
tests/run_cats_r4_b2_shared_accuracy_full_iverilog.ps1
tests/run_cats_r4_b2_shared_compatibility_full_iverilog.ps1
E:\vivado_25_2\2025.2\Vivado\bin\vivado.bat -mode batch -source scripts/cats_r4_b2_softmax_ooc.tcl -tclargs . <fresh-output-root> 6.666
git diff --check
```

XSim 使用对应 artifact 中的 compile/elaborate/run 文件复查；协议压力的原始编译与运行
记录保存在 `artifacts/b2_shared_protocol_stress_xsim_20260911_160000/`。

## 交接与限制

- B2 的 B-owned gate 已闭合并允许进入 B3；不代表 A abort commit 已完成团队接收，
  也不代表 C weight memory service 或 board/system top 已集成。
- combined gate PASS 不是 bit-exact；未修改 golden、阈值或原始输入。
- B3 应消费 V3 的 `pv_row/weight_rd/weight_release` 与 v1 V service，最终 Context 接受且
  outstanding=0 后才 release。
