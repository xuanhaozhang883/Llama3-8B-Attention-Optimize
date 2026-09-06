# CATS-R4 C2 单 cluster 预检记录

状态：`BLOCKED AT ENTRY GATE / NOT READY`

日期：2026-09-06

## GitHub 对齐

- remote：`https://github.com/xuanhaozhang883/Llama3-8B-Attention-Optimize.git`
- upstream base：`origin/main@9029158361591da987e19402e408facf94f73078`
- 工作分支：`codex/cats-r4-c2-single-cluster`
- 对齐后的接口提交：`5a4baa50648ddf010931f4da77a4d5c705d320a3`
- 正式接口标记：annotated tag `CATS_R4_INTERFACE_COMMIT`，解引用到上述提交。
- 独立短路径 worktree：`D:/Vitis/FPT/cats_c2`。
- 计划 150 MHz build root：`D:/Vitis/FPT/b/c2_150_<source_sha>`；创建时必须是不存在的新目录。

原工作树 `D:/Vitis/FPT/FPT_WORKSPACE/03_work_v314_causal_bypass` 保持在原分支，已有未提交文档没有 stash、覆盖或带入本分支。

## C2 入口检查

阶段要求“只有 A/B 单元和计算 cluster wrapper READY 后开始”。下表同时区分当时的 GitHub 审计结论和当前工作树中的本地候选；本地未跟踪 RTL、单元仿真或 OOC 结果都不等同于 READY commit：

| Gate | Expected | Observed | Result |
|---|---|---|---|
| A unit READY | 基于 `CATS_R4_IF_V1` 的 32-lane QK/R=16 wrapper 与 READY commit | 已有 `cats_r4_qk_32lane_scheduler.sv` 本地调度器检查点；真实 FP32 MAC/accumulator、score/max commit、full-size aggregate 和 READY marker 仍缺失 | BLOCKED |
| B unit READY | 整行 Softmax、32-lane PV、FP32 accum 的 READY commit | 没有 B READY marker；整行 Softmax 与 32-lane PV 仍缺失 | BLOCKED |
| compute cluster wrapper | `rtl/core/cluster/` 下冻结 wrapper | 已有 `cats_r4_cluster_shell.sv`，但文件明确标注为 deterministic contract stub，不是计算 wrapper | BLOCKED |
| C memory-service candidates | bank/DMA/CDC/output 契约与定向证据 | 当前工作树已有本地 C 侧候选和单元检查点；Q/K/V bridge 仅为 `LOCAL CHECKPOINT / NOT READY`，尚未纳入生产 manifest | LOCAL ONLY |
| interface freeze | tag 位于 GitHub main 基线后且为本分支祖先 | `CATS_R4_INTERFACE_COMMIT -> 5a4baa5` | PASS |
| device/tool contract | Vivado/Vitis 2025.2，xczu15eg-ffvb1156-2-i | `project_config.json` 器件正确 | PASS |
| current production config | 必须明确区分 legacy 与 CATS | 仍为 v3.1.4、QK lanes=4、PV lanes=2 | LEGACY ONLY |
| source manifest | C2 实现后覆盖全部新增生产 RTL | 本地候选仍未纳入 `scripts/source_manifest.tcl` | NOT APPLICABLE YET |

因此当前仍没有授权把本地 banking/DMA/CDC/output 候选接入生产 top/manifest，也不能启动 C2 full-board Vivado/Vitis 构建。可以继续在本地完成 contract-only、单元仿真和 OOC 检查，但这些结果不能替代 A/B READY、真实计算 wrapper、routed Timing/DRC 或板级验证。现有 150 MHz routed 报告、BIT/XSA/ELF 和 303.120724 ms 板测只属于 v3.1.4 fallback，不能用作 C2 证据。

## 恢复条件

C2 仅在以下三项同时出现后恢复：

1. A 提交 32-lane QK、R=16、固定 2-cycle memory response contract 的 READY commit；不得改变 QK 数学/调度语义。
2. B 提交整行 Softmax、32-lane PV、16-bit external weight 和 FP32 accumulator contract 的 READY commit；不得改变已冻结数值/舍入语义。
3. 队长在本分支或其后继分支接收一个符合 `docs/CATS_R4_INTERFACE_COMMIT.md` 的 compute cluster wrapper，并记录 A/B commit SHA。

恢复后 C2 的第一步是 contract-only elaboration/TB，不直接做 full build。依次通过 bank collision、4 KiB burst boundary、随机 AXI latency/backpressure、CDC/reset、payload/tag 与写回保序后，才在全新 150 MHz build root 运行 Host/Python/XSim、OOC、full-board synthesis/implementation、Timing/DRC 和含 bit XSA。随后必须用该 XSA 新建 Vitis workspace/BSP/app，生成匹配 ELF，并记录工具、器件、绝对路径、时间和 SHA-256。

本记录不是 READY commit，不包含生产 RTL 修改，也不允许交 D 上板。
