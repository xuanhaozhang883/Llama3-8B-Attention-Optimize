# CATS-R4 下一阶段执行与验收计划（D 状态更新版）

原计划日期：2026-09-09  
D 状态更新：2026-09-09  
负责人：队长兼 C 负责人  
适用范围：codex/cats-r4-local-integration 及 A/B/C/D 独立交付分支  
当前总状态：**UNIT DEVELOPMENT / NOT READY FOR C2 BOARD BUILD**

> 本版只根据已经生成并复核的 D1/D2 证据更新 D 的门禁、看板和下一步；A/B/C 的状态沿用原计划，不因本次修订自动升级。原文件保留不覆盖。

## 1. 目的与规则

本文依据当前 Git、交付报告和本机复现结果生成，用于队长派工、收件、复核和决定是否进入下一门禁。它不是新的接口规范，也不自动授权合并、提交、推送、生成板卡产物或修改 golden/阈值。

所有“通过”必须绑定完整源码 SHA、接口 tag、命令、工具版本、输入或日志哈希和实际输出。成员报告、截图、自制模型和目标计数不能单独升级 READY。

职责采用 CATS_R4_LEAD_ACCEPTANCE_ADDENDUM.md 的纠正：

- A：QK、scheduler、score/max、score formatter、A→B 行交接、计算 cluster 内部集成。
- B：Softmax、exp/sum/reciprocal、Accuracy FP32 weight、PV 和数值模式。
- C：banking、ownership、DMA、AXI、CDC、output、board/system、集中 Vivado/Vitis 验证。
- D：独立参考、签核器、证据链、板测和发布复核；没有独立 D 时由队长指定交叉复核者。

## 2. 2026-09-09 冻结快照

### 2.1 Git 身份

| 项目 | 实际值 |
|---|---|
| 当前分支 | codex/cats-r4-local-integration |
| 当前 HEAD | 7a36930a83ec716349b3dbc6b0bca2856cce7011 |
| 对应远端 | 与 origin/codex/cats-r4-local-integration 一致 |
| 接口 tag | CATS_R4_INTERFACE_V3_COMMIT |
| tag commit | 4d386e0f8f39c9f3c6de5ffa2ced408f254146ee |
| origin/main | 35397958107bb552453bf81858bc25847a8dcffd |
| 当前分支与 main | 当前分支独有 12 个提交，main 独有 1 个提交；合入前必须审查 |
| A2 候选分支 | origin/agent/cats-r4-a2-row-handoff |
| A2 候选 HEAD | d06d999a409a68dd89d1e4db8d78d3eb8f5574cb |
| A2 候选基线 | merge-base 是当前 HEAD 7a36930，可直接独立审查 |
| C2 历史候选 HEAD | 964da3a42245ddc7fe05a9d86c1be9d21c9bd997；只是入口门禁记录 |

工作树已有未跟踪的 artifacts/raw_logs/ 和 docs/CATS_R4_WORKSPACE_HANDOFF_LOCAL_2026-09-09.md。它们属于用户现有资料，禁止删除、覆盖或捎带提交。

### 2.2 已完成的本机基线核验

| 检查 | 结果 | 证据边界 |
|---|---|---|
| python tests/check_cats_r4_lead_release.py | PASS：4 个归档哈希、报告结构/指标、8 个输入哈希 | 仅 artifact identity |
| python tests/test_cats_r4_v3_capacity.py | PASS：4 tests | 仅容量、映射和规划算术 |
| python tests/check_cats_r4_gate_manifest.py | PASS | 仅 schema/状态/目标计数；overall 仍为 NOT_READY |
| P3C 原始串口日志 SHA-256 | 505031F483A8C85A5D912068795F84F3FBF4BFC7C8A811E3D197CEB486833995 | 与历史记录一致；本轮未重跑板测 |
| D1 v3.1.4 正式签核 | PASS：warm-up PASS；10/10 correct、10/10 deterministic；45,467,520 avg cycles；303.120724 ms；combined_failures=0 | v3.1.4 fallback 证据收口；误差门禁通过，非 bit-exact |
| D2 独立验证入口 | PASS：接口/历史原件/8 输入哈希、v3 capacity 4 tests、workload 公式 | 验证契约与软件工具，不是硬件签核 |
| D2 独立参考与协议 checker | PASS：FP64 vs Decimal(80) 522 outputs、combined_failures=0；2 个合法 token、5 类错误全部检出 | checker 自测；未输入新的 RTL event log |
| D2 full-GQA 软件重算 | PASS：524,288 outputs、combined_failures=0；different=223,988 | 历史 RTL-exact 软件模型重算，非 bit-exact，不是新 RTL/板测 |
| D2 已知风险复现 | PASS：seed 12794 的 fused-vs-math=10、fused-vs-v30=13、v30-vs-math=23 | 预期诊断失败已保留，未放宽阈值 |
| D2 结果包 | READY（validation contract/tooling only） | `workspace/D/D2_RESULTS_2026-09-09`；artifact manifest SHA-256=`F515655DE54EC296B4AEC7AA64DEB80AD63644B6B717697E6E2568A5BB7D0F3B` |

### 2.3 当前门禁

| 门禁 | 当前判断 | 解除条件 |
|---|---|---|
| v3.1.4 fallback | D1 READY；签核输出、统计和身份链已收口 | 保持只读 fallback；新候选不得复用或冒充其板测证据 |
| D2 验证契约/工具 | READY；full/stress/seed、参考、counter、telemetry 和 artifact schema 已冻结 | 等待 A/B/C 固定 SHA 后用于 D3 独立签核 |
| 接口 | READY FOR UNIT DEVELOPMENT | A/B/C 的 DELIVERY 确认同一 v3 tag |
| A2 | IMPLEMENTATION COMPLETE / SIGN-OFF NOT READY | 独立复现、full 数值、lane 等价 |
| B2/B3 | NOT READY，缺可审查的新 SHA | 完整源码/TB/log、Accuracy 和 PV 签核 |
| C memory-service | NOT READY | 真实 XPM、ownership/reset、AXI/CDC/output 闭合 |
| compute wrapper | NOT READY | A/B/C 单元 READY 后集成 |
| C2 150 MHz | BLOCKED AT ENTRY GATE | A/B/C/compute wrapper 均 READY |
| 200 MHz、2/4 cluster | NOT STARTED | 单 cluster 150 MHz 闭环后独立推进 |

## 3. 总体依赖顺序

第一波原定并行完成 A2 验收、B2/B3、C memory-service、D1/D2；其中 D1/D2 现已完成。第一波剩余工作是 A2 独立验收、B2/B3 和 C memory-service。第二波才做 single-cluster compute wrapper。第三波才允许全新 150 MHz C2 整板构建和匹配产物。single-cluster 板测完成后，依次判断 2 cluster、4 cluster 和 200 MHz。

A/B/C 单元应并行；compute wrapper 和整板按依赖串行。成员缺 Vivado 时可交 NOT READY checkpoint，由 C 在完全相同源码 SHA 上集中验证。

## 4. 当前冲刺任务包

### P0：队长收件与基线控制

负责人：队长兼 C  
优先级：最高  
状态：IN PROGRESS

任务：

1. 冻结第 2 节 SHA；成员交付必须写完整 SHA，不接受浮动分支名作为身份。
2. 要求 A/B/C/D 复制 CATS_R4_DELIVERY_TEMPLATE.md，明确 consumed interface tag。
3. 审查 origin/main 独有提交后再决定是否纳入；禁止直接 merge/pull 覆盖共享分支。
4. 收件顺序：身份保存 → 文件所有权 → 接口差异 → 单元复现 → 集中工具验证 → 独立复核。
5. 每次只升级一个门禁。checkpoint 可以 NOT READY；只有证据闭合才标 READY。

完成标准：每个候选都有 branch/base/head、接口 tag、dirty 状态、文件/输入/log 哈希和复现命令；门禁文件只反映已复核事实；未经队长决定不改 production manifest、board top、BD、constraints 和冻结 tag。

### A-R1：A2 行交接候选独立验收

负责人：A 实现；队长/C 复现；D 或交叉复核者签核  
候选：d06d999a409a68dd89d1e4db8d78d3eb8f5574cb  
状态：READY FOR REVIEW / NOT READY FOR INTEGRATION

任务：

1. 在独立 worktree 固定候选 SHA，不修改共享工作树。
2. 审计 32 个变更文件，确认只覆盖 A 的 QK、score formatter、row handoff、TB 和脚本。
3. 复现 DELIVERY 的 Icarus、XSim 和真实 FP IP OOC，保存 stdout、工具版本和源码哈希。
4. 补新 A2 wrapper 的 full-size Q/K 固定输入、独立 golden score/max 和输入哈希。
5. 定位 lane 1/2/4/8 旧回归 run 0 的 done=0000 超时，保存失败日志和最小复现。
6. 检查 A→B token、mode、last、abort、final_release 与 v3 的逐端口差异。

必须核对：

| 项目 | 期望 |
|---|---:|
| scheduler jobs | 6,144 |
| MAC steps | 1,310,720 |
| valid QK MAC | 33,816,576 |
| causal lane bubbles | 8,126,464 |
| causal rows skipped | 6,144 |
| Q slab need/ready/retire | 256 / 256 / 256 |
| engine start/complete | 6,144 / 6,144 |
| A→B rows | 4,096 |
| causal scores | 264,192 |
| clean-case protocol errors | 0 |

A2 READY：定向、随机反压/reset、full score/max、lane 等价和系统回归 PASS；full-size 使用独立参考且 combined_failures=0；OOC Complete、150 MHz WNS≥0；不以 B/C 替身冒充端到端证明。

### B-R1：B2 源码收件与 Accuracy Softmax

负责人：B；队长/C 集中工具验证；D/交叉复核者独立数值检查  
状态：BLOCKED ON DELIVERABLE SHA，但 B 可继续本地实现

第一交付：

1. 可审查 branch、完整 head/base SHA、dirty 状态和 v3 tag。
2. RTL、TB、Python/reference、脚本、原始日志和 DELIVERY；截图只作附件。
3. Compatibility/Accuracy 已实现与未实现边界；禁止按输入身份隐式切模式。
4. score16、row max、weight32、mode/token/last、N+2 read service 的端口映射。

B2：

- Accuracy 使用 FP32 weight；完成 exp、sum、reciprocal 的声明精度路径。
- 每行全局 max 后按 key 顺序产生 weight。
- 覆盖 mask、非有限值、下溢、相近 score、最大值后移、长尾、首末 causal 行和短行。
- 随机 latency/backpressure/reset 下无丢 tag、重复 weight、槽覆盖或死锁。
- full exp=264,192，issue/result/commit 闭合，错误计数为 0。
- full 与固定 seed stress 分别报告；软件结果不得写成 RTL/XSim。

B3 单独提交：

- 32 lanes 为 4 Query heads × 8 features，同一输出元素按 key 递增累加。
- V/weight request=response=consume，PV issue=result=commit。
- full PV MAC=33,816,576，Context words=524,288。
- output backpressure、bank conflict、可变 V latency、reset/epoch 和短行通过。

B READY：Compatibility/Accuracy 边界明确，full/stress/随机回归通过，combined_failures=0、error flags=0，OOC WNS≥0，保留失败 seed。

### C-R1：memory-service、AXI、CDC、output 闭环

负责人：C  
状态：IN PROGRESS / NOT READY

任务：

1. 建立 IF_V1/IF_V2/v3 精确端口与职责矩阵，不能靠版本注释判定兼容。
2. 用真实 XPM/Vivado 连续读回证明 N+2 数据/tag 对齐和无回压 response。
3. 验证 bank mapping、ownership、active-write rejection、buffer switch、retire/outstanding、abort/epoch/reset。
4. 验证 AXI 4 KiB 边界、短尾、地址/长度和总 beat 守恒；逻辑 slab 尾不等于 burst 长度。
5. CDC 使用异步时钟和单边 reset，检查 Gray pointer、旧 epoch、underflow/overflow。
6. output 覆盖满、持续反压、乱序完成、payload/tag 保持和最终保序。
7. A/B 候选只接验证 harness；单元未 READY 前不改 production manifest。

| 正常 full 项目 | 目标 |
|---|---:|
| DDR read beats | 196,608 |
| DDR write beats | 131,072 |
| rows committed | 4,096 |
| protocol/conflict/underflow/overflow/error | 0 |

负向用例单独记录期望错误增量，不污染正常用例，不屏蔽错误求 PASS。

C READY：Host/Icarus、真实 XPM XSim、CDC/AXI/output 回归和 OOC 通过；counter 闭合；150 MHz WNS≥0。

### D-R1/D-R2：fallback 收口与独立验证契约

负责人：D 或独立复核者  
状态：**D1 READY；D2 READY（validation contract/tooling only）**

已完成：

1. D1 使用 `v314-causal-bypass` profile 生成正式 JSON/Markdown；warm-up、10/10 correct、10/10 deterministic、cycles、303.120724 ms 和固定 counter 一致。
2. D1 `combined_failures=0`，明确记录“误差门禁通过，非 bit-exact”；D1 产物哈希已纳入 D2 manifest。
3. D2 固定接口 commit `4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`，校验 4 个历史归档和 8 个输入哈希。
4. D2 冻结双参考、项目阈值、full/stress/固定 seed、counter、telemetry、artifact schema 和 core/PL/application 三种计时边界。
5. D2 full-GQA 历史 RTL-exact 软件模型重算 524,288 outputs，`combined_failures=0`，但 `different=223,988`，不得称 bit-exact。
6. D2 保留历史 stress 的 online_q15=482、row_q15=459，以及 seed 12794 的 10/13/23 个诊断失败。
7. D2 独立 FP64/Decimal 参考和协议 checker 自测通过；新 RTL、XSim、OOC、全板和板测仍全部为 `NOT RUN`。

证据入口：

- `workspace/D/D2_README_2026-09-09.md`
- `workspace/D/D2_RESULTS_2026-09-09/D2_VALIDATION_REPORT.md`
- `workspace/D/D2_RESULTS_2026-09-09/D2_VALIDATION_SUMMARY.json`
- `workspace/D/D2_VALIDATION_TELEMETRY_CONTRACT_2026-09-09.md`

D 当前下一步：

1. 对 A2 固定候选 `d06d999a409a68dd89d1e4db8d78d3eb8f5574cb` 做独立审查，优先核对 full score/max、lane 等价、abort slot、token/mode/last/final_release 和证据身份；缺口未闭合时严格输出 NOT READY。
2. B 提交固定 B2/B3 SHA 后，按 D2 契约复核 Accuracy full/stress、特殊值、误差阈值、有效 exp/PV、counter 和证据身份链。
3. A/B/C 单元和 compute wrapper 均 READY 后进入 D3；此时才执行 row/online 公平消融。

## 5. 第二冲刺：单 cluster 集成

进入条件：A2、B2、B3、C memory-service 单元 READY，且 v3 端口映射兼容。

1. 固定 integration base，逐个 cherry-pick 已验收的单一目的提交。
2. 接 QK→score/max slab→Softmax/weight slab→PV→DRAIN，保持三槽状态守恒。
3. 运行端口/elaboration、定向、随机阶段 latency/backpressure/reset、长循环、异常注入和 full-size。
4. aggregate 工作不得重复：QK/PV MAC 各 33,816,576，exp 264,192，Context 524,288 words。
5. 用时间戳、slot occupancy、stall counter 证明 overlap；II 不达目标由 counter 解释。
6. row/online 消融必须同输入、精度、lanes、频率和计时边界。

集成 READY：full combined_failures=0，error flags=0；request/result/commit 和槽守恒闭合；随机反压无死锁；OOC WNS≥0。

## 6. 第三冲刺：C2 单 cluster 150 MHz 整板

进入条件：队长记录 A/B/C/compute wrapper READY，并批准 production manifest 差异。

1. 使用全新短 ASCII build root，不复用 v3.1.4 XSA/BSP/ELF。
2. 冻结 source、Vivado/IP、implementation/report、artifact/Vitis 四类 manifest。
3. 依次运行 elaboration、OOC、synthesis、implementation、route、Timing、DRC、BIT、含 bit XSA。
4. 只有 route Complete、关键时钟受约束、WNS≥0、DRC 无阻塞错误才交板测。
5. 从该 XSA 新建 Vitis platform/BSP/app 和匹配 ELF，记录产物 SHA-256。
6. 身份链复核后执行 warm-up + 10 measured runs。

整板 READY：源码、报告、BIT/XSA/ELF、输入、日志同一身份链；10/10 correct/deterministic，combined_failures=0，错误计数为 0；core/PL/application 分开计时。

## 7. 后续 GO/STOP

- 2 cluster：仅在单 cluster 150 MHz 板测 READY 后开始。aggregate 工作不翻倍；公平提升明显低于约 1.6×则 STOP，先查 bank/DMA/output。
- 4 cluster：仅在 2 cluster 全门禁通过后开始。8 KV groups 两波，负载差小于 5%；不收敛保留 2 cluster 或 v3.1.4。
- 200 MHz：独立提交。只有 post-route WNS≥0 才交板测；失败回退 timing-met 频率，不放宽约束。

## 8. 队长看板

| Owner | Work | Signoff | 固定 head | 最近 PASS | FAIL/NOT RUN | 下一依赖 |
|---|---|---|---|---|---|---|
| A | REVIEW | NOT READY | d06d999... | 本机独立复现 8 项 Icarus PASS | lane 等价、full golden、本轮 XSim/OOC | 继续 A2 验收 |
| B | 待交付 | NOT READY | OPEN | 历史报告不计签核 | 源码、Accuracy、PV | B 提交 SHA |
| C | IN PROGRESS | NOT READY | 待固定 | protocol-only 历史范围 | 真实 XPM/CDC/AXI/output | C 单元验证 |
| D | D1/D2 COMPLETE；等待候选复核 | READY（仅 D1 fallback 与 D2 validation tooling） | v3 tag `4d386e0...` | D1 签核；D2 全门禁；full-GQA 524,288 outputs combined_failures=0 | 新 CATS-R4 RTL/XSim/OOC/board NOT RUN | 先审 A2；等待 B2/B3、C 候选 |
| Integration | NOT STARTED | NOT READY | OPEN | 无 | A/B/C READY | 队长开门禁 |
| C2 board | BLOCKED | NOT READY | OPEN | 无 | 入口门禁 | 单元/集成 READY |

## 9. 提交与证据纪律

- 每个提交单一目的；架构、数值、升频、整板接入不得混合。
- 可提交/推送明确 NOT READY 的 checkpoint；READY 控制正式集成。
- 队长只 cherry-pick 固定 SHA；不移动 tag，不 force-push 共享分支。
- git diff --check、相关单元回归、一个系统回归和 DELIVERY 是最低审查条件。
- 临时工程、缓存、许可证、临时绝对路径不进 Git；脚本、manifest、报告摘要可提交。
- 原始日志和失败 seed 只追加，不覆盖删除；PASS 与 FAIL/NOT RUN 分列。
- 软件、仿真、OOC、post-route、板测必须注明证据等级。

## 10. 本次已经启动的工作

1. 已 fetch GitHub 并对当前分支执行 pull --ff-only；结果 Already up to date。
2. 已固定 A2 候选 d06d999...，确认它直接基于当前集成 HEAD，未合并。
3. 已完成三项队长基线检查，结果见第 2.2 节。
4. 已复算 P3C 原始日志 SHA-256，与历史身份一致。
5. 已修正 RELEASE_GATE 中把 FP32 weight formatter 误列给 A 的职责文字；门禁状态未改变。
6. 已在系统临时目录创建 detached A2 审查 worktree，固定到 d06d999；当前共享工作树未切换分支。
7. 已独立复现以下 8 项 Icarus 回归，退出码均为 0：
   - 32-lane engine；
   - Q-slab client，实际报告 slabs=256、engine_jobs=6144；
   - score formatter；
   - row assembler；
   - A→B handoff，实际报告 rows=4096、causal_scores=264192；
   - slot lifecycle；
   - row abort arbiter；
   - integrated row handoff wrapper。
8. 本轮 Icarus 输出包含 constant-select 工具能力提示和 TB 中 fatal 不可综合警告，未形成测试失败。尚未在本轮复现 XSim/OOC，也未解除 lane 等价和 full golden 门禁，因此 A2 仍为 NOT READY。
9. D1 已完成 v3.1.4 fallback 正式签核与结果归档；历史结果保持“误差门禁通过，非 bit-exact”。
10. D2 已完成接口/输入身份、独立参考、协议 checker、full/stress/seed、workload/counter 和 artifact schema 验证，状态为 validation contract/tooling READY。
11. D2 结果包位于 `workspace/D/D2_RESULTS_2026-09-09`；新 CATS-R4 RTL、XSim、OOC、整板和板测未运行，未因此升级任何 A/B/C 或 integration 门禁。

队长下一条最优执行指令是：D 按已冻结的 D2 契约对 `d06d999...` 开始 A2 独立签核；同时向 B 索取完整 B2 SHA，C 继续真实 XPM/CDC/AXI 单元验证。三项可以并行，且不会提前污染 production manifest。

## 11. 2026-09-10 GitHub 与消融状态补充

本节晚于前文，发生冲突时以本节为准。

1. GitHub `main` 当前为 `35397958107bb552453bf81858bc25847a8dcffd`，仍未包含最新 A2 交付。
2. `agent/cats-r4-a2-row-handoff` 的 2026-09-10 交付已把 A-owned QK/row handoff 标为
   **A unit/OOC READY**；A2 technical evidence SHA 为
   `051559ef1edf03e7b3aeed9010c1b4c5bfa577a5`。这取代前文针对旧
   `d06d999...` 检查点的状态判断，但不代表 A+B+C production integration READY。
3. GitHub 当前没有可审查的 CATS-R4 B2/B3 新分支；共享 integration 的
   `CATS_R4_RELEASE_GATE.json` 仍为 `overall=NOT_READY`，B unit、C bridge 和 C2 board
   均未解除门禁。
4. D 已完成一个不冒充 CATS-R4 的前置消融：v3.1.3 legacy consumer 对
   v3.1.4 causal consumer bypass。平均周期 `63,669,978 -> 45,467,520`，减少
   `28.588761%`，加速 `1.40034x`；consumer tile 与 V 读取均减少 `48.4375%`，
   Context words 保持 `524,288`，v3.1.4 原始板测 10/10 correct/deterministic。
5. 该前置消融交付位于
   `workspace/D/D3_PRE_ABLATION_V313_V314_2026-09-10`，状态为
   `PASS_WITH_LIMITATIONS`；缺少 v3.1.3 成对原始产物/PPA，本机也未能调用
   Icarus/Vivado，所以没有声称完成 RTL/OOC 重跑或 PPA delta。
6. 正式 CATS-R4 row/online D3 仍是 `BLOCKED_AT_ENTRY_GATE`。最小解除条件为
   B2 READY SHA、B3 READY SHA、A3 single-cluster wrapper SHA、C memory-service
   integration SHA，以及两套同输入/精度/lanes/频率/计时边界的 runner 和证据。

更新后的 D 下一步：先独立审计 A2 technical evidence SHA 和 candidate golden；
同时等待 B2/B3 与 single-cluster wrapper。收到完整候选后再启动正式 row/online D3。
