# 活动工程状态

`03_work_v314_causal_bypass` 是后续唯一允许修改和提交的工程目录；`02_baseline_v313_verified` 是只读签核基线，其他三个来源目录只作追溯资料，不能直接混入生产清单。

## 已恢复的非板卡闭环（2026-09-02）

- 活动分支：`codex/v314-causal-bypass`；起点为带标签 `workspace-v313-gate0` 的 v3.1.3 文件级签名基线。
- Host/Icarus 完整回归通过：QK lanes 1/2/4/8、causal skip、随机 backpressure、consumer/full integration、board-log 单测和 524,288 元素 full-GQA 数值模型均 PASS。
- Vivado 2025.2 XSim 回归通过，包括新增的 v3.1.4 causal consumer bypass 定向测试。
- 更新后的 A53 裸机源代码使用 Vitis 2025.2 工具链成功编译；由于当前只能借用 v3.1.3 XSA 验证软件编译，它还不是可上板的 v3.1.4 配套 ELF。
- 数值模型 `combined_failures=0`，但有 223,988 个元素与 golden 逐比特不同；当前正确口径是误差阈值通过，不能宣称 bit-exact。

## v3.1.4 已实现

consumer 在确认 `all_masked && col_tile > row_tile` 时只推进 FIFO/坐标/计数，不启动 Online Softmax、V 读取或 Context 数据面；对角 tile 仍逐元素 mask，最终输出总量保持 524,288 words。

完整 32Q、S=128、TILE=4 的计数契约：

| 计数 | v3.1.3 | v3.1.4 期望 |
|---|---:|---:|
| FIFO tile enqueue/dequeue | 32,768 | 32,768 |
| Softmax/Context tile | 32,768 | 16,896 |
| causal consumer bypass | 0 | 15,872 |
| V vectors | 2,097,152 | 1,081,344 |
| Context output words | 524,288 | 524,288 |

这些是由协议和循环边界推导、且已由小规模定向仿真验证的期望值；没有匹配的 v3.1.4 BIT/XSA/ELF 和板级日志前，不宣称实际延迟或 PPA 收益。

## 当前硬阻塞

本机 Vivado 能创建 XCZU15EG Floating-Point IP 并运行 XSim，但在 OOC synthesis 入口报告缺少 `Synthesis`/`xczu15eg` 有效许可证。因此 Elaboration 后的综合、实现、Timing/DRC、BIT/XSA 以及匹配硬件的软件/上板闭环尚不能完成。许可证恢复后按 `docs/NON_BOARD_RECOVERY_2026-09-02.md` 继续。

## 下一项架构工作

在 v3.1.4 通过综合和板级 Gate 2 前，不把第二项高风险数据面改动并入主线。并行研究可在独立分支开展：优先 FIT-Context 流水化，其次 QK 细粒度交错/向量化，再评估 2-cluster 和 4-cluster；四人边界见 `docs/TEAM_4_OPTIMIZATION_PLAN.md`。
