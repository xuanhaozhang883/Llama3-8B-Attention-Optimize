# 四人最优化分工与合并计划

目标不是四个人同时改同一套顶层，而是建立四条可独立验证、按门禁合并的工作流。姓名未确定前使用 A/B/C/D；每人只提交自己拥有的目录，公共顶层由 A 在集成窗口统一修改。

## 角色和文件所有权

| 人员 | 主责 | 独占修改区 | 每周必须交付 |
|---|---|---|---|
| A：架构/集成 | 接口冻结、causal bypass、公共层级、合并与版本 | `rtl/board/`、`rtl/core/online/*top.sv`、`scripts/source_manifest.tcl` | 集成分支、接口表、综合/板测差分报告 |
| B：Context/FIT | FIT-Context、V cache 访问、累加流水与数值误差 | `rtl/core/bc/` 及新 `rtl/core/context/`、对应 TB/Python 模型 | 独立 TB、吞吐/误差/资源估算、可 cherry-pick 提交 |
| C：验证/软件 | Golden、随机回压、断言、计数器、Vitis/串口签核 | `tb/`、`tests/`、`python/`、`vitis/` | 一键回归、失败最小复现、BIT/XSA/ELF/日志哈希表 |
| D：QK/PPA | QK 细粒度交错、向量化、多 cluster 和时序/资源优化 | `rtl/core/a/` 中 QK/RoPE 数据面及新 `rtl/core/qk/` | OOC 报告、等价测试、II/频率/资源对比 |

公共接口变更流程：提案先写端口、位宽、valid/ready、重置、计数语义和异常行为；C 先补 contract TB；A 再改公共 top。B/D 不直接改 `attention_board_top.sv` 或 `fpt_attention_board_engine.sv`。

## Gate 路线

| Gate | 功能 | Owner | 进入条件 | 退出条件 |
|---|---|---|---|---|
| 0 | v3.1.3 签名基线 | A+C | 已完成 | 身份链、host 回归、历史板测证据冻结 |
| 1 | Profiling/计数契约 | C | Gate 0 | 每级 enqueue/dequeue/skip/V/context 可签核 |
| 2 | v3.1.4 causal consumer bypass | A+C | Gate 1 | host+XSim+OOC+整板时序+匹配板测均通过 |
| 3 | FIT-Context | B+C | Gate 2；独立分支可提前研究 | 误差阈值、随机回压、PPA 和板测优于 Gate 2 |
| 4 | QK 交错/向量化 | D+C | Gate 2 | lanes 等价、顺序不变、吞吐/PPA 实测改善 |
| 5 | 2-cluster | A+D | Gate 3/4 中至少一项通过 | DDR 带宽、资源、时序和端到端延迟均闭环 |
| 6 | CATS-4 / 4-cluster | A+B+D | Gate 5 | 只有收益大于路由/带宽代价才保留 |
| 7 | 混合精度/250 MHz | 全员 | 稳定功能版本 | 精度、Timing、功耗和板级稳定性共同通过 |

## 当前可并行的两个冲刺

### 冲刺 1：把 Gate 2 做成可上板版本

- A：冻结 causal bypass RTL，拿到许可证后做 OOC/整板 synthesis、implementation 和 IP 属性审计。
- C：增加 v3.1.4 日志 profile、计数负例、10-run 汇总和产物哈希检查。
- B：只在独立分支建立 FIT-Context Python/RTL 接口原型，不接公共顶层。
- D：只做 QK OOC 基线与交错调度实验，不改变输出顺序。

### 冲刺 2：Gate 3/4 二选一合入

先比较 FIT-Context 与 QK 交错在相同约束下的“端到端 cycles 减少 / 新增 LUT+DSP / WNS 损失”。优先合入收益可归因、正确性证据完整的一项；另一项基于新主线重放，禁止把两项同时合并后再猜收益来源。

## 合并门禁

每个候选提交必须同时提供：

1. 设计说明和明确的非目标；
2. 定向 TB、随机 backpressure、全回归和数值误差报告；
3. OOC 与整板 LUT/FF/BRAM/DSP、WNS、频率和 cycles 对比；
4. 匹配 BIT/XSA/ELF SHA-256 与原始 UART 日志；
5. 可单提交回退，且不修改只读基线。

任何一项只有模型/仿真证据时必须标注“预测”或“仿真”，不能写成实板收益。

## 默认优化目标

在竞赛评分口径未补充前采用分层目标：首先 `combined_failures=0` 且协议/计数无错；其次最小化端到端 PL cycles；再以 WNS≥0、器件资源不超限为硬约束，比较 DSP/BRAM/LUT 和功耗。频率提升只有在端到端时间确实下降时才算收益。
