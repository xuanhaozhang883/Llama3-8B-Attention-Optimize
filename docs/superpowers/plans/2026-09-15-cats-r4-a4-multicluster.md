# CATS-R4 A4 完整实施计划：2 / 4 cluster 计算侧扩展

日期：2026-09-15

负责人：成员 A

状态：执行中；P0/P1 已启动，当前受 canonical output 可行性门禁约束

目标：先完成 A4-2 计算侧验收，再完成 A4-4 计算侧验收与 B/C/D 交接。

本文件中的新增源码、TB、脚本和报告是计划产物，尚不存在；命令示例只有对应任务实现后才能运行。勾选框代表实际完成记录，不因写完计划而勾选。现有 A3 READY 不等于 A4 READY。

## 1. 依据、范围和文档优先级

执行依据：

1. `docs/STEP_BY_STEP_PROMPTS_CN.md`：成员 A 的 A4，成员 B 的 B4，成员 C 的 C3/C4，成员 D 的 D3/D4。
2. `docs/CATS_R4_INTERFACE_V3.md`，及其继承的 V2 Q/KV selector、Q-slab need/ready/retire 契约。
3. `docs/CATS_R4_C1_SYSTEM_CONTRACT.md`：group 静态分配、存储服务、canonical output 和系统边界；V3 覆盖其中旧 weight 宽度与容量。
4. `docs/superpowers/specs/2026-09-13-cats-r4-a3-compute-cluster-design.md`。
5. `docs/CATS_R4_A3_COMPUTE_CLUSTER_DELIVERY_2026-09-13.md`、`docs/CATS_R4_A3_PORT_MAP_2026-09-13.md`、`reports/cats_r4_a3_evidence.json`。
6. `docs/CATS_R4_B4_DELIVERY_2026-09-13.md`、`docs/CATS_R4_C_INTERFACE_MATRIX_2026-09-08.md` 和实际 RTL。

旧 `TEAM_4_OPTIMIZATION_PLAN.md` / `TEAM_4_COLLABORATION_PLAN.md` 使用过不同的 A/B/C/D 分工；本计划使用 CATS-R4 执行提示词和后续接口冻结中的分工。旧提示词里的 QK“4 heads × 8 lanes”已被 V2/V3 的“32 key lanes、4 Q heads 顺序复用”覆盖。不得混用。

提示词引用的 `00_handoff_docs/FPT_XCZU15EG_冲冠最终方案_2026-09-05.md` 未在本次检查的工作树发现。现有已冻结文件足以编写本计划；P0 要让队长给出其可访问位置或明确当前替代基线，不能声称已经逐条审核了这份未找到的文档。

### 本次交付范围

- A：计算侧 group/job 调度、多个 A3 实例组合、局部三槽隔离、完成判定、错误与计数汇聚、计算侧测试和 OOC。
- B：Softmax/PV 数值内部、已有 B4 修复接收、1/2/4 cluster 的数值复核。
- C：Q/K/V 与 weight 存储实体、KV 双缓冲、DMA、CDC、canonical output 仲裁、全局 drain/reset、production manifest、board top、BIT/XSA/ELF。
- D：独立 golden/容差、性能口径审查、板测和系统性能签核。

A4 基线频率为 6.666 ns（约 150.015 MHz）。200 MHz、混合精度、更换器件、修改 lane 数和增加 HP 口均不是本 A4 计划默认任务。

## 2. 已核对事实与入口

2026-09-15 只读检查 GitHub：

| 分支 | SHA | 含义 |
|---|---|---|
| `codex/a-cats-r4-a3-compute-cluster` | `9be65351193608b2b1c1597ede166b1534437496` | 已推送 A3 交付 |
| `codex/cats-r4-local-integration` | `f9419e8d30d13f5aeba6cfeb6dd1403028f79d43` | 检查时仍是旧集成基线 |
| `main` | `eb530f835f9a80920522a02e08f1f8ad4728d023` | 不是本计划直接开发目标 |

A3 被测源码/工具身份：`1372b0bb8f1264311d4e9bffd1b656bceea05c68`；之后交付提交只更新文档。A3 报告的 OOC：LUT=61967、FF=115025、DSP=387、BRAM/URAM=0、WNS=+0.640 ns、TNS=0。这个资源范围不包含 C 的完整存储/板级基础设施。

### 入口不是“一定先等完整 C2 板测”

- 现在可独立完成：A3 证据核查、资源/带宽模型、工作分配模型、A4 设计与接口请求、测试矩阵和验收工具设计。
- 默认正式开发基线：队长接收 A3 后的 `codex/cats-r4-local-integration`，记录准确 SHA。
- 若集成尚未合并，可从上述已推送 A3 SHA 开独立 A4 checkpoint 分支，开展不依赖新公共接口的 A-owned 原型/单测；记录祖先与后续移植任务。合并到集成分支不是 RTL 能运行的技术必要条件。
- B4 owner 接收、C 多 cluster 接口及性能环境未冻结时，相关正式集成/READY 门禁保持 BLOCKED。C2 整板完成不是所有 A4 单测的前置条件。
- C3/C4、D 的系统门禁由相应成员完成。若 C/D 已证明共享系统瓶颈并标记 STOP，A 不以理想内存模型 PASS 为由绕过它复制 4 cluster。

拟用独立分支：`codex/a-cats-r4-a4-2cluster`、`codex/a-cats-r4-a4-4cluster`。只在进入对应阶段时创建；4 cluster 分支必须继承已验收 2 cluster SHA。A3 分支保留为回退和审查基线。

## 3. 推荐设计与备选方案

采用“参数化多个真实 A3 + 每 cluster 独立控制/存储端口 + C 侧静态 group 命令”的设计。新增 A-owned adapter，不将 C 的 DMA scheduler 改造成 A 的文件，不复用 `cats_r4_cluster_shell.sv` 的占位行为。

备选方案比较：

| 方案 | 优点 | 代价/结论 |
|---|---|---|
| 多个 A3、局部 adapter、独立 C 服务端口 | 复用已验收算术，隔离明确，便于归因 | 推荐；需要核对真实输出/存储瓶颈 |
| 所有 cluster 共用细粒度中央 mux/控制器 | 表面代码少 | 易产生全局反压、长组合路径；不作默认实现 |
| 先重写算术/混合精度，再复制 | 可能省资源 | 数值和验证范围大；仅在资源诊断后由 owner 提独立方案 |

### 3.1 静态分配与波次

`cluster_id = group % N`，`local_group_index = group / N`，`global_q_head = 4*group + local_head`，其中 N=1/2/4、group=0..7、local_head=0..3。每个 group 包含 4 heads × 8 row windows，window=0..7、每 window=16 rows。

| N | cluster 0 | cluster 1 | cluster 2 | cluster 3 |
|---|---|---|---|---|
| 1 | 0,1,2,3,4,5,6,7 | — | — | — |
| 2 | 0,2,4,6 | 1,3,5,7 | — | — |
| 4 | 0,4 | 1,5 | 2,6 | 3,7 |

4 cluster 的两波是各 cluster 的两个本地 group。局部 ready/retire 条件满足后可启动自己的下一 group，不默认增加“等所有 cluster 完成第一波”的全局屏障。若 C 的存储契约需要屏障，必须显式记录原因和性能影响。

现有 B4 TB 按 `head = CLUSTER_ID + local_head_index*CLUSTERS` 分配 head，它只能作为 B4 局部算法回归，不能证明上述 A4 group 分配。新增 A4 测试驱动和 scoreboard，不把旧 TB 的 PASS 改名作为 A4 证据。

### 3.2 每 cluster 状态与端口

- 每 cluster 复用一个真实 `cats_r4_a3_compute_cluster`，保持 32 QK key lanes、32 PV feature lanes、原 FP32 顺序累加和 BF16 RNE。
- 每 cluster 独立三份 score16 槽和三份 weight32 槽；weight 存储仍由 C 提供。R=16 contexts 与三槽是不同层级，不混称。
- `slot_id=0..2` 是本地编号；跨 cluster 唯一身份是 `{cluster_id,完整 V3 token}`。本地 slot 位宽保持 2 bit。
- A4 外层以 packed array 或展平向量承载 N 套原有端口，最终形式在 P2 冻结；不能省掉某套 ready、buffer selector 或 token。
- C 的 per-cluster group command 只在对应 KV 已 active 且旧 group 已安全释放后提交；A adapter 接受后展开 32 个 head/window jobs。
- K/V buffer 由 C 分配/激活，A 使用冻结 selector；不能把单 cluster 的 `buffer=group[0]` 直接推广到 2/4 cluster，因为同一 cluster 的 group 常为同奇偶。若交替，按本地 group 序号及 C 所有权驱动。
- Q-slab selector 与 KV selector 分离，保留 need/ready/retire 的完整身份与时序。
- N+2 非反压 response 保持原契约：随机压力改变请求 ready、服务可用时刻和输出 ready；改变固定返回 latency 的用例归为负向协议测试。
- 每 cluster 的事务 mode 锁存一次，busy 时非法修改必须拒绝/报告，不能部分 cluster 切换成功。

### 3.3 完成、输出与时间戳

- `out_tensor_last` 是全局数据坐标标记，不是每个 cluster 的 done，也不能单独证明整个事务完成。
- 正常 group completion 必须同时满足：32 个 jobs 已接受且 Q-slab 已 retire、512 行/65536 Context words 已交给 C、512 个 final releases 已完成、三个 score/weight 槽释放、所有相关 pending request/response/error 清空。
- 需要的 status 通过 A-owned adapter/只读状态端口显式提供；不得用生产 RTL 层次引用或固定延时猜测 idle。新增公共状态须纳入 P2 接口请求。
- `group_done valid/ready` 及其 epoch/group/error 在阻塞时稳定；每 group 最多一次，重复/错 group completion 必须检测。
- 全局 compute done 等所有分配的 group 完成且各 completion 被接收；DDR 写响应完成与系统 done 仍归 C。
- 每 cluster 记录每次输出握手的最近时间，不能直接复用 A3 只在全局 tensor_last 时更新的 `last_commit_cycle` 作为所有 cluster 的结束时间。
- 主性能边界：同一 core clock 下全局首个实际 QK issue，到所有 Context chunk 被约定 C 消费边界接受的最后一拍；`cycles=end-start+1`。另报 release/drain 完成延迟、C 的 DDR transaction cycles。
- C 保持 canonical `(global_q_head,row,feature)` 输出；A 不自行改变 DDR 可见顺序。

### 3.4 错误、reset 与 epoch

- 常规局部背压只影响相关 cluster；其他 cluster 在服务可用时可继续。
- 每 cluster 独立错误缓冲；共享错误出口采用锁定输出的公平仲裁，携带 cluster id 和原错误 source/code/token，同拍多源不丢失、不覆盖。
- 错误后的全局 halt/隔离由 C 契约驱动；错误 cluster 停止新工作，其他 cluster 只能完成契约允许的在途排空。不可将错误事务发布正常 done。
- 全局恢复顺序为隔离新请求 → C 排空/取消 outstanding → 协调 clear → 新 epoch → 重启。
- Q/K/V response 未携带完整 epoch，不能仅靠比较 token 丢旧数据；必须证明旧 response 已排空或被适配层隔离后才重用 context/slot。
- 单 cluster reset 负向测试必须触发约定的事务 abort 或局部恢复协议，不默认允许它在旧事务里静默重入。
- `counter_clear` 只在全系统约定 quiescent 状态执行；snapshot 在同一统计窗口采样，禁止读取跨域活动计数进行比较。

## 4. 精确工作量与性能门槛

### 4.1 全负载计数

固定 S=D=128、32 Q heads、8 KV groups。下表为每个 cluster 的均匀分配期望，aggregate 总值始终取 N=1 列。

| 指标 | N=1 每 cluster / aggregate | N=2 每 cluster | N=4 每 cluster |
|---|---:|---:|---:|
| groups | 8 | 4 | 2 |
| Q heads | 32 | 16 | 8 |
| rows / final releases | 4096 | 2048 | 1024 |
| causal scores / 有效 exp | 264192 | 132096 | 66048 |
| weight writes（含 mask） | 524288 | 262144 | 131072 |
| QK valid MAC | 33816576 | 16908288 | 8454144 |
| PV valid MAC | 33816576 | 16908288 | 8454144 |
| Context words | 524288 | 262144 | 131072 |
| Q slabs | 256 | 128 | 64 |
| engine jobs | 6144 | 3072 | 1536 |

score 只发送 key=0..row、score last 在 key=row；weight 写 0..127、weight last 在127。正常协议错误为0；负向用例逐项声明预期错误源和增量。读 request/response/consume 按真实实现闭合，不能把 feature 广播当额外有效 exp。

C 系统级总量另验：DDR read=196608 beats、write=131072 beats、rows_committed=4096；不能由 A4 计算单元测试假装完成 DDR 验收。

### 4.2 加速、负载和公平性

- 1/2/4 对照使用相同 full input hashes、mode、每 cluster lane 数、时钟、功能、服务 latency、输出顺序、每 cluster 有限 queue 容量和总共享端口带宽。总 lane 数随 N 增加是本次变量，必须同时报告。
- `speedup2=cycles1/cycles2`；计划采用 `>=1.6` 的明确自动推进线。低于1.6为 STOP，不凭“约”字自行解释为通过；记录诊断，再由团队处理。
- 负载差定义：`imbalance=(max(active_cycles)-min(active_cycles))/mean(active_cycles)`，每 cluster 从同一事务起点到其最后本地 commit，含实际分配/存储/输出等待，最终要求 `<0.05`；同时报告纯计算 busy cycles 和 group 启动偏差，避免隐藏等待。
- 该负载门槛用于正常同条件基准；人为把一个 cluster 延迟放大的 fault/stress 用例主要验证安全性和可恢复性，不要求故意不平衡负载仍<5%。2 cluster 也测并按 C3 同口径要求<5%。
- 仲裁 liveness 在“下游最终 ready”的前提下证明。对连续可服务请求，用成功 grant 机会计数给出轮转上界；无限外部反压不算内部死锁，但必须能识别具体阻塞源。
- 4 cluster 必须报告 speedup4 和相对2 cluster的增益；原 A4 没有明确规定4×或3.2×下限，不自行添加承诺。退化或长期阻塞仍须诊断，不能仅数值 PASS 就宣布全部完成。

## 5. 两个必须提前做的可行性检查

### 5.1 资源

按 A3 OOC 简单乘法，仅作风险估算：

| 计算实例 | LUT | FF | DSP |
|---|---:|---:|---:|
| 1 | 61967 | 115025 | 387 |
| 2 | 123934 | 230050 | 774 |
| 4 | 247868 | 460100 | 1548 |

4 cluster 计算部分粗估已超过 C1 提到的 full-board 约230k LUT / 380k FF 规划，尚未加入 C 侧开销。这不是器件已放不下的证明，但足以要求早期预算审查。V3 容量模型必须计入 score16、weight32、mask/token、sum/inv_sum，不能只复制 C1 V1 152960 bytes。

P1 取得器件容量、C 当前实际资源/预留和团队预算决策。物理容量为硬门；旧规划预算若需要调整，记录 C/队长的明确决定和理由，A 不静默放宽。需要 B/C 内部节省资源时由对应 owner 独立提交。不可通过删除 counters、减少 lane、隐藏实例来“通过”资源验收。

### 5.2 canonical output 与有限缓存

C1 的每 cluster 输出队列仅32行，一个 group 却有512行。后序 group 在等待 canonical 输出时可能很快填满队列，进而停住 PV/Softmax/QK。无限 sink 或每 cluster 无带宽上限的独立 sink 会高估加速。

P1 先用可复算模型比较：无限 sink（诊断上限）、现有有限队列/严格顺序（基准）、C 提供的可实现改善方案。若基准预测明显无法达到1.6，则先提交输出缓存/调度集成请求；性能不足的设计仍可做必要的最小验证，但不直接进入完整2 cluster长布线，更不复制4 cluster。改变 output queue、DDR commit策略或 memory service 归 C，必须更新其资源模型及契约。

## 6. 完整任务分解

### P0 — A3 交接、证据和实际基线审计

依赖：无；A 可立即做。

- [x] 保存 branch/HEAD/status、A3 PR 状态、接口 tag object 与 peeled commit；当前 tag commit 为 `4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`。
- [x] 整理 A3 已有 DCP、XSim 日志、route/timing/DRC/资源报告及 hash，迁入本地持久证据目录并建立tracked index；跨机器发布仍列独立动作。
- [x] A3 full protocol runner 已保留输出并显式记录vvp退出码；无法恢复的旧日志未冒充当前证据，mode0/1已从`247b46d30542345db41e8a7ea644550389d0d12d`各补跑一次完整4096行并保存hash。
- [x] 修正证据分类：`run_cats_r4_qk_a2_row_pipeline_xsim.ps1` 使用 `tb_qk_fp32_mocks.sv`，属于 XSim 上的模拟算术回归；真实 vendor-IP 证据来自 A3 real-IP runner。修正交付文字中的混淆。
- [x] A3 已保存摘要主要是 max/setup；从同一 DCP 补生成 min/max 报告并验证 `WHS=+0.010ns, THS=0`，未重新综合布线。
- [x] 清理 A3 ablation 文档仍称“OOC timing failed”的失效文字，保留 online 对照缺失的事实；不扩展实现 online 引擎。
- [ ] 取得 B/队长对 `b53902734501738df2a9a467e7907ffe99a11eda` 的接收 SHA/例外记录；取得 C 对 sin_bf16 expected/actual hash 的正式决定。未知就列未满足依赖。
- [ ] 队长给出 A4 使用的集成 SHA、权威总方案路径与多 cluster 接口对接人；复核差异后建立独立工作树，不覆盖现有 main/A3 工作树。

产物：`docs/CATS_R4_A4_BASELINE.md`、持久 A3/A4 baseline evidence index。验收：每份证据可追溯源码与输入；owner 接收不靠推测。未收到外部答复仍可进入 P1、P2 草案。

### P1 — 资源、带宽、调度和队列可行性模型

依赖：P0 的本地事实；A 主做、C/D 提供/审阅约束。

新增：`python/cats_r4_a4_scaling_model.py`、`tests/test_cats_r4_a4_scaling_model.py`、`docs/CATS_R4_A4_FEASIBILITY.md`。

- [x] 枚举全部 N=1/2/4 group/head/window/row，验证无漏项、重复、错误 owner；生成本计划第4节的 expected counters。
- [x] 基于 V3 重新算每 cluster 容量、并发 Q/K/V/weight 端口需求和共享带宽；列清读写/广播单位。
- [x] 建立有限输出缓存、canonical reorder、group切换的事件/周期模型；保存完整配置和模型局限；KV预取仍待C契约参数。
- [x] 验证不同cluster等待与队列容量下的因果关系，不仅给线性倍增预测。
- [x] 输出2/4 cluster资源风险；C资源预留作为明确外部请求，预算处理路径已记录。
- [x] 1.6×目标被共享瓶颈限制，已产出最小场景、stall预测、C接口请求和备选方案；按 owner 处理后重新检查。

验收：所有 aggregate invariant 成立，预算/输出路径具有可实现方案。预测不标记 RTL 或系统实测 PASS。

### P2 — 冻结 A4 外层契约、完成语义和性能环境

依赖：P1；A 起草、C 接收，涉及 B 数值/释放时由 B 接收。

新增：`docs/CATS_R4_A4_INTERFACE.md`、`docs/CATS_R4_A4_INTEGRATION_REQUESTS.md`。

- [x] 对照真实 A3 与 C 端口列出逐字段映射：方向/宽度/clock/reset/default、ready/valid、selector、cluster routing、stall稳定性。
- [x] 冻结A侧单元开发所用的 C→A per-cluster group command、A→C group completion、错误、halt/drain/idle、mode 与 epoch 语义；C生产接收仍OPEN。
- [x] 冻结A侧 status/计数更新规则、乱序完成、全局 done 与 tensor_last 的区别。
- [ ] 冻结每cluster score/weight的独立物理存储、Q/K/V隔离、N+2返回、队列容量、总共享带宽及性能结束边界。
- [x] 每个公共接口变更单独记录 owner/提案/接收SHA/回归要求；已有 V3 tag 不移动，需要新版本由队长发布。

验收：编码所需字段和责任全部确定；未解决的问题列明确阻塞任务，不靠占位信号静默接零。

### P3 — 建立可复用 runner 与证据保存

依赖：P0/P2；A。

新增：`tests/run_cats_r4_a4_suite.ps1`、`tests/check_cats_r4_a4_readiness.py`、`tests/test_check_cats_r4_a4_readiness.py`；必要时抽取 A-owned runner 公用逻辑。

- [x] runner支持 `Clusters=1/2/4`、`Mode=0/1`、seed、suite、独立输出根目录、超时并拒绝非法配置；未实现阶段显式fail closed。
- [x] 每次先保存 Git source/tree/file hashes、工具版本、精确命令和配置；后续套件接入时补输入/IP/XDC专用字段。
- [x] 原始 stdout/stderr、退出码、计数摘要、报告和失败seed在结束/失败/超时后都保留；只清生成工程，不清证据。
- [x] 每次启动登记PID、开始时间、阶段、日志位置和checkpoint；恢复时先确认原进程/日志，禁止同候选无理由重复启动。
- [x] 验收器检查证据等级、配置覆盖、hash/文件可读性、正常错误、逐cluster/aggregate、setup/hold/route/DRC、性能和未关闭依赖，不能仅检查JSON写着PASS。
- [x] 针对缺失配置、陈旧/缺失证据、负WNS/WHS、错误计数、double-count、假时钟、不可比性能、依赖未接收设置失败测试。

验收：伪造/缺失证据不能变 READY；真实失败不会因wrapper输出PASS字符串而通过。

### P4 — group/job adapter 与工作分配单测

依赖：P2/P3；A。

新增：`rtl/core/bc/integration/cats_r4_a4_group_job_adapter.sv`、`tb/tb_cats_r4_a4_group_job_adapter.sv`、`tests/run_cats_r4_a4_group_job_iverilog.ps1`。

- [x] 接收匹配group command，锁存epoch/mode/selector，按head递增、window递增产生32 jobs；C生产接收仍OPEN。
- [x] job/retire观察链路独立反压与payload稳定性；Q-slab need/ready仍由既有A3处理，不以固定延时跳过握手。
- [x] 实现逐group计数差分、三槽/在途完成条件、group_done锁存与释放，区分正常完成、error和abort。
- [x] 验证N=1/2/4全部cluster-ID的静态group映射、首末head/window、不合法command及重复提交；跨cluster同token隔离留给P6组合TB。
- [x] 覆盖最后Context早于最后release、retire阻塞、错误阻塞、done阻塞、clear/abort及busy counter_clear；任何未排空状态不得假done。

验收：每group恰好32 slabs、768 engine jobs、512 rows/releases，全部有效事务守恒。

### P5 — N=1 外层组合与新的公平对照基线

依赖：P4；A。

新增：`rtl/core/bc/integration/cats_r4_a4_compute_array.sv`、`tb/tb_cats_r4_a4_compute_array.sv`、`tb/tb_cats_r4_a4_service_model.sv`。

- [x] 首先只启用N=1，将真实A3和group adapter接起来；保持原A3行为。
- [x] 使用C冻结服务模型，并增加一层调用现有真实C weight memory的集成测试；模型不能替代实际C服务验收。
- [x] 建立独立scoreboard，按完整token验证score、Context和release；为后续乱序cluster输出使用集合+局部顺序检查。
- [x] 比较新wrapper与A3相同事务的内容/工作量并测量adapter周期；物理资源差分留给同工具OOC，不从源码行数推断。
- [x] N=1正式基准覆盖两种mode、相同full workload和冻结服务模型，并保存全部证据；另以真实C weight memory完成512-row边界集成。

验收：N=1功能等价且开销可解释；它是2/4性能对照的C1 cycles，不是PowerShell运行秒数。

### P6 — 2 cluster 实体接线、事务控制与计数汇聚

依赖：P5；A。

新增：`rtl/core/bc/integration/cats_r4_a4_event_join.sv`、`rtl/core/bc/integration/cats_r4_a4_telemetry.sv` 及对应TB；扩展compute_array到N=2。

- [x] 实例化两套独立A3/adapter，独立暴露Q/K/V/weight/Context端口，不建立细粒度全局数据mux。
  - [x] 前置条件：单个真实compute-array已参数化为N=2的cluster 0/1，并分别完成group 0/head 0--3与group 1/head 4--7的512-row协议切片；尚未把两实例组合成生产N=2顶层。
- [x] 实现事务捕获/异步start fanout单元，验证每cluster恰好一次启动、epoch/mode锁存、busy/非法mode/epoch复用错误及全局排空解锁。
- [x] 组合两套真实group adapter完成P6控制面TB：并行group 0/1、不同job背压、异步completion、done阻塞稳定和错误路由隔离均通过。
- [x] 将start fanout接入两套真实A3，验证静态group映射；所有cluster接受同事务前不得造成mode/epoch混杂。
- [x] 实现可复用的buffered completion/error汇聚单元、锁定轮转仲裁、独立source counter并完成独立TB。
- [x] 将completion/error汇聚接入N=2实体，并验证wrong-owner control root与事务协议错误均触发全局halt及新命令封锁。
- [ ] 在P7压力TB中证明错误后的accepted outstanding、sidecar、spool与事件缓冲全部排空，满足P2 drain门禁。
- [x] 实现先捕获一致快照、下一拍再归约的telemetry单元，避免直接读取活动计数。
- [x] 在N=2实体中接入真实cluster活动/阻塞计数与telemetry一致快照。
- [ ] 用Vivado确认高扇出控制与telemetry归约不会成为长路径；必要时在cluster边界增加本地寄存。
- [x] telemetry单元提供first_issue、last_local_commit、all_done和逐cluster完成/占用/等待快照，并完成独立TB。
- [ ] 将上述统计接到两套真实A3/adapter，确保实际时间戳不依赖只在head31触发的tensor_last。

验收：两cluster可同时工作，一个cluster常规stalled时另一个有服务仍可推进；总量与逐cluster求和一致。

### P7 — 2 cluster 完整协议、压力与恢复

依赖：P6；A。

新增：`tb/tb_cats_r4_a4_full_protocol.sv`、`tb/tb_cats_r4_a4_stress.sv` 和对应 Icarus runner。

- [ ] 两种mode各跑一次完整4096行；逐cluster和aggregate核对第4节全部counter。
- [ ] 正常seed采用7/19/73/101；各cluster使用可复算的不同随机子序列，避免同时相同stall掩盖错误。
- [ ] 依次测试无反压、请求侧反压、输出满队列、完成乱序、长循环跨epoch、所有三槽满、两波/多波边界。
- [ ] 测同拍多cluster错误、错误出口堵塞、非法mode、token/group/cluster不符、重复/缺失key/last/response和非有限score；逐例预声明错误增量。
- [ ] reset/clear覆盖QK在途、row-max流水中、weight写/读、PV在途、Context阻塞、completion阻塞和group切换；确保新epoch首个请求正确。
- [ ] 设计“带错误tag的迟到response”和“不带epoch的Q/K/V迟到response”各自的隔离测试。
- [ ] 测episode超时须保存最后进度/owner/FIFO/outstanding诊断，不靠增大timeout掩盖无进展。

验收：常规路径零错误、无丢失重复、负向只出现预期事件、所有恢复用例可完成下一事务；证据标为protocol_model。

### P8 — 2 cluster 数值一致性与真实IP/XSim

依赖：P7；A执行、B提供模式语义/核查、D阈值保持不变。

新增：`python/cats_r4_a4_numeric_compare.py`、`tests/run_cats_r4_a4_numeric.ps1`、`tests/run_cats_r4_a4_realip_vivado.ps1`。

- [ ] 使用同一批已保存的Q/K/RoPE/V输入和reference，输出以global head/row/feature归位；验证实际group分发而非只重复调用同一数学函数。
- [ ] full numeric覆盖4096行/524288元素、两种正式支持mode；按既定combined gate要求0 failures，报告abs/BF16-distance/误差分布，保持Compatibility已声明输入域及限制。
- [ ] 区分“相同算术的1/2输出逐字相同”与“对golden满足容差”；仅前者适合声称规模扩展不改变raw bits。
- [ ] 真实IP代表性矩阵：N=1/2 × mode0/1 × seed7/19/73/101；每配置所有cluster同时参与，先每cluster一个合法16-row window。矩阵合计覆盖每cluster两个不同group、首末head、window=0/1/2/7及row=0/1/15/16/31/32/126/127、连续行三槽占满。每例记录实际rows/jobs，不宣称每例都是full workload。
- [ ] 代表性短窗口在真实array的job边界回放，不给生产group adapter增加为测试跳过工作量的逻辑；全group/two-wave调度由P7全量协议测试覆盖。另补真实group adapter连接真实A3的完整group集成用例，先测单例成本，再选择最少覆盖所有控制状态的模式/规模组合；这类长用例和短窗口证据分别记录。
- [ ] 使用非零、正负混合且不同group可区分的输入；零score/V=1只能作smoke，不能作为完整数值证明。
- [ ] mode0/seed7注入reset，mode1/seed19注入abort；修复发现的问题后仅复跑受影响矩阵，再冻结RTL。
- [ ] 确认真实IP编译清单没有FP mocks/protocol替代模型进入算术路径；服务模型仍单独标注。

验收：full numeric与代表性real-IP分别PASS；完整protocol+stored numeric不得标成4096行真实IP全量PASS。若证明链仍有缺口，补必要的分片real-IP验证。

### P9 — 2 cluster 实际OOC与性能推进门

依赖：P8、P1预算闭合；A。

新增：`scripts/cats_r4_a4_compute_array_ooc.tcl`、`python/cats_r4_a4_scaling_gate.py`、`tests/test_cats_r4_a4_scaling_gate.py`。

- [ ] 固定N=2、完整真实compute_array、Vivado2025.2、xczu15eg-ffvb1156-2-i、6.666ns；synth后先检查实例未优化丢失和资源预算再route。
- [ ] 只对明确记录的package-less外部契约边界设置OOC例外；A4内部调度/汇聚/跨cluster寄存器路径全部约束，不通过新增false-path隐藏长路径。
- [ ] 保存synth/routed DCP、setup/hold/min/max、WNS/TNS/WHS/THS、pulse width、recovery/removal、route status、DRC、methodology、utilization、power及约束覆盖；功耗无活动文件时标为vectorless。
- [ ] 必须route complete、routing errors=0、WNS>=0/TNS=0、WHS>=0/THS=0、no_clock=0、unconstrained_internal_endpoints=0、无阻塞DRC；所有例外和warning单独解释。
- [ ] 在同一真实服务环境下取得1/2对照，报告core cycles、release/drain、输出reorder wait、memory/FIFO/RAW stalls、load imbalance和source/input hashes。
- [ ] 协议模型速度只作诊断。推进4 cluster所用1.6×必须来自同等级、功能和服务可比较的RTL cycle证据；优先完整真实算术仿真/已有C实测。若仅能做代表性real-IP，先由C/D冻结足够的可比覆盖范围，不能从短smoke推导full speedup。
- [ ] speedup2>=1.6且正常负载差<5%，结合数值/时序/依赖全通过，才写`A4-2 compute/OOC READY`。

失败分流：数据逻辑长路径→A局部流水/缓存；路由拥塞→控制本地化/布局验证；C输出/存储瓶颈→最小复现交C；B算术资源/时序热点→交B。每轮新route需记录假设、源码差异和成功判据，相同candidate不原样重跑。

### P10 — 2 cluster 交付和4 cluster入口审查

依赖：P9；A交付，B/C/D分别接收。

新增：`docs/CATS_R4_A4_2CLUSTER_DELIVERY.md`、`reports/cats_r4_a4_2cluster_evidence.json`。

- [ ] 保存2 cluster代码commit与独立文档commit，证据引用前者，推送`codex/a-cats-r4-a4-2cluster`并提交给`codex/cats-r4-local-integration`审查。
- [ ] 给C3提供端口图、group映射、done/error/reset顺序、有限服务性能和集成脚本；给B提供数值矩阵；给D提供可重放对照。
- [ ] 关闭会影响4 cluster的P1资源风险、C共享瓶颈、B/C owner依赖和任何STOP记录。
- [ ] 从已验收2 cluster SHA创建`codex/a-cats-r4-a4-4cluster`；保存2 cluster独立回退点。

验收：2 cluster不是只有checkpoint PASS；有完整独立READY证据。未达到入口时不得用“已经编译成功4份”表示进入4 cluster阶段。

### P11 — 4 cluster 两波实现和提前资源检查

依赖：P10；A。

- [ ] compute_array启用N=4，其余算术/服务语义继承2 cluster；证明4套完整实体都被保留。
- [ ] 验证0/4、1/5、2/6、3/7分配；各cluster本地KV切换与32个Q slabs/group独立，不使用group奇偶误选buffer。
- [ ] 证明第二波可在允许条件下推进，慢cluster不会经无必要的全局屏障冻结其他cluster。
- [ ] 扩展completion/error仲裁、公平性、snapshot和累加器；避免共享宽组合mux/高扇出reset成为热点。
- [ ] 在运行完整长回归/route前做实际综合、资源容量与C预算复核，确认4cluster项目具备路由余量；估算不替代综合或最终PPA。

验收：4cluster分工正确且资源风险有可实现处理路径；超出预算/容量时停止route，保留2cluster并提交owner优化请求。

### P12 — 4 cluster 完整回归与1/2/4等价性

依赖：P11；A，B/D核查数值。

- [ ] 对N=4执行P7的完整双mode负载与四seed压力矩阵，按第4节逐cluster和aggregate验收。
- [ ] 增加4源同拍错误/完成、cluster3先完成、group7提前输出tensor_last但其他cluster未done、第一/二波交界reset、epoch重用与两个cluster同时背压。
- [ ] 对N=4执行P8的full numeric和八配置real-IP代表性矩阵；矩阵合计覆盖每cluster两group且输入可区分。完整两波控制走全量协议回归，真实IP完整group集成按P8风险覆盖补齐，避免每个随机seed重复整张量真实IP仿真。
- [ ] 对1/2/4输出按完整global坐标比较，检查拆分不改变head数学顺序；不得每实例重复全部32heads后只除计数。
- [ ] 复跑变更涉及的N=1/2基准作为回归；完全相同hash/依赖的既有证据可引用，无须机械重复所有昂贵测试。

验收：三个规模数值/协议一致，正常aggregate不变，各cluster工作可复算；4cluster两波和异常恢复全部通过。

### P13 — 4 cluster 最终OOC、性能与预算验收

依赖：P12；A，C/D审阅接口环境/性能。

- [ ] 真实完整N=4 OOC完成P9全部setup/hold/route/DRC门禁；资源与关键路径来自此规模实际post-route。
- [ ] 对1/2/4进行相同边界性能对照，报告speedup2/speedup4、各cluster active/busy/wait、负载差<5%、吞吐/总延迟和stage overlap。
- [ ] 核对共享输出/存储约束仍与C实现相符，禁止增加未计资源的无限队列或理想带宽。
- [ ] 更新C全板资源预留与时序风险，计算OOC结论不外推成full-board结果。
- [ ] 4cluster无法满足门禁时保留失败DCP/seed/counter，回退已验收2cluster作为候选；最终状态为A4-4 BLOCKED/NOT READY，而不是A4全部完成。

验收：4cluster全部技术门禁通过，才进入最终收尾。

### P14 — 最终READY、评审、交接与收尾

依赖：P13；A。

新增：`docs/CATS_R4_A4_DELIVERY.md`、`reports/cats_r4_a4_evidence.json`、`docs/CATS_R4_A4_TEAM_HANDOFF.md`。

- [ ] 更新所有任务状态、source与delivery SHA、接口tag、B/C接收SHA、source/input/IP/XDC/hash、精确命令、原始日志位置、全部expected/actual counter。
- [ ] 保存N=1/2/4 × mode矩阵、real-IP代表性覆盖/限制、数值误差、性能可比性、resource/setup/hold/route/DRC结果和失败历史。
- [ ] readiness工具自动核验文件/hash/证据覆盖及门禁；`git diff --check`、编译清单和owner diff审查通过。
- [ ] A4-2和A4-4分别保留单一目的提交与回退点；最终推送`codex/a-cats-r4-a4-4cluster`，向`codex/cats-r4-local-integration`提交PR，由队长组织合并。
- [ ] 交C：冻结wrapper、存储/输出时序契约、done/error/drain、资源/时序报告和C3/C4待办；交B：按group多实例数值核验；交D：相同条件的1/2/4实验及原始证据。
- [ ] 文档清楚区分“A4 compute/OOC READY”“C3/C4 system READY”“D板测/性能签核”；最后两者未完成时不写项目全部完成。

## 7. 测试入口规划与运行规则

以下入口由P3及后续任务实现，当前不应直接执行：

```powershell
# 测试脚本统一由仓库根目录运行；EvidenceRoot由任务创建且持久保存
& tests/run_cats_r4_a4_suite.ps1 -Clusters 1 -Suite baseline -EvidenceRoot <new-evidence-dir>
& tests/run_cats_r4_a4_suite.ps1 -Clusters 2 -Suite protocol -Mode 0 -Seed 7 -EvidenceRoot <new-evidence-dir>
& tests/run_cats_r4_a4_suite.ps1 -Clusters 2 -Suite full -Mode 0 -EvidenceRoot <new-evidence-dir>
& tests/run_cats_r4_a4_suite.ps1 -Clusters 2 -Suite full -Mode 1 -EvidenceRoot <new-evidence-dir>
& tests/run_cats_r4_a4_suite.ps1 -Clusters 2 -Suite numeric -EvidenceRoot <new-evidence-dir>
& tests/run_cats_r4_a4_suite.ps1 -Clusters 2 -Suite realip -EvidenceRoot <new-evidence-dir>
& tests/run_cats_r4_a4_suite.ps1 -Clusters 2 -Suite ooc -EvidenceRoot <new-evidence-dir>
& tests/run_cats_r4_a4_suite.ps1 -Clusters 2 -Suite scaling -EvidenceRoot <new-evidence-dir>
# N=2进入门禁通过后，才将上面Clusters改为4执行相应全矩阵
& $A4Python tests/check_cats_r4_a4_readiness.py reports/cats_r4_a4_evidence.json
git diff --check
```

`A4Python`、`VivadoRoot`、`IcarusRoot` 在运行前通过工具存在性检查和版本输出确定，不硬编码队长机器。所有Suite同时允许独立运行和恢复；full/numeric/realip多mode、多seed覆盖不能由一个默认mode代替。

长任务管理：

- 先快速编译/单测，再full/numeric，再代表性real-IP，最后完整route；P11资源预检例外，安排在4cluster长回归前。
- 初始超时参考现有A3：full protocol单mode约17分钟，仅作为估时起点；多实例不会保证仿真墙钟时间缩短。
- 每个仿真用有限的周期看门狗，每个工具进程用墙钟超时；超时后先读进度判断是慢还是死锁，再决定恢复/修复。
- 每轮route只启动一个，避免多份Vivado争用内存/CPU；小模型和文档可并行。
- 若同一源码/约束的已保存synth或routed DCP可用，优先恢复或补报告；不得把不同hash的checkpoint接到当前证据链。
- 不为了获得PASS更换seed、降低负载、放宽数值/时序/性能阈值。确需调整外部契约，由owner签核并对各规模重新建立公平基线。

## 8. 每个人接下来需要交什么

| 成员 | A4需要的交付 | 影响的门禁 | A能否先做其他工作 |
|---|---|---|---|
| A | P0–P14计算侧任务、测试与证据 | A4-2/A4-4 | 可以持续推进不依赖未冻结接口的部分 |
| B | B4修复接收；按group分发的两种mode数值复核；必要内部修复SHA | 正式组合/数值READY | 模型、调度单测可以先做 |
| C/队长 | A3接收、sin身份、A4接口与资源预算、有限存储/输出服务、C3/C4生产集成 | 契约、真实服务性能、系统采用 | A无需等完整板测才能做计算单测 |
| D | 阈值/公平性复核、必要同等级性能证据、后续板测 | 1.6推进口径、系统性能发布 | A可先产生候选证据 |

任何外部依赖都记录“所需内容、owner、请求文件、接收SHA、阻塞任务”。本计划尚未向B/C/D发消息，不把他们的未回复当作同意。

## 9. A4全部完成的定义

必须同时满足：

1. A4-2与A4-4生产计算wrapper均实现，N=1/2/4 group映射正确且每cluster独立三槽/状态。
2. 1/2/4完整负载计数守恒，两种正式模式数值门禁通过，随机/异常/reset测试通过。
3. 代表性real-IP证据按规模/模式/seed完整；算术mock与真实IP证据分类正确。
4. 2cluster达到同条件约定的1.6×推进线；4cluster正常负载差<5%，无长期计算侧仲裁阻塞，性能结果可复算。
5. 2/4cluster实际完整OOC满足150MHz setup/hold/route/DRC，资源预算有明确结论；无例外掩盖内部关键路径。
6. B/C公共接口与owner依赖已闭合，原始证据可取回，readiness自动检查通过，A4提交已推送并交接评审。
7. C3/C4、D后续整板/板测状态明确，不冒充已完成；若系统采用有额外未闭合门禁，单独列出。

任一项未满足都不称A4全部完成。稳定2cluster回退是有价值的交付，但不等于4cluster验收通过。

## 10. 首批实际执行顺序

第一批只执行 P0 证据/基线核查、P1可行性模型、P2接口草案和P3证据基础设施；同时形成给B/C/D的具体请求文件。先验证资源与canonical output可行性，再进入P4–P9的2cluster实现验收。P10通过后才执行P11–P14。

这份计划覆盖至A4完成的全部任务；后续每批报告统一给出：当前P编号、已通过门禁、剩余问题、依赖owner、实际耗时和下一步。任何STOP必须给出可复现原因与恢复条件，不能只要求反复“继续”。
