# CATS-R4 项目交接状态（2026-09-07）

## 结论

本次按技术依赖整理当前工作，不沿用 `STEP_BY_STEP_PROMPTS_CN.md` 中的人员分工。当前工作树形成了 A 侧 QK 本地候选、C 侧 QKV banking/AXI bridge 本地候选，以及对应的直接仿真/OOC 证据；B 侧 CATS-R4 Softmax/PV 生产实现尚未开始。所有新增候选仍标记为 `LOCAL CHECKPOINT / NOT READY`，没有接入 production manifest、board/system top，也没有生成新的 BIT/XSA/ELF。

## Git 身份

- 分支：`codex/cats-r4-local-integration`
- 整理前 HEAD：`ca7dac8 C2: record Q slab DMA checkpoint / NOT READY`
- 远端：`https://github.com/xuanhaozhang883/Llama3-8B-Attention-Optimize.git`
- 本交接提交：见本文件对应 Git commit（推送后以远端 SHA 为准）
- 最新 C contract-only checkpoint：`4ad3c7e7cf80e2f570ebb0f0eb94eff1470a97ed`

## A/B/C 完成矩阵

| 线别 | 已完成 | 证据 | 当前状态 |
|---|---|---|---|
| A：QK/scheduler/FP32 accumulator | 32-lane、R=16、多上下文 tag scheduler；Q/K 两拍 response；causal lane mask；MAC completion tag；FP32 accumulator context isolation；score FIFO backpressure；集成 engine mock regression；score formatter 独立候选（FP32 scale、RNE BF16、mask/tag/backpressure） | `rtl/core/bc/qk/`、对应 `tb/`、Icarus/XSim/OOC 检查点；真实 Floating-Point IP OOC：0 errors、0 critical warnings、WNS +2.528 ns @150 MHz、LUT 20,058、FF 44,971、DSP 128 | `LOCAL CHECKPOINT / NOT READY`。尚未闭合整行 score/max slab ownership、full-size aggregate、生产 cluster 接线和 READY marker；仍有普通 warning，`HD.CLK_SRC` 缺失 |
| B：Softmax/PV | 仅保留已有 CATS-R4 接口/系统契约、legacy/online 参考逻辑及转换器 | 当前没有 A2/B2 整行 Softmax、Compatibility/Accuracy 数值模式、32-lane PV、full-size 数值回归、exp/reciprocal counter closure 或 PV aggregate counter | `NOT STARTED / NOT READY`。不得把 legacy 模块称为 CATS-R4 B 完成 |
| C：memory/AXI/banking | QKV banked memory、AXI bank bridge、Q/K/V beat counter；protocol-only 正负向 XSim 证据；default XPM static elaboration；bridge OOC 约 LUT 2,052、FF 1,423、BRAM 100、WNS +3.372 ns | `rtl/core/cluster/`、对应 `tb/`、Vivado 脚本和 OOC Tcl；本轮复跑 protocol-only Icarus PASS | `LOCAL CHECKPOINT / NOT READY`。尚未完成 C2 memory service、CDC/DMA/output queue、board/system top、production manifest、full-board implementation、DRC/timing、BIT/XSA/ELF 或上板验证 |

## 本轮直接复核

- formatter Icarus：PASS（scale、RNE BF16、lane mask、tag、counter、output backpressure）。修正了测试对 masked lane 的错误期望：masked lane 的 scaled FP32 输出为零。
- integrated QK engine Icarus：PASS。
- 32-lane/R=16 scheduler Icarus：PASS。
- QKV AXI bank bridge protocol-only Icarus：PASS，包含正向 Q/K/V beat 完成和 `NEGATIVE_GATE_DONE`。
- C contract-only 包：PASS，新增默认 bridge 行为模型下的 Q/K/V readback、三路固定两周期响应断言、reset/token mismatch 门禁，以及参数化 bank mapping 回归。
- C2 build preflight：PASS，确认 build root 必须是 checkout 外的新建 ASCII 路径；未修改 production manifest/top/BD/constraints。
- `git diff --check`：PASS。
- 直接编译 bridge 的 default XPM 模式不使用 Icarus 作为通过依据；该模式依赖 Vivado `xpm` 仿真库，已有 Vivado 脚本负责 static elaboration。

## 尚未通过的门禁与禁止事项

1. A 不能称为 A2 READY：缺少 score/max slab ownership、full-size aggregate counter closure、完整 production wrapper 和全时钟约束闭合。
2. B 未开始：不得启动依赖 B READY 的 A3/C2 集成，不得把 legacy/online 逻辑写入 CATS-R4 完成矩阵。
3. C 不能接入 production manifest、board/system top、BD 或 constraints；不得生成 BIT/XSA/ELF，不得上板。
4. 任何本地仿真、blackbox OOC 或单个 bridge OOC 结果都不能写成 full-board timing、bit-exact 或板测结果。
5. v3.1.4 的 303.120724 ms、10/10 correct/deterministic 仍是稳定 fallback，不是 CATS-R4 证据。

## 推荐的下一步顺序

1. 先冻结 A 的 score/max slab ownership、commit/last/mask/epoch 契约，并补 full-size aggregate 计数证据。
2. 再实现并验证 B2 整行 Softmax（Compatibility/Accuracy 明确分模式），闭合 exp/reciprocal counter。
3. 再实现 B3 32-lane PV 与行末归一化，闭合 PV MAC 和 Context words 计数。
4. 只有 A/B READY 后，才把 C 的本地 memory/AXI/CDC 候选接入单 cluster wrapper；随后新建干净 build root 做 full-board synthesis/implementation/Timing/DRC。
5. 150 MHz full-board 通过后，才可独立尝试 200 MHz；所有 BIT/XSA/ELF 必须来自同一 manifest/Git 身份链。

## 本次整理涉及的文件

- A：`rtl/core/bc/qk/cats_r4_qk_32lane_{scheduler,fp32_service,engine}.sv`、`cats_r4_qk_score_formatter.sv` 及对应 TB/脚本。
- C：`rtl/core/cluster/cats_r4_axi64_qkv_banked_mem.sv`、`cats_r4_qkv_axi_bank_bridge.sv` 及对应 TB/OOC/Vivado 脚本。
- 文档：A2/C2 checkpoint 与 `CATS_R4_C2_PREFLIGHT_2026-09-06.md`。
- C 审计：`docs/CATS_R4_C_CONTRACT_AUDIT_2026-09-07.md`。
- 本文件：当前交接总览与下一步依赖。

生成物、Vivado 临时目录、绝对路径 build root、许可证、BIT/XSA/ELF 均未加入本次提交。
