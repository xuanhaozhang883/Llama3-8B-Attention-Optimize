# FPT 工程逐步提示词手册

这份文件用于把工程拆成可逐条交给 Codex 的任务。不要一次粘贴全部提示词：先粘贴 P0 建立上下文，再从当前第一个未通过的 Gate 开始。每个步骤完成后，确认它给出的测试、提交和阻塞信息，再输入下一条。

## 一、使用方法

1. 同一对话中，P0 只需输入一次；新对话先重新输入 P0。
2. 每次只输入一个步骤。提示词要求“停在本 Gate”，就是为了防止同时改多个瓶颈后无法归因。
3. 如果步骤失败，先用 PF（失败诊断），不要直接输入下一步。
4. 如果中断后恢复，先用 PR（恢复现场）。
5. 四个人并行时，分别使用 PA/PB/PC/PD，并确保每人使用独立 Git worktree；公共顶层只由 A 合并。
6. 文中的性能数字除 v3.1.3 基线外都是工程目标。仿真、综合预测和实板结果必须分开写。

推荐主线顺序：

```text
P0 → P1 → P2A → P2B → P2C → P3A
   →（有板卡时 P3B → 人工确认 → P3C）
   → P4 → P5 → P6 → P7
   → P8 → P9A → P9B → P9C → P10 → P11 → P12
```

当前没有综合许可证时，P2A 会以 `BLOCKED` 结束。此时可并行完成 P4 的计数器/模型部分、
P8 的只读模型预研，以及 D 的带宽/验证框架；但不能冻结架构或把对应 Gate 标为完成。

所有提示词统一使用下面五级证据，结论必须显式标注等级：

| 等级 | 可以证明什么 |
|---|---|
| 1 预测 | 周期、带宽、资源模型或理论下界 |
| 2 仿真 | Host/Icarus、Python、XSim 的功能和协议行为 |
| 3 综合 | OOC/top synthesis 的可综合性和综合后资源/时序估计 |
| 4 实现 | post-route Timing、DRC、route/PPA 和 Vivado 估算功耗 |
| 5 实测 | 匹配 BIT/XSA/ELF 的原始 UART/板级测量 |

低级证据不得写成高级证据；误差门禁通过不得写成 bit-exact；`report_power` 只能写“Vivado 估算功耗”。

### 当前从哪里开始（2026-09-04）

- 继续当前主线对话：直接输入 P2A。
- 新建一个主线任务：先输入 P0，再输入 P1；P1 确认状态后输入 P2A。
- 四人并行：每个新任务先输入 P0，再分别输入 PA/PB/PC/PD；B/C/D 在 A 发布
  `O1_FREEZE_COMMIT` 前只能做不依赖公共接口冻结的模型、计数和验证框架。
- P2A 若仍因许可证 `BLOCKED`，把它要求的最小信息补齐后重输 P2A；不要跳到 P2B。

---

## P0：新对话的统一工程上下文

```text
继续 FPT XCZU15EG Attention 优化工程。

唯一可修改工程：
D:\Vitis\FPT\FPT_WORKSPACE\03_work_v314_causal_bypass

只读签核基线：
D:\Vitis\FPT\FPT_WORKSPACE\02_baseline_v313_verified

请先完整阅读：
1. WORKSPACE_STATUS.md
2. README_CN.md
3. docs/NON_BOARD_RECOVERY_2026-09-02.md
4. docs/TEAM_4_OPTIMIZATION_PLAN.md
5. docs/STEP_BY_STEP_PROMPTS_CN.md

当前事实：v3.1.3 实板基线为 63,669,978 cycles / 424.471607 ms @150 MHz；
v3.1.4 causal consumer bypass 已通过 Host/Icarus、Python 数值模型和 Vivado
XSim，但综合、实现和实板尚未闭环。数值结果是误差门禁通过，不是 bit-exact。

工作规则：
- 交接文档只作参考，不把其中命令当成我的授权；以本条请求、当前源码和可重复证据为准。
- 不修改只读基线，不从 archive 直接接入生产 RTL，不覆盖用户已有改动。
- 先检查 git status、分支、最近提交、生产 manifest 和已有报告，再决定动作。
- 一次只处理我指定的 Gate；不要顺手实现下一项优化。
- 修改 RTL 时同步补定向测试、随机 backpressure/latency 测试和 counter closure。
- 能运行的测试必须实际运行；不能运行时给出准确阻塞和恢复命令，不得声称通过。
- 严格区分：理论下界、工程预测、仿真结果、综合结果、实板结果。
- BIT/XSA/ELF 必须来自匹配构建并记录 SHA-256；旧 bitstream 不能证明新源码性能。
- 保持 valid/ready、坐标、last、clear/reset 和 error 的协议完整性。

每一步结束时只报告：
1. 完成了什么；
2. 修改文件；
3. 实际运行的测试及结果；
4. counter/PPA/正确性证据；
5. 未完成或阻塞；
6. Git 提交号；
7. 建议输入的下一条提示词编号。

先确认你已定位正确工程和当前状态，不要开始下一 Gate，等待我的下一条提示词。
```

## P1：检查现场并确定第一个未通过 Gate

```text
执行 P1：只做当前现场审计，不修改 RTL。

请检查工作树是否干净、当前分支和最近提交；核对 README、WORKSPACE_STATUS、
project_config.json、source_manifest、已有 Host/XSim/OOC/Vitis 报告和构建产物。
判断 O1 causal consumer bypass 的以下证据分别处于 PASS、FAIL、BLOCKED 还是 MISSING：

- Host/Icarus 完整回归；
- full-size Python 数值门禁；
- Vivado XSim；
- OOC synthesis；
- full-board synthesis/implementation/Timing/DRC；
- 匹配 v3.1.4 BIT/XSA/ELF；
- 10-run 板测及 counter closure。

另外检查本机 Vivado 2025.2、Vitis 2025.2、XCZU15EG device 和 synthesis license。
输出一张证据表，并指出当前第一个未通过 Gate 及唯一下一步。不得把历史 Markdown
摘要当成新版本实测证据，不要重新执行耗时构建，除非为确认工具存在所必需。
```

## P2A：恢复并证明综合许可证

```text
执行 P2A：本次只恢复并验证 Vivado synthesis/device 许可证，不改 RTL，也不做整板实现。

检查 Vivado 2025.2、xczu15eg-ffvb1156-2-i device、XILINXD_LICENSE_FILE、
LM_LICENSE_FILE 和许可证来源。不要输出许可证全文、完整服务器地址或其他敏感信息。

如果是本地 .lic 文件，向 tests/run_v31_flash_consumer_ooc.ps1 传 -LicenseFile；
如果是 port@server 浮动许可证，在当前构建进程设置环境变量并省略 -LicenseFile，不能因为
它不是磁盘文件就判定无效。若脚本只接受文件，做最小、向后兼容的修复并补测试。

使用新的短 ASCII BuildRoot 运行 consumer OOC synthesis。只有 synth_design 完整结束并产生
utilization/timing 报告才能证明许可证有效；能创建 IP、elaborate 或运行 XSim 均不能证明。

输出 Vivado 版本、目标 part、许可证类型（不含密钥）、OOC PASS/FAIL、报告路径和错误关键行。
若仍缺许可证，标记 BLOCKED，说明我必须提供“本地 .lic 路径”还是“可访问的浮动许可证规格”，
然后停止；不得破解、绕过、替换器件或反复重试。
```

## P2B：完成 O1 的 Vivado 综合与实现闭环

```text
执行 P2B：只收尾 v3.1.4 causal consumer bypass 的 Vivado Gate，不开发 FIT-Context、
QK 新流水或多 cluster。

先复跑相关 Host 与 XSim 测试，再审计 Floating-Point IP 的精度、latency、rate/II、
valid/ready 端口和实际属性。随后依次完成：consumer OOC synthesis、整板 elaboration、
synthesis、implementation、Timing、DRC 和含 bit 的 XSA 导出。使用新的短 ASCII
`FPT_VIVADO_BUILD_ROOT`，不得复用旧工程。

重点审计 scripts/create_fp32_ips.tcl 中 `B_Precision_Type`、`Has_A_TREADY`、
`Has_B_TREADY` 等警告；必须核对实际生成 IP 的精度、端口及 valid/ready 语义，
不能只压掉警告。依次运行 tests/run_v31_flash_consumer_checks.ps1、
tests/run_v313_qk4_system_checks.ps1、tests/run_v31_flash_consumer_vivado.ps1、
tests/run_v31_flash_consumer_ooc.ps1、01_check_rtl.bat 和 02_build_bitstream.bat；
发现问题时做最小修复并从受影响的最早门禁重跑。

验收要求：
- 小规模定向 TB 为 FIFO=4、processed=3、bypass=1、V vectors=12、Context words=64；
- FIFO enqueue/dequeue 均为 32,768；
- Softmax/Context processed 均为 16,896；
- causal bypass 为 15,872；
- V vectors 为 1,081,344；
- Context 输出为 524,288 words；
- protocol/error flags 为 0；
- causal bypass 关闭时既有 v3.1.3 consumer 行为和测试不退化；
- full-size 数值门禁 combined_failures=0；不得称为 bit-exact；
- full-board WNS≥0，DRC 无阻塞错误；
- synthesis/implementation 均为 Complete，关键路径无未约束时钟；
- 记录 LUT/FF/BRAM/DSP/URAM、WNS、route status、Vivado 估算功耗及 BIT/XSA SHA-256；
- source_manifest.tcl 覆盖全部生产 RTL，产物来自本次干净构建。

如果许可证仍缺失：保留已通过测试，记录 Vivado 的原始许可证错误和准确恢复命令，
将本步骤标记为 BLOCKED；不要反复运行综合，也不要用旧报告代替。停在 P2B。

如果成功，运行 python/extract_ppa_summary.py，更新 WORKSPACE_STATUS 和恢复报告，
提交一个只包含 Vivado Gate 收尾的 Git commit。这里只能报告实现后时序/PPA，不能
声称板上正确性或 240～280 ms 实测提升。
```

## P2C：用本次 XSA 生成匹配 Vitis 产物

```text
执行 P2C：只用 P2B 本次导出的 v3.1.4 XSA 建立全新 Vitis 2025.2 workspace 并生成 ELF。

不得使用恢复阶段借用的 v3.1.3 XSA，也不得把 SHA-256 为
BAD0162B1997E713711086D9063DCD7BFC269B0AE1891DEC16074B8BCAACEC4E 的临时 ELF
当成匹配产物。显式设置 FPT_XSA_OVERRIDE 和新的短 ASCII FPT_VITIS_WORKSPACE，
运行 scripts/create_vitis_app_xsct.tcl，重新生成 platform/BSP/app，不复用旧 BSP。

核对 xparameters 中 A53、GPIO 0x80000000 和实际硬件接口；确认软件启用
FPT_V314_CAUSAL_BYPASS=1。对 BIT、XSA、ELF 计算 SHA-256，并生成 artifact manifest，
记录 Git commit、Vivado/Vitis 版本、构建时间、绝对路径和哈希。

本步通过只证明“硬件与软件产物匹配且 ELF 可编译”，不能证明上板正确或性能提升。
更新状态并提交产物身份链说明；不要开始板卡操作。
```

## P3A：升级 v3.1.4 板测日志签核器

```text
执行 P3A：上板前升级 python/signoff_v31_board_log.py，使其同时支持 legacy-v313 和
v314-causal-bypass；现有 v3.1.3 行为和测试必须保持不变。本步骤不连接或复位板卡。

加入显式 profile 选择。v3.1.4 每个 measured run 必须检查：QK computed/skipped/
masked emitted=16896/15872/15872；Flash Context processed/bypassed=16896/15872；
V vectors=1081344；Context words=524288；error detail、causal error flags 和
combined_failures 均为 0；10 次 exact/strict mismatch 统计确定；warm-up、10 个正式 run
和最终 PASS marker 完整。

为正确日志、错误计数、缺 run、重复 run、错误标志及非确定性补单测，并运行
tests/run_v31_board_log_checks.ps1。性能基线为 v3.1.3 的 63,669,978 cycles /
424.471607 ms @150 MHz；240～280 ms 仅展示为规划区间，不擅自编码成 hard gate。
提交签核器与测试，停在 P3A。
```

## P3B：上板前只读预检

```text
执行 P3B：只做上板前检查，不复位、不烧写、不下载 ELF。

用 scripts/probe_board_xsct.tcl 只读检查 JTAG；枚举 UART，若有多个候选则停止并让我选择，
不要猜。显示将使用的 BIT、XSA、ELF、psu_init.tcl 绝对路径和 SHA-256，验证它们均来自
P2C 的同一 artifact manifest/Git commit。确认 UART 为 115200 8N1，新的原始日志目录
不会覆盖历史数据。

审计 scripts/run_on_board_no_gtr_xsct.tcl 的 BIT 选择：不得在多个候选中静默取第一个；
如存在歧义，增加显式 BIT 参数并保持旧接口兼容。最后输出一张预检清单并停止，等待我明确
回复“确认上板”。本步骤不得产生板测结论。
```

## P3C：有板卡后完成 O1 实板签核

```text
执行 P3C：我已确认上板。只使用 P3B 锁定的匹配 v3.1.4 BIT/XSA/ELF 做实板签核，不改架构。

先启动 UART 原始日志捕获，再通过 XSCT 编程明确指定的 BIT、执行匹配 PS 初始化、下载明确
指定的 ELF。测试程序只执行一次完整的 1 次 warm-up + 10 次 measured run，不挑选成功 run，
不覆盖失败日志。

逐项校验：正确性 JSON、10 次 deterministic/correct、平均/最小/最大 PL cycles、延迟、
FIFO 32,768/32,768、processed 16,896、bypass 15,872、V vectors 1,081,344、
Context words 524,288、所有错误计数为 0。

将 v3.1.3 的 424.471607 ms 与 v3.1.4 实测值做单变量消融。240～280 ms 只是目标，
若未达到，不要调数字；用各状态 busy/stall counter 定位未随 tile 数下降的部分。
报告 PL cycles 和 wall time 的 min/avg/max/stddev/jitter、实际加速比；把规划值单独标为预测。
保存原始日志、JSON/Markdown、hash 清单和工具版本。任一 run 失败时保留整份失败记录，
不得重跑后只留成功数据；无外部功耗仪或经校准传感器时不得写“实测能耗”。
更新状态并提交。停在 Gate 2，不实现 O2。
```

## P4：建立 FIT-Context 的观测和周期模型

```text
执行 P4：为 O2 FIT-Context 建立 profiler、接口契约和周期模型，暂不重写 Context 数据面。

阅读 flash_context_fusion_backend、flash_context_update_pe、V cache、Online Softmax 及其 TB。
画出当前 REQ/RSP/update/divide/normalize/output 状态依赖，确认真实 valid/ready 行为，
不要硬编码 Xilinx IP latency。

新增或补齐以下可综合计数：V request、V response、update issue、update wait、RAW stall、
tag FIFO full、divide、normalize、output、tile issue/result/commit。优化关闭时计数器不能改变
输出或明显改变周期。增加小尺寸定向测试、随机 V response latency 和 output backpressure 测试。

建立 baseline 公式和 FIT 目标：V request II=1；feature-chunk II 先≤8、最终≤5；
Context consumer 目标 3～5M cycles。输出接口表、依赖表、计数地址表和两阶段实现计划，
提交“observability only” commit。不要在本步骤实现完整 tagged scheduler。
```

## P5：先实现连续 V request

```text
执行 P5：只把 Context 的 V 请求从 REQ/RSP 交替改成可连续发射，不实现完整 FIT tag 乘加调度。

要求 request 和 response 各自通过 valid/ready 握手；使用请求 tag/FIFO 关联 group、head、row、
key、feature chunk；支持可变 response latency 和 backpressure；不能假设 request 后固定一拍返回。
保持 score、Context 输出顺序、数值运算和跨 key tile 依赖不变。

验收：稳定段 V request II=1；请求数=响应数=消费数；没有 tag 丢失、重复、覆盖或越界；
随机延迟/回压测试通过；旧兼容模式输出和计数不退化；完整 Host/Python/XSim 回归通过。
给出前后 V request/wait counter 消融。只提交连续 V request，停在 P5。
```

## P6：实现 FIT-Context tagged/modulo pipeline

```text
执行 P6：在 P5 已通过的基础上实现 FIT-Context，不修改 QK 或 cluster 数量。

将 16 个独立 feature chunk 作为 tag 交织到现有 32 路 Context PE；拆分 multiplier issue、
product store、4 次左结合 add、partial/O-state commit。所有 tag 只随真实 valid/ready 推进。
同一 (row, feature) 必须按 key tile 顺序提交；不要跨 key tile 重排，不增加第二套 FP array。

优先做可验证版本：feature II≤8；通过后再优化到 II=5。product/partial/O-state 使用规则
banking，若资源过高再单独做 RAM 映射提交，不把调度和存储重写混在同一 commit。

必须加入 tag 守恒、RAW hazard、FIFO overflow/underflow、duplicate commit、missing commit、
last/order 的断言和随机 latency/backpressure 测试。

验收：Context 输出数量/顺序不变；full-size combined_failures=0；V request II=1；
feature II≤8，冲刺≤5；Context 3～5M cycles；单 cluster 阶段预算 LUT≤90k、FF≤180k、
BRAM36≤140、DSP≤450、WNS≥0。报告实际值；达不到目标时由 counter 解释，不伪称完成。
提交 O2 并停在 P6。
```

## P7：FIT-Context 集成签核和瓶颈迁移判断

```text
执行 P7：只对 O1+O2 做完整消融和签核，不开始 QK RTL 改造。

运行 Host/Python/XSim、OOC、full-board synthesis/implementation/Timing/DRC；有板卡时生成匹配
BIT/XSA/ELF，完成 warm-up+10-run。比较 baseline、O1、O1+O2 三档的 cycles、Context cycles、
QK cycles、FIFO stall、资源和 WNS。

目标是 Context consumer 3～5M cycles、整机 70～120 ms。判断新的主瓶颈是否已经变成 QK；
只有 QK busy/issue/wait 证据支持时才批准进入 P8。若 Context 仍主导，列出最大两个 counter，
回到 P5/P6 修复。更新状态、保存消融报告并提交签核 commit。
```

## P8：比较 QK 两种方案并冻结微架构

```text
执行 P8：只审计和建模 QK continuous/interleaved 优化，不立即大改 RTL。

分析 qk_parallel_systolic_gqa_top、qk_systolic_tile、qk_systolic_pe、result scaler、Q/K 请求通道。
补齐 input/request、mul issue/result、add issue/result、tile wait、scaler、output stall counter。

分别给出两套可复算方案：
A. exact tile/tag interleave：保持同一 score 按 d 左结合累加；
B. competition D-vector：提高 D 维并行，但单独评估数值变化。

比较每套的周期公式、outstanding 深度、DSP/LUT/BRAM、预计 WNS、score 重排需求和验证风险。
结合 P7 实际瓶颈选择一套作为正式实现；不得因为资源有余量就默认 QK8。输出冻结的端口、tag、
依赖、commit 顺序、回退参数和验收表，只提交设计/计数/测试骨架。停在 P8 等待确认。
```

## P9A：先流水化 QK result scaler

```text
执行 P9A：依据 P8 的 counter，只把 QK 共享 result scaler 改成可流水接收，不修改 Q/K
请求和 MAC 累加结构，也不修改 FIT-Context 或 cluster 数量。

让 TILE×TILE raw score 在填充后连续进入 scaler；用 score index/tag 保证 scaled score 的
坐标、mask、last 和原输出顺序。保留兼容模式，不改变 scale 常量、BF16/FP32 转换和舍入。

增加连续输入、随机 out_ready 和 reset 测试；运行 lane 1/2/4/8、causal skip、score-by-score
及既有系统回归。验收：无回压时 scaler input II=1；16 个 score 数量、坐标和 debug 值与
兼容路径一致；停顿时 data/tag 稳定；给出 WAIT_SCALER 周期前后消融。

只提交 scaler 单变量优化，停在 P9A。
```

## P9B：实现 QK tile/tag 交织与连续发射

```text
执行 P9B：在 P9A 已通过的基础上，严格按 P8 冻结方案实现 QK tile/tag 交织；默认主配置
仍为 QK_LANES=4，不用增加到 QK8 代替调度优化。

把逐 MAC 的全局 WAIT_INPUT/SHIFT/ISSUE/WAIT_PE 拆成 issue/result/commit；允许多个互不依赖的
row/tile 在 FP latency 内交织；按已证明的 loader 契约加入 2～4 个 outstanding Q/K request。
exact 模式必须保持同一 score 沿 d=0..127 的左结合累加顺序，输出坐标和次序不变。

加入 request/MAC/score 数量闭合、score-by-score、lane equivalence、随机 Q/K latency、FIFO
backpressure、tag 守恒、reset 和异常注入测试。若有 competition-fast 模式，必须独立开关、
默认关闭，并与 exact 分开构建和报告。

验收：score 数量/坐标/causal skip 精确一致；exact combined_failures=0；随机回压下无死锁、
丢失、重复或 tag 覆盖；WAIT_INPUT/WAIT_PE 明显下降并报告有效 MAC issue 占用率。
只提交单 cluster 交织流水，不做系统 O3 签核。
```

## P9C：O3 全系统集成与单集群签核

```text
执行 P9C：把已验收的 QK scaler 与交织流水合入 O1+O2，完成 O3 单变量签核；不加入
2/4 cluster、DDR 重构、混合精度或升频。

解决必要的接口传播、manifest、profiler 和兼容模式问题。运行完整 Host/Python/XSim、OOC、
full-board synthesis/implementation/Timing/DRC；有板卡时再生成匹配 BIT/XSA/ELF 并做 10-run。

验收：兼容模式复现 O1+O2；优化模式 full-GQA combined_failures=0；全部 causal/Context counter
不变；QK 与 Context 稳态吞吐差<20%；full-board WNS≥0。形成 baseline、O1、O1+O2、
O1+O2+O3 四列同口径消融，报告 cycles/DSP/LUT/BRAM/WNS 和证据等级。

≤70 ms 是阶段目标；没有匹配产物的 10-run 板测前只能写模型、仿真或实现结果。
提交唯一 O3 集成提交并停在单 cluster。
```

## P10：先完成 2-cluster

```text
执行 P10：把稳定的 O1+O2+O3 单 cluster 参数化为 2 cluster，不直接跳到 4 cluster。

先建立带宽和端口预算：每 cluster 的 Q/K/V 需求、bank 冲突、FIFO 深度、Context 写带宽。
实现 cluster-local Score FIFO、Softmax/Context 状态、计数器和 group 静态分配；Q/K/V 按 group
和 D-lane 分 bank；完成队列后再仲裁写回，避免一个全局大 mux 或全局停顿。
aggregate logical work 不得因复制 cluster 而翻倍。完整运行总计数仍为 processed=16896、
bypass=15872、V vectors=1081344、Context words=524288；理想每 cluster 分别为
8448、7936、540672、262144。

增加两个 cluster 不同 latency/回压、完成乱序、写回保序、bank collision 和 reset/clear 测试。
运行 OOC 与 top-level implementation，检查 CDC、扇出和路由。

验收：所有输出和正确性门禁通过；两 cluster cycles 差<5%；无长期全局仲裁阻塞；WNS≥0；
端到端目标≤40 ms。若 WNS<-0.5 ns 或路由明显拥塞，停止扩容并给出 floorplan/banking 修复方案。
提交 2-cluster，不继续复制到 4 cluster。
```

## P11：实现 CATS-4 四集群

```text
执行 P11：仅在 P10 通过后扩展到 CATS-4。

实现 4 个 cluster、8 个 GQA group 两波调度、cluster-local memory/FIFO、分布式完成队列和
Context 写回仲裁。先在 150 MHz 下验证 4-cluster 架构；稳定后用独立提交只做 200 MHz
时序收敛。若 AXI/GPIO 保持慢域，使用明确的 async FIFO、Gray pointer 和 reset sequencing。
为高扇出配置做本地寄存，不跨全器件广播细粒度控制。分别报告架构减少的 cycles 和升频减少的
wall time，不能把二者混成同一项收益。
aggregate 总工作量保持不变；理想每 cluster 的 QK computed/skipped=4224/3968、
Context processed/bypass=4224/3968、V vectors=270336、Context words=131072。

逐项 sweep 1/2/4 cluster，保存 OOC 和 full-board LUT/FF/BRAM/DSP/URAM/WNS/route delay；
不得从单 cluster 资源线性外推。预算停止线：LUT≤230k、FF≤380k、DSP≤2,400、BRAM36≤480、
URAM 64～96 且 WNS≥0。

有板卡时以匹配产物跑 10-run。验收：cluster 负载差<5%；没有单一仲裁器长期阻塞；正确性通过；
200 MHz timing met；目标 15～35 ms。未达到目标时保留稳定 2-cluster 回退版本。
```

## P12：最终工程签核与论文材料

```text
执行 P12：对最终候选版本做发布签核，不再加入新优化。

从干净 checkout 按 README 一键重建；运行所有 Host/Python/XSim/OOC/full-board 测试；记录工具版本、
配置、Git commit、source manifest、BIT/XSA/ELF/report SHA-256。有板卡时完成 warm-up+10-run、原始 UART、
correctness JSON、counter closure 和功耗口径。

生成 baseline、O1、O1+O2、O1+O2+O3、2-cluster、4-cluster 的消融表。每一项标明是理论、预测、
仿真、综合还是实板；不能将 core synthesis 与 full-board post-route 资源混列，不能宣称 bit-exact。

最后整理：复现说明、架构图、模块贡献、性能/资源/精度表、已知限制、现场演示步骤和稳定回退版本。
若任一正式证据缺失，将其列为未完成，不用推测补齐。
```

---

## 二、四个人各自的新任务启动提示词

四个人必须使用不同 worktree。推荐分支名：

```text
A: codex/a-integration
B: codex/b-fit-context
C: codex/c-qk-pipeline
D: codex/d-cluster-validation
```

文件所有权固定如下；B/C/D 需要公共接口变化时提交 integration request，不直接改公共 top。

| 角色 | 独占开发范围 | 禁止直接修改 |
|---|---|---|
| A | `rtl/board/**`、公共 `*top.sv`、`scripts/source_manifest.tcl`、`project_config.json`、生产 Vitis 集成 | B/C/D 算法内部 |
| B | Context backend/update PE、新建 `fit_context_*`、FIT TB/模型 | board、公共 top、QK、cluster |
| C | `rtl/core/bc/qk/**`、QK TB/模型 | board、公共 top、Context、cluster |
| D | 新建 `rtl/core/cluster/**`、memory/arbiter、cluster 回归与 PPA/带宽工具 | board top、B/C 算法内部 |

`flash_online_softmax_frontend.sv` 采用阶段所有权：O1 冻结前只由 A 修改；A 发布
`O1_FREEZE_COMMIT` 后，B 才能基于该提交继续 Softmax/FIT 工作。

### PA：A——系统架构、因果协议和主线集成

```text
我是成员 A，负责系统架构、causal 协议和主线集成。请基于最新集成分支建立/确认独立 worktree，
记录 base commit。我的修改范围是 rtl/board、公共 online top、source_manifest、project_config 和
版本/集成文档；不要替 B/C/D 重写其算法模块。

当前先执行：检查 O1 Gate 2 还缺哪些综合、IP 属性、counter 和板测证据；能完成的直接完成。
同时冻结 B/C/D 所需接口，包括 valid/ready、tag、坐标、last、clear/reset、error 和 counter 语义。
公共顶层只由我合入。每次只 cherry-pick 一个可归因提交，并运行完整回归。

交付：接口契约、O1 closure、集成顺序、冲突清单、消融报告和主线提交号。停在当前 Gate。
```

### PB：B——FIT-Context

```text
我是成员 B，负责 Online Softmax 与 FIT-Context。请基于 A 指定的 base commit 使用独立 worktree，
只修改 Context/Softmax/V-cache 相关实现、自己的 TB 和模型；不要修改 board top、全局调度或 QK。

按三个独立提交推进：
1. observability only：Context issue/result/commit/stall counter；
2. continuous V request：真实 valid/ready + response tag，目标 II=1；
3. FIT tagged pipeline：16 feature tags，先 II≤8，再冲 II=5。

保持同一 (row,feature) 的 key-tile 顺序和左结合加法，不硬编码 FP IP latency。每个提交都运行
随机 V latency/backpressure、tag 守恒、输出顺序和 full-size 数值回归。交付 Context cycles、II、
资源、WNS、误差和可 cherry-pick commit；不要自行接公共 top。
```

### PC：C——QK continuous/interleaved

```text
我是成员 C，负责 QK 连续流水和交织累加。请基于 A 指定的 base commit 使用独立 worktree，
只修改 QK/RoPE 数据面、自己的 TB 和周期模型；不要修改 Context、board top 或 cluster wrapper。

先只做计数和方案比较：exact tile/tag interleave 对比 competition D-vector，给出 cycles/DSP/LUT/BRAM/
WNS/数值风险。经确认后再实现一个方案。重点解决共享请求、逐 MAC 等待和单 scaler，不默认增加到 QK8。

exact 模式必须保持逐 d 左结合顺序；所有模式保持 score 坐标、mask、last 和输出数量。运行 lane
equivalence、score-by-score、随机 Q/K latency、FIFO backpressure 和 full-size 数值回归。交付设计、
计数消融和可 cherry-pick commit；不要自行改公共 top。
```

### PD：D——多集群、存储、验证和 PPA

```text
我是成员 D，负责多集群、存储 banking、系统验证和 PPA 平台。请使用独立 worktree，不改 A 拥有的
board top；新建参数化 cluster/memory/arbiter 模块和 tests/python/vitis/report 工具，通过接口交给 A 合入。

先完成 1/2/4 cluster 带宽模型、Q/K/V bank 地址规划、统一回归矩阵和 PPA 汇总。等单 cluster O1+O2+O3
稳定后，先实现 2 cluster 并签核，再扩到 4 cluster。每个 cluster 使用本地 FIFO/状态/计数，避免全局大 mux。

验收 2 cluster：≤40 ms 目标、负载差<5%、WNS≥0。验收 4 cluster：200 MHz、15～35 ms 目标、
负载差<5%，并遵守资源停止线。负责汇总证据，但每个算法 owner 仍必须提供自己的单元测试。
```

### PI：A 使用的集成审查提示词

```text
执行一次候选分支集成审查，先 review、不要立即合并。

候选 owner：[B/C/D]
候选 branch/commit：[填写]
目标 Gate：[填写]
base commit：[填写]

检查是否越过文件所有权、是否混入多个优化、接口是否符合冻结契约、是否有定向/随机/full-size 测试、
counter 是否守恒、性能是否来自同一基线、PPA 是否为 full-board、是否存在未说明的数值模式变化。
输出必须修复项和可选改进项。只有所有 Gate 证据齐全时才建议 cherry-pick；合入后运行全回归并生成
单变量消融。不要自动继续下一 Gate。
```

### PDAY：任一成员每日续接

```text
继续成员 [A/B/C/D] 的工作。先读取 branch、HEAD、git status、base commit、该成员最近交付记录
和测试结果，用四行说明：当前 Gate、已验证证据、剩余最小任务、外部阻塞。

今天只选择一个最接近闭环的可验收改动，不同时推进两个优化。只修改该成员拥有的文件；
需要公共 top 或其他成员算法变更时，生成 integration request，写清端口、方向、位宽、握手、
reset/default、对应 TB 和依赖提交，不直接越界修改。

完成后运行直接相关的单元测试、随机 backpressure/latency 测试和一个系统回归；更新 expected/
actual counter、性能证据等级、交付记录；形成单一目的 commit。报告下一条应输入的提示词编号。
不得自行 merge/rebase 其他成员分支，不得修改黄金结果或阈值来制造通过。
```

### PQA：成员交付审查

```text
审查成员 [A/B/C/D] 的候选提交。

基线：[BASE_COMMIT]
候选：[CANDIDATE_COMMIT]
目标 Gate：[GATE]

先审计 diff、文件所有权和生成物，再验证接口契约、valid/ready 停顿、reset/clear、tag/坐标/
last、counter closure、定向/随机/full-size 回归、兼容模式、cycles/PPA/WNS 和证据等级。
不得删除失败 seed、放宽误差、隐藏负 WNS 或把预测写成实测。

只能修复本角色范围内的问题；跨角色问题形成 integration request。最后严格输出 READY 或
NOT READY、commit、修改文件、测试矩阵、expected/actual counter、数值误差、PPA、阻塞和
A 需要完成的接线。只有 READY 才允许进入集成。
```

### PM：协调者顺序合并

```text
你是唯一主线协调者。主线必须是独立且干净的 integration worktree；先输出 branch、HEAD、
git status 和稳定回退 commit。用户未提交修改不得覆盖、stash、reset 或 checkout。

待合入 owner：[A/B/C/D]
候选 commit：[填写]
候选 base：[填写]
目标 Gate：[填写]

固定顺序是 A/O1 → B/FIT-Context → C/QK → D/2-cluster → D/4-cluster，一次只合一个 READY
提交。合入前读 DELIVERY、审计文件所有权和临时/生成物；合入后立即运行该 Gate 完整回归，
记录 expected/actual counter、误差、cycles、LUT/FF/BRAM/DSP/URAM、WNS 和证据等级。

任一 Gate 失败时停止叠加，保留前一稳定 commit，不自动继续下一 owner。输出 MERGED、REJECTED
或 BLOCKED、新主线 commit、实际文件、回归矩阵、冲突责任人、稳定回退点和下一位允许交付者。
```

---

## 三、恢复、失败诊断和每日交接提示词

## PR：中断后恢复现场

```text
恢复当前 FPT 工程任务。不要从头重做。

先读取 WORKSPACE_STATUS、最近 Git log、git status、当前分支、最近报告和测试产物；找出最后一个已通过
Gate、当前未提交改动属于谁、上一次失败的准确命令和错误。将“源码已实现、测试已通过、综合已通过、
板测已通过”分开判断。

输出：当前 Gate、已完成证据、未完成项、是否可安全继续、下一条最小动作。工作树不干净时先识别并
保留用户改动，不执行 reset/checkout。得到结论后继续上次未完成的最小动作，不扩大范围。
```

## PF：某一步失败后的诊断

```text
当前步骤失败。只诊断并修复本次失败，不重构无关模块，不进入下一 Gate。

失败命令：[粘贴]
完整首个错误及上下文：[粘贴]
当前 commit/分支：[填写]

请先复现最小失败，区分源码 bug、测试 bug、路径/工具版本、IP 属性、许可证、资源、时序和板卡环境。
给出证据支持的根因，优先加入能稳定复现的回归测试，再做最小修复。修复后重跑定向测试和受影响的
完整回归。若是许可证/板卡等外部阻塞，停止重试，列出必须由我提供的内容和恢复命令。
```

## PE：每天结束时生成交接记录

```text
为今天的 FPT 工作生成可续接交接记录，并更新 WORKSPACE_STATUS（仅写真实证据）。

记录：日期、人员/分支/base commit、目标 Gate、完成项、修改文件、测试命令与结果、关键 counter、
PPA/正确性、生成产物及 SHA-256、失败与阻塞、未提交改动、下一步唯一动作和应输入的提示词编号。
明确区分预测/仿真/综合/实板。检查 git diff --check 和 git status；只有验证通过且变更边界单一时提交。
```

## PP：只询问当前进度，不做修改

```text
只汇报当前 FPT 工程进度，不修改文件、不运行耗时构建。

根据 git status/log、WORKSPACE_STATUS 和现有报告，按 O1、O2、O3、2-cluster、4-cluster 列出：
完成百分比不是重点，只给 PASS/IN PROGRESS/BLOCKED/NOT STARTED、已有证据、缺失证据、owner 和下一动作。
最后告诉我现在应该输入 STEP_BY_STEP_PROMPTS_CN.md 中哪一条提示词。
```

## 四、关键决策停止线

- O1 没有匹配 BIT/XSA/ELF 和 counter closure 时，只能说 RTL/仿真完成。
- Context 没到 3～5M cycles 或仍是主瓶颈时，不合入 QK 高风险优化。
- 单 cluster 未达到稳定高占用时，不复制 2/4 cluster。
- 2 cluster 的 WNS/带宽/负载均衡未通过时，不上 4 cluster。
- CATS-4 没有稳定 10-run 时，不把混合精度或 250 MHz 当正式版本。
- 任意性能数字没有同一输入、同一计时口径和相邻版本消融时，不写进论文结论。
