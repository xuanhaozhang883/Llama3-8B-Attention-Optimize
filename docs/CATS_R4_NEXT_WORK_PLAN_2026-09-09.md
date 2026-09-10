# CATS-R4 下一阶段执行与验收计划

日期：2026-09-09

负责人：队长兼 C 负责人

适用范围：codex/cats-r4-local-integration 及 A/B/C/D 独立交付分支

当前总状态：**UNIT DEVELOPMENT / NOT READY FOR C2 BOARD BUILD**

## 1. 目的与规则

本文依据当前 Git、交付报告和本机复现结果生成，用于队长派工、收件、复核和决定是否进入下一门禁。它不是新的接口规范，也不自动授权合并、提交、推送、生成板卡产物或修改 golden/阈值。

所有“通过”必须绑定完整源码 SHA、接口 tag、命令、工具版本、输入或日志哈希和实际输出。成员报告、截图、自制模型和目标计数能单独升级 READY。

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
| C 实现基线 | `f807b93cd2a877001005c37bdd35cb25dc6afbe2` |
| 对应远端 | `origin/codex/cats-r4-local-integration`；本地领先 7 个提交，未推送（含本轮清理与 C 证据提交） |
| 接口 tag | CATS_R4_INTERFACE_V3_COMMIT |
| tag commit | 4d386e0f8f39c9f3c6de5ffa2ced408f254146ee |
| origin/main | 35397958107bb552453bf81858bc25847a8dcffd |
| 当前分支与 main | 当前分支独有 12 个提交，main 独有 1 个提交；合入前必须审查 |
| A2 候选分支 | origin/agent/cats-r4-a2-row-handoff |
| A2 候选 HEAD | d06d999a409a68dd89d1e4db8d78d3eb8f5574cb |
| A2 候选基线 | merge-base 为历史集成基线；当前 C 提交未合入 A2 候选 |
| C2 历史候选 HEAD | 964da3a42245ddc7fe05a9d86c1be9d21c9bd997；只是入口门禁记录 |

工作树已有未跟踪的 artifacts/raw_logs/ 和 docs/CATS_R4_WORKSPACE_HANDOFF_LOCAL_2026-09-09.md。它们属于用户现有资料，禁止删除、覆盖或捎带提交。

### 2.2 已完成的本机基线核验

| 检查 | 结果 | 证据边界 |
|---|---|---|
| python tests/check_cats_r4_lead_release.py | PASS：4 个归档哈希、报告结构/指标、8 个输入哈希 | 仅 artifact identity |
| python tests/test_cats_r4_v3_capacity.py | PASS：4 tests | 仅容量、映射和规划算术 |
| python tests/check_cats_r4_gate_manifest.py | PASS | 仅 schema/状态/目标计数；overall 仍为 NOT_READY |
| P3C 原始串口日志 SHA-256 | 505031F483A8C85A5D912068795F84F3FBF4BFC7C8A811E3D197CEB486833995 | 与历史记录一致；本轮未重跑板测 |

### 2.3 当前门禁

| 门禁 | 当前判断 | 解除条件 |
|---|---|---|
| v3.1.4 fallback | 板测结果已存在，原始日志身份已复核 | D1 正式签核输出和状态收口 |
| 接口 | READY FOR UNIT DEVELOPMENT | A/B/C 的 DELIVERY 确认同一 v3 tag |
| A2 | IMPLEMENTATION COMPLETE / SIGN-OFF NOT READY | 独立复现、full 数值、lane 等价 |
| B2/B3 | NOT READY，缺可审查的新 SHA | 完整源码/TB/log、Accuracy 和 PV 签核 |
| C memory-service | STANDALONE COMPONENT GATES PASS / SYSTEM NOT READY | A/B wrapper、production reset/AXI outstanding、集成 output writer、全局 counter 闭合 |
| compute wrapper | NOT READY | A/B/C 单元 READY 后集成 |
| C2 150 MHz | BLOCKED AT ENTRY GATE | A/B/C/compute wrapper 均 READY |
| 200 MHz、2/4 cluster | NOT STARTED | 单 cluster 150 MHz 闭环后独立推进 |

## 3. 总体依赖顺序

第一波并行完成 A2 验收、B2/B3、C memory-service、D1/D2。第二波才做单 cluster compute wrapper。第三波才允许全新 150 MHz C2 整板构建和匹配产物。单 cluster 板测完成后，依次判断 2 cluster、4 cluster 和 200 MHz。

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

状态：STANDALONE COMPONENT GATES PASS / SYSTEM NOT READY

任务：

1. 已完成 IF_V1/IF_V2/v3 精确端口与职责矩阵，保留接口差异证据。
2. 已用真实 XPM/Vivado 连续读回证明 N+2 数据/tag 对齐和无回压 response。
3. 已完成 bank mapping、ownership、active-write rejection、buffer switch、retire/outstanding、abort/epoch/reset 的 standalone 验证。
4. 已完成 AXI 4 KiB 边界、短尾、地址/长度和局部 beat 守恒验证；全局 counter 尚未接入。
5. 已完成异步 CDC、Gray pointer、旧 epoch、underflow/overflow 和 reset 负向用例。
6. 已完成 output 满载、持续反压、乱序完成、payload/tag 原子性和最终保序的 4096-row 单元回归。
7. 下一步只接 A/B validation wrapper；production manifest 保持不变，等待集成级 reset/AXI/output writer。

| 正常 full 项目 | 目标 |
|---|---:|
| DDR read beats | 196,608 |
| DDR write beats | 131,072 |
| rows committed | 4,096 |
| protocol/conflict/underflow/overflow/error | 0 |

负向用例单独记录期望错误增量，不污染正常用例，不屏蔽错误求 PASS。

C READY：仍未满足。已通过 16-case Icarus、2 个真实 XPM runtime、6 个 150 MHz OOC gate；新增的系统计数闭合 gate 仅验证已经稳定的 owner-domain snapshot，尚未连接真实系统 snapshot。剩余 A/B wrapper、production reset/AXI outstanding、集成 output writer、真实全局 `rd_beats=196608`、`wr_beats=131072`、`rows_committed=4096` 闭合和整板实现。

### D-R1：v3.1.4 fallback 证据收口

负责人：D 或独立复核者

状态：原始日志身份已复核；正式签核输出待生成

1. 用 v314-causal-bypass profile 运行正式签核器，生成新 JSON/Markdown，不覆盖原始日志。
2. 复算 warm-up、10/10 correct/deterministic、cycles、303.120724 ms、consumer/bypass/V/context、exact mismatch 和 combined gate。
3. 将 BIT/XSA/ELF SHA、Git commit、build_id、输入/golden、日志 SHA 和签核结果连接为 manifest。
4. 必须写“误差门禁通过，非 bit-exact”；未知字段标 OPEN。
5. 冻结独立 reference、固定 seed stress、counter schema 和三种计时边界。

D1 READY：签核器 passed=true，历史统计一致，身份链可追溯；预测性能不得写成实测。

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
| D | IN PROGRESS | NOT READY | N/A | raw log hash 一致 | 正式签核 JSON/MD | 运行签核器 |
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

队长下一条最优执行指令是：在独立 worktree 对 d06d999... 做 A2 独立复现，同时向 B 索取完整 B2 SHA；C 继续真实 XPM/CDC/AXI 单元验证。三项可以并行，且不会提前污染 production manifest。
