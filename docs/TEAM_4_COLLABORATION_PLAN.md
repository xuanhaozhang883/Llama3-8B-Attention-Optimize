# FPT v3.1.4 后续四人并行协作计划

> 生效基线：2026-09-04，`codex/v314-causal-bypass`，HEAD `e37948d`  
> 适用工程：`FPT_WORKSPACE/03_work_v314_causal_bypass`  
> 排期口径：以本文件确认执行之日为 `T0`；周期按阶段估算，不按自然日逐日排班。Codex 可以压缩编码、测试生成和文档整理时间，但不能压缩 Vivado 实现、板卡排队和人工接线时间。

## 1. 当前进度与本轮目标

当前已完成：

- O1（v3.1.4 causal consumer bypass）RTL、Host/Icarus、Python full-GQA 数值模型和 Vivado XSim 均已通过；
- P2B Vivado Gate 已通过：整板综合、实现、路由、Timing、DRC、BIT 和含 bit XSA 已完成，150.015 MHz 下 WNS 为 `+0.654 ns`；
- P2C Vitis Gate 已通过：已由本次 XSA 新建 platform/BSP/A53 app，并生成匹配 ELF；
- BIT/XSA/ELF 身份链和板测日志签核器已就绪。

当前唯一未闭环项是 O1 实板 Gate：需要 XCZU15EG 板卡、JTAG、UART、供电和正确拨码，完成 1 次 warm-up 加 10 次正式运行。O1 未通过实板 Gate 前，O2/O3/多集群可以并行做模型、接口、单元级 RTL 和验证准备，但不得合入正式主线或宣称实板性能提升。

O1 板测必须核对的完整规模契约为：QK computed/skipped=`16,896/15,872`，Context processed/bypassed=`16,896/15,872`，V vectors=`1,081,344`，Context words=`524,288`。这些数值目前是协议推导和小规模 TB 支持下的板测期望值，尚不是完整规模实板实测值。

本轮总目标是按以下顺序形成可回退的稳定版本：

```text
O1 实板签核
  → O1 + O2（FIT-Context）
  → O1 + O2 + O3（QK continuous/interleaved）
  → 2-cluster
  → 4-cluster / CATS-4 候选提交
```

## 2. 四人职责与固定边界

成员姓名未确定时使用 A/B/C/D；确定后只替换称谓，不改变职责边界。

| 成员 | 主责 | 主改目录/文件 | 必须交付 | 不负责的内容 |
|---|---|---|---|---|
| A：架构与主线集成 | O1 板测收口、公共协议、顶层与主线合并、版本回退点 | `rtl/board/`、`rtl/core/a/`、公共 top、`scripts/source_manifest.tcl`、`project_config.json` | 接口契约、板测记录、集成提交、每阶段 release note、稳定 tag/commit | 不代替 B/C 改其模块内部算法；不代替 D 补系统证据 |
| B：Softmax / FIT-Context | O2 profiler、连续 V request、tagged Context 流水、局部存储优化 | `rtl/core/online/flash_online_softmax_frontend.sv`、`flash_context_fusion_backend.sv`、`flash_context_update_pe.sv`、对应 TB/模型 | 周期模型、RTL、模块 TB、随机回压、counter、OOC PPA、O2 交接包 | 不修改 QK 算法和多集群全局仲裁 |
| C：QK 连续流水 | O3 issue/result/commit、tile/tag 交织、scaler、exact/fast 数值模式 | `rtl/core/bc/qk/`、QK/RoPE 接口侧适配、对应 TB/模型 | 两种候选模型、选型记录、RTL、score 顺序/数量检查、OOC PPA、O3 交接包 | 不提前改变 Context 内部结构；不直接改 board top |
| D：多集群与系统验证 | 统一回归/PPA、banked memory、1/2/4-cluster wrapper、写回仲裁、证据汇总 | 新建 `rtl/core/cluster/`，`tests/`、`python/`、`vitis/`、报告脚本；公共 top 由 A 代合 | 回归矩阵、带宽模型、cluster RTL、PPA/功耗/板测汇总、产物哈希清单 | 不替 B/C 承担模块单测；不单方面改公共接口 |

固定规则：每个模块的实现者同时是该模块正确性第一责任人。D 负责系统级验证平台和结果汇总，不是全队的“补测试人员”；A 负责合并，不是全队的“冲突清理人员”。

## 3. 阶段期限与并行安排

预计总工期为 `T0 + 5～6 个有效工作周`。若板卡不能按时提供，只顺延需要板测的 Gate；B/C/D 的模型、单元 RTL 和验证框架仍按期推进。任何阶段若 Gate 不通过，后续研究分支可以继续，但正式主线停在最后一个稳定提交。

| 阶段与最晚目标 | A | B | C | D | 阶段出口 |
|---|---|---|---|---|---|
| S0：现场冻结与 O1 板测，`T0 + 0.5 周` | 核对 BIT/XSA/ELF 哈希，执行板测，保存原始 UART 日志并签核 | 冻结 O2 接口草案；加入 Context 状态、V 请求、RAW stall、tag FIFO 周期模型 | 加入 QK issue/wait/scaler 计数方案；完成 tile-interleave 与 D-vector 两个只读周期模型 | 固化回归矩阵、PPA 表和 1/2/4 cluster 带宽模型 | 10/10 正确且确定；`combined_failures=0`；完整计数闭合；O1 实测延迟有原始日志。无板卡时标记 BLOCKED，不伪造 PASS |
| S1：O2 并行原型，`T0 + 1.5 周` | 冻结 tag/坐标/last/clear 协议，准备 O2 集成壳层 | 实现连续 V request 和第一版 FIT-Context，先达到 V request `II=1`、feature II `≤8` | 继续 O3 模型与小原型，只改个人分支；给 B 提供 QK 输出压力模型 | 建立随机 V latency/backpressure、counter closure 和 Context OOC 自动报告 | O2 单元与 consumer 集成测试通过；无丢失、重复、乱序；有 cycles/LUT/FF/BRAM/DSP/WNS 对比 |
| S2：O2 主线集成，`T0 + 2.5 周` | 只合入 O2，解决公共层冲突，建立 O1+O2 回退点 | 修复集成问题，目标 Context consumer `3～5M cycles`、feature II 最终 `≤5` | 用新 profiler 判断 QK 是否成为主瓶颈，冻结 O3 选型 | 跑 Host/XSim/OOC/full-board；有板时跑 10-run | 数值门禁通过、WNS≥0、Context 不再是明显主瓶颈；实测目标 `70～120 ms` 仅在板测后成立 |
| S3：O3 实现与集成，`T0 + 3.5 周` | 冻结 O2 接口，只合入一个可归因的 O3 方案 | 保证 consumer 对新的 QK 发射节奏和回压兼容，协助定位跨模块问题 | 完成选定的 interleaved/continuous QK；exact 为默认，fast 单独报告 | 扩展 score-by-score、随机回压、全系统/PPA/板测矩阵 | QK/Context 吞吐差 `<20%`；score 坐标/数量一致；exact 过既有误差门禁；目标整机 `≤70 ms` 需实测确认 |
| S4：2-cluster，`T0 + 4.5 周` | 集成 cluster wrapper 与 board engine，控制公共接口变更 | 参数化 Context 本地状态和 V bank 接口 | 参数化 QK 本地状态和 Q/K bank 接口 | 主导 2-cluster、静态 group 分配、banked memory 和写回仲裁 | cluster 负载差 `<5%`；无长期全局仲裁阻塞；WNS≥0；板测目标 `≤40 ms` |
| S5：4-cluster 收敛，`T0 + 6 周` | 冻结候选架构、版本和回退方案，组织最终消融 | 解决 4-cluster Context 资源/时序热点 | 解决 4-cluster QK 资源/时序热点 | 主导 4-cluster、floorplan/跨时钟复位、PPA/功耗/10-run 汇总 | 计算域力争 200 MHz；10/10 正确且确定；负载差 `<5%`；目标 `15～35 ms`，未达标则提交稳定 2-cluster 或 O1+O2+O3 |

上述性能数字是阶段目标，不是预先承诺。未经板测时必须写“模型”或“仿真”；只有同源 BIT/XSA/ELF 的原始 10-run 日志才能写“实测”。

## 4. 每个成员当前立即开工项

### A：先闭环 O1，再守住主线

1. 以 `docs/BOARD_BRINGUP_TUTORIAL_V314.md` 为唯一板测步骤，核对三件套哈希后执行 warm-up + 10-run。
2. 使用 `python/signoff_v31_board_log.py` 对原始日志签核，记录日志 SHA-256、板卡信息和实测延迟。
3. 发布公共接口契约；B/C/D 若需改变公共端口，先提交接口提案，不直接改顶层。
4. 为每个 Gate 保存稳定 commit；集成失败时回到上一稳定点，不叠加第二项优化。

### B：并行完成 O2 可交付原型

1. 先测量 Context FSM 各状态周期、V request/response、issue/result/commit、RAW stall 和 tag FIFO 占用。
2. 将事务式 `REQ/RSP` 等待改为连续请求，tag 只在真实 `valid && ready` 时推进。
3. 实现 feature-chunk 调度、product store、partial accumulator 和 commit 队列；保持同一 `(row, feature)` 跨 key tile 的依赖顺序。
4. 交付 O2 模块测试、随机 backpressure、周期/PPA 消融和接口说明；不直接合主线。

### C：并行完成 O3 选型与原型

1. 对 tile interleave 和 D 维向量化分别给出 cycles/DSP/LUT/预期 WNS 模型，用数据选一个，不预设 QK8。
2. 拆分全局等待，建立多 tile/tag 的 issue-result-commit 流水，并处理 2～4 个 outstanding vector request。
3. exact 模式保持每个 score 沿 `d` 的既有左结合次序；fast 模式必须使用独立开关和独立误差报告。
4. 在 O2 主线数据出来前仅做分支原型；O2 证明 QK 成为瓶颈后才申请合入。

### D：并行搭建扩展与证据平台

1. 把全队测试整理为模块、consumer、full-system、OOC、full-board、board-log 六级矩阵。
2. 建立每 cluster 的 Q/K/V 读带宽、Context 写带宽、bank 冲突和仲裁等待模型。
3. 定义参数化 1/2/4-cluster wrapper、8 个 GQA group 的静态分配和两波调度，不提前修改公共 board top。
4. 自动汇总 utilization、WNS/TNS、route、功耗、counter、10-run 延迟和 BIT/XSA/ELF 哈希。

## 5. 共同接口与编码规范

### 5.1 协议规范

- 所有流接口仅在 `valid && ready` 同周期为 1 时完成一次传输；任何坐标、tag、计数和 `last` 只随真实传输推进。
- tag 至少能唯一恢复 `group/q_head/row_tile/col_tile/feature_chunk`；跨模块不得依赖“固定延迟后自然对齐”。
- `all_masked` 只允许旁路严格上三角 tile；对角线及以下出现异常 `all_masked` 必须置 sticky protocol error。
- `clear/reset/start/done/error` 的有效电平、同步域和保持周期由 A 统一冻结；模块内部不得另造同名不同义信号。
- 输出数量与顺序是硬契约：完整配置仍输出 `524,288` 个 Context words；优化不得以减少输出或改变软件布局换速度。
- 默认数值模式为 compatibility/exact。任何重排、混合精度或近似计算必须显式开关、独立 Golden、独立误差和独立报告。

### 5.2 文件与分支规范

- `02_baseline_v313_verified`、`archive/` 和来源归档只读；所有改动只发生在 `03_work_v314_causal_bypass`。
- 建议分支：`codex/a-integration-*`、`codex/b-fit-context-*`、`codex/c-qk-interleave-*`、`codex/d-cluster-*`。
- A 独占公共 top、board engine、生产 manifest 和版本配置的最终写入权；B/C/D 通过接口提案或补丁交给 A 合入。
- 同一阶段避免两人同时修改同一 RTL 文件。确需共享时，先在交接记录中写明 owner、预期端口 diff 和交还时间。
- 每个提交只包含一个可归因变化；提交信息建议使用 `A(board): ...`、`B(context): ...`、`C(qk): ...`、`D(cluster): ...`。
- 不提交临时 Vivado/Vitis 工程、绝对路径、缓存和无来源的大二进制；生产 RTL 新增后必须显式加入 `scripts/source_manifest.tcl`。

### 5.3 测试与证据规范

- 模块 owner 先跑定向 TB 和随机 backpressure；D 再跑系统矩阵；A 只合入已附证据的交付。
- 每项优化至少报告：基线 commit、优化 commit、工具版本、配置、cycles、counter expected/actual、数值误差、LUT/FF/BRAM/DSP/URAM、WNS/TNS、功耗和失败项。
- OOC 通过不等于整板通过；整板 timing 通过不等于板上正确；单次板测通过不等于 10-run 确定性通过。
- 板测必须使用同一次身份链的 BIT/XSA/ELF，保留原始 UART 日志并计算 SHA-256；不得只保留人工整理后的表格。
- 任何结果只允许使用 `PASS / IN PROGRESS / BLOCKED / NOT STARTED`；BLOCKED 必须写清外部依赖、恢复入口和当前可继续的并行工作。

## 6. 交接包与日常对接格式

成员申请评审或合并时，必须一次性交付以下内容：

```text
[Owner / 分支 / base commit / head commit]
目标 Gate：
改动范围：
接口变化：无 / 有（附端口与时序说明）
关键假设与周期模型：
修改文件：
已跑测试及结果：
counter expected / actual：
数值误差：
OOC / full-board PPA：
产物与日志 SHA-256：
已知问题或阻塞：
回退 commit：
请求谁做什么：
```

对接响应时限按阶段而非按天管理：接口提案必须在下一阶段开工前冻结；模块交付必须在对应阶段集成窗口前完成；集成发现的问题由原 owner 在该阶段内修复。不能在集成窗口临时增加新功能或顺手重构无关模块。

## 7. 合并 Gate 与最终决策权

| Gate | 允许合入的内容 | 必须同时满足 | 未通过时 |
|---|---|---|---|
| G0：O1 板级 | 仅 causal bypass 收尾和板测证据 | 同源三件套、10/10、数值/计数/错误标志全通过 | 主线停在当前 v3.1.4；继续 O2/O3 分支预研 |
| G1：O2 | 仅 FIT-Context | 单元+随机回压+full regression、Context 指标、WNS≥0；有板时补 10-run | 退回 B 修复，C/D 不叠加到该提交 |
| G2：O3 | 仅选中的 QK 方案 | exact 数值门禁、顺序/数量、吞吐差、PPA/时序、系统回归 | 保留 O1+O2，拒绝混入 fast 模式 |
| G3：2-cluster | banked memory、2-cluster wrapper/仲裁 | 负载差、带宽、时序、正确性、10-run | 保留稳定单 cluster |
| G4：4-cluster | CATS-4 候选 | 资源/时序/功耗、10-run、完整消融与回退提交 | 以稳定 2-cluster 或 O1+O2+O3 作为正式提交 |

A 对主线合并顺序负责；B/C/D 对各自模块的正确性和证据负责。是否进入下一 Gate 只看验收证据，不以“代码已经写完”作为完成标准。若结论有争议，以可复现日志、报告和最小消融结果为准。

## 8. 阶段完成定义

一个阶段只有同时满足以下条件才算完成：

1. 设计和接口说明已更新；
2. 模块定向测试、随机回压和适用的系统回归均通过；
3. counter、数值误差和 PPA 有基线对比；
4. 生成物可追溯到明确 Git commit 和工具版本；
5. 工作树中没有混入其他成员或下一阶段的改动；
6. 已给出稳定回退点、已知问题和下一阶段唯一主线动作。

本计划的核心是“研发并行、接口先冻、主线按 Gate 串行合入”。这样既利用四人和 Codex 的并行效率，又保留每一项性能提升的可归因性和失败时的稳定退路。
