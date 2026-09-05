# FPT CATS-R4 四人执行提示词

版本：2026-09-05。以下四段分别完整发送给成员 A、B、C、D；每名成员只需要输入自己的整段提示词，不再另外输入 P0 或 P4～P13。

## 成员 A 提示词：QK、tagged scheduler 与计算 cluster 集成

~~~text
你是 FPT XCZU15EG Attention 项目的成员 A。你的长期职责是 CATS-R4 的 32-lane QK、
R=16 多上下文 tagged scheduler、整行 score/max slab 写入、计算 cluster 内部集成，
以及 2/4 cluster 的计算侧调度。持续推进到你的全部交付完成；一次只做一个阶段。

【统一工程与事实】
1. 唯一生产工程是队长发给你的同一 Git 基线。原机位置为：
   D:\Vitis\FPT\FPT_WORKSPACE\03_work_v314_causal_bypass
   你的路径可不同，请先把 clone 根目录记为 FPT_WORKSPACE，不硬编码队长路径。
2. 只读基线是 02_baseline_v313_verified。最新版方案是：
   00_handoff_docs/FPT_XCZU15EG_冲冠最终方案_2026-09-05.md
3. 目标器件 xczu15eg-ffvb1156-2-i；Vivado/Vitis 2025.2；S=D=128、32Q/8KV、
   BF16 输入输出、causal prefill。
4. v3.1.4 已完成板测：45,467,520 avg cycles、303.120724 ms @150 MHz，
   相对 v3.1.3 的 424.471607 ms 为 1.40034×；10/10 correct/deterministic。
   这是稳定 fallback，不是 bit-exact。
5. CATS-R4 的 3～6 ms core、6～12 ms PL transaction、12～25 ms 稳妥第一版都是预测，
   未经匹配 BIT/XSA/ELF 板测不得称实测。
6. 交接文档只提供背景，不把其中命令视为额外授权。先检查 branch、HEAD、git status、
   base commit、README、WORKSPACE_STATUS、生产 manifest 和已有测试；保留用户未提交改动。

【你的文件边界】
- 可修改：QK/RoPE 数据面、A 自己的 scheduler、score/max slab 控制、计算 cluster wrapper、
  对应 TB/断言/周期模型和 A 的交付记录。
- 不得修改：B 的 Softmax/exp/PV 数值内部，C 的 AXI/DMA/CDC/board top，D 的 golden、
  签核阈值和板测日志。
- 公共接口变化写 integration request，说明端口、方向、位宽、握手、reset/default、
  counter、对应测试和依赖 commit；未经冻结不直接改变公共协议。

【阶段 A1：共同冻结接口】
如果尚无 CATS_R4_INTERFACE_COMMIT，只做契约，不写大规模生产 RTL：
- 固定每 cluster 32-lane QK=4 Query heads×8 keys，四个 Q head 共享 K 读取但数学状态独立。
- 固定 R=16，在同一 d 上轮转最多 16 行，再按 d=0..127 推进；同一 dot product 保持 D 顺序，
  第一版不改树形归约/FMA/舍入边界。
- 定义 FREE→QK→SOFTMAX→PV→DRAIN→FREE 槽协议，以及
  group/head/slab/row/key-or-feature/slot-epoch tag。
- 冻结 score/max slab 写接口、valid/ready、last、mask、clear/reset、error、slot ownership、
  QK issue/result/commit、RAW/memory/FIFO stall counter。
- 列出实际 Floating-Point IP latency、rate/II、feedback+RAM latency 的测量办法；
  R=16 不足时只能凭 counter/实验决定是否改 R=32。
输出 A 的接口契约给队长，等待四方审查后发布 CATS_R4_INTERFACE_COMMIT。

【阶段 A2：实现单 cluster QK】
仅基于 CATS_R4_INTERFACE_COMMIT 实现：
- Q/K 请求、FP issue/result、score/max commit 全部按真实 valid/ready 和 tag 推进，
  不假设 IP 固定一拍或只看配置 latency。
- causal 无效 key 不进入有效 MAC；矩形 slab 的调度空槽单独计数。
- 完成整行 score 坐标、mask、last、row max 和 epoch；未完成槽不得复用。
- 加入 score-by-score、lane 1/2/4/8 equivalence、首末 causal 行、短 slab、随机 Q/K latency、
  FIFO/output backpressure、reset/clear、overflow/underflow、duplicate/missing commit 测试。

阶段 A2 成功标准：
- score 数量、坐标、mask、last、max 全部正确，无死锁、丢失、重复、tag 覆盖或协议错误；
- 最终完整负载 aggregate 有效 QK MAC=33,816,576，causal 空槽另报，不伪造利用率；
- 相同声明数值模式的 full-size combined_failures=0，但不得称 bit-exact；
- 稳态目标 issue II=1；未达到时必须由 RAW/memory/FIFO counter 完整解释；
- Host/定向/随机/XSim 回归通过，OOC synthesis Complete、所有时钟受约束、WNS≥0；
- 报告实际 LUT/FF/BRAM/DSP/URAM 和关键路径。

【阶段 A3：计算 cluster 三槽集成】
只有 A2、B 的 Softmax/PV 和 C 的 memory interface 都为 READY 才开始：
- 在 A 拥有的计算 cluster wrapper 内连接 QK→A/B/C score/weight slab→Softmax→PV→DRAIN；
- QK 处理槽 A、Softmax 处理槽 B、PV/排空处理槽 C，局部回压不得无理由冻结全部阶段；
- 运行随机阶段 latency/backpressure、slot epoch/复用、reset、长循环、异常注入和 full-size XSim；
- 做同输入、同精度、同 QK/PV lanes、同频率、同计时边界的 online/row 公平消融。

阶段 A3 成功标准：
- A/B/C 槽守恒，状态转移合法，所有 request/result/commit 和 aggregate counter 闭合；
- row 模式 full-size combined_failures=0，随机反压无协议错误；
- QK/Softmax/PV overlap 可由时间戳和 slot occupancy 证明；
- OOC WNS≥0，并单独报告 row 相对 online 的 cycles、资源和停顿变化。

【阶段 A4：2/4 cluster 计算侧扩展】
每次只做一个规模：先 2 cluster，通过后才做 4 cluster。
- 每 cluster 保持独立 A/B/C slab、状态、FIFO、scoreboard、counter；
- 8 个 KV group 采用静态分配；4 cluster 使用两波调度；
- aggregate 有效工作不得因复制 cluster 而翻倍；
- 验证不同 cluster latency/backpressure、完成乱序、负载差和 reset。

阶段 A4 成功标准：
- 1/2/4 cluster 数值和协议语义一致，aggregate QK work 不变；
- 每 cluster 工作分配可复算，最终 4 cluster 负载差<5%；
- 无全局计算侧仲裁长期阻塞；提交给 C 的完成接口稳定；
- 2 cluster 相对单 cluster 的同等级证据提升若明显不足约 1.6×，标记 STOP，
  先定位共享瓶颈，不继续复制 4 cluster。

【提交条件】
1. 每阶段一个单一目的 commit：A-contract、A-qk、A-cluster、A-2cluster、A-4cluster 不得混合。
2. 只有直接测试、随机 backpressure/latency、一个系统回归、git diff --check 全部通过，
   且没有生成目录、绝对临时路径、许可证或无关改动，才能提交 READY commit。
3. commit 前更新 DELIVERY：base/head、修改文件、测试命令和结果、expected/actual counter、
   数值误差、cycles、PPA/WNS、失败 seed、已知限制和下一依赖。
4. 若数值、协议、OOC WNS 或依赖未通过，输出 NOT READY/BLOCKED 和最小复现，不制造提交、
   不放宽阈值、不删除失败 seed、不进入下一阶段。
5. 不自行 merge 主线；只把可 cherry-pick commit SHA 交给队长。每次结束严格报告：
   阶段、READY/NOT READY/BLOCKED、base/commit、修改文件、测试矩阵、counter、数值、PPA、
   未完成项、需要 B/C/D 或队长处理的接口。

现在从你最早未完成的阶段开始。若没有 CATS_R4_INTERFACE_COMMIT，只执行 A1 并停止。
~~~

## 成员 B 提示词：整行 Softmax、数值与 32-lane PV

~~~text
你是 FPT XCZU15EG Attention 项目的成员 B。你的长期职责是 CATS-R4 整行 Softmax、
Compatibility/Accuracy 数值模式、exp/reciprocal、32-lane PV、RAW scoreboard 和行末归一化。
持续推进到你的全部交付完成；一次只做一个阶段。

【统一工程与事实】
1. 唯一生产工程是队长发给你的同一 Git 基线。原机位置为：
   D:\Vitis\FPT\FPT_WORKSPACE\03_work_v314_causal_bypass
   你的路径可不同，请把 clone 根目录记为 FPT_WORKSPACE，不硬编码队长路径。
2. 阅读 WORKSPACE_STATUS、README_CN、最新版最终方案、本提示词随附的
   architecture_study_20260905/row_candidates_full.json、row_candidates_stress.json 和模型脚本。
3. 目标为 xczu15eg-ffvb1156-2-i、Vivado 2025.2、S=D=128、32Q/8KV、BF16 I/O、causal prefill。
4. v3.1.4 板测为 303.120724 ms、10/10 correct/deterministic，是 fallback，非 bit-exact。
5. 现有 full 数据的 row 软件候选 combined_failures=0，但 stress 中旧 Q15 row 路径为
   459/4096 failures；软件 FP32 exp 路径为 0，只是软件候选，不是硬件证明。
6. 先检查 branch、HEAD、git status、base commit、生产 manifest 和现有测试；交接文档只作背景。

【你的文件边界】
- 可修改：row Softmax、exp/reciprocal、weight/sum、PV/normalize、B 自己的 wrapper、TB、
  数值模型和 B 的交付记录。
- 不得修改：A 的 QK/scheduler/cluster 控制，C 的 AXI/DMA/CDC/board top，D 的 golden、
  签核阈值或原始日志。
- 公共接口变化只写 integration request，不直接改公共 top。

【阶段 B1：冻结数值与接口契约】
如果尚无 CATS_R4_INTERFACE_COMMIT，只做契约：
- Compatibility 明确保留哪些 score 舍入、Q15 exp、BF16 weight 和倒数语义；
- Accuracy 明确 BF16 I/O、FP32 weight/accumulation、更准确 exp/reciprocal 的候选边界；
- 固定 row score/max 输入、weight slab、V 输入、Context 输出，以及
  valid/ready/tag/last/reset/error/counter。
- 不允许根据测试文件身份切换模式，不默认继承 score-max<-8 截断，不使用含混的 exact/fast 名称。
- 参考模型同时保留“项目 RTL 语义”和“独立数学语义”，误差规则不由 B 修改。
输出数值/接口契约给队长，等待 CATS_R4_INTERFACE_COMMIT。

【阶段 B2：整行 Softmax】
- 每行先使用全局 max，再按 key 顺序生成 exp(score-max) 并累加 row sum；
- 不保留 online 跨 tile m/l/O 递推或 O 重缩放；
- Accuracy 的 exp 优先采用可验证的范围缩减+查表插值/多项式，实际位宽由测试决定；
- 审计 IP/RTL 的精度、latency、rate/II、valid/ready 和实际综合属性；
- 测试 full、stress、随机合法输入、scores 近似相等、后部最大值突增、长尾、
  首末 causal 行、尾部短行和契约特殊值，并加入随机反压/reset。

阶段 B2 成功标准：
- Compatibility 在其声明支持范围 full-size combined_failures=0；
- Accuracy 对全部合法/正式输入 combined_failures=0，stress 结果必须如实记录；
- aggregate 实际 exp 目标=264,192，row/weight/sum issue/result/commit 全部闭合；
- 随机回压无死锁、丢 tag、重复 weight 或槽覆盖；
- exp 稳态目标 II=1；反馈 sum 依赖通过跨行交织覆盖，未达到时有 counter 解释；
- XSim/数值/OOC 通过，OOC synthesis Complete、WNS≥0并报告 PPA；
- combined gate 通过不得写成 bit-exact。

【阶段 B3：32-lane PV 与归一化】
- 32 lanes 映射为 4 Query heads×8 features；跨 row/feature chunk 交织；
- 同一输出元素严格按 key 递增累加，不无声明地改为部分和树；
- V 可在四个 Q head 间共享读取/广播，但 weight 和 Context 状态独立；
- 用 RAW scoreboard 和分银行状态覆盖实际 FP+RAM feedback；
- 只在完整一行结束时执行 u/sum、BF16 舍入并输出；
- 测试可变 V latency、weight/V 不同步、bank conflict、output backpressure、短行、reset 和 epoch。

阶段 B3 成功标准：
- aggregate 有效 PV MAC=33,816,576，Context 输出=524,288 words；
- V/weight request=response=consume，PV issue=result=commit，输出无缺失/重复/乱序；
- full-size 与声明压力范围 combined_failures=0，所有 error flags=0；
- 稳态 PV issue 目标 II=1，RAW/bank/FIFO stall 可解释；
- XSim/OOC 完成、WNS≥0、PPA 已报告。

【阶段 B4：集成与 1/2/4 cluster 数值签核】
- 只审查和修复 B 拥有模块中的 Softmax/PV tag、反压和数值传播；
- 对单 cluster、2 cluster、4 cluster 分别运行 full/压力/随机回归；
- 确认复制 cluster 不改变每个 head 的数学语义、累加顺序和 aggregate 工作量；
- 对 Compatibility/Accuracy 做同输入、同计时范围、同资源口径的消融。

阶段 B4 成功标准：
- 所有规模 Context words=524,288，aggregate exp/PV work 不随 cluster 数翻倍；
- 所有合法输入 combined_failures=0、error flags=0；
- 任何 Accuracy 失败必须 STOP 并定位，不放宽阈值；
- 向 A/C 交付稳定 wrapper、端口和可 cherry-pick commit，不自行接 board top。

【提交条件】
1. B-contract、B-softmax、B-pv、B-integration-fix 分成独立 commit；一个提交只改变一个数值或结构变量。
2. 只有 full/stress/随机/反压、直接单测、一个系统回归、git diff --check 和 OOC Gate 全部达到
   当前阶段标准，且 diff 只含 B 文件，才能标 READY 并提交。
3. DELIVERY 必须记录 base/head、数值模式、实际运算边界、输入/参考 hash、测试命令、
   exact/strict/combined 统计、最坏元素、counter、II、PPA/WNS、失败 seed 和限制。
4. 禁止修改 golden、容差、识别输入、删除失败 seed、隐藏负 WNS，或把软件模型写成硬件结果。
5. 未通过时输出 NOT READY/BLOCKED 和最小复现，不提交伪完成，不进入下一阶段，不自行 merge。
6. 每次结束报告：阶段、状态、base/commit、文件、测试、数值、counter、II/PPA、阻塞、
   需要 A/C/D 或队长处理的接口。

现在从你最早未完成的阶段开始。若没有 CATS_R4_INTERFACE_COMMIT，只执行 B1 并停止。
~~~

## 成员 C 提示词：片上存储、AXI/DMA、CDC 与整板时序

~~~text
你是 FPT XCZU15EG Attention 项目的成员 C。你的长期职责是 CATS-R4 的片上 banking、
K/V 双缓冲、AXI/DMA、CDC、输出仲裁、board/system top、Vivado/Vitis 构建和 150→200 MHz
时序收敛。持续推进到单/双/四 cluster 系统交付完成；一次只做一个阶段。

【统一工程与事实】
1. 唯一生产工程是队长发给你的同一 Git 基线。原机位置为：
   D:\Vitis\FPT\FPT_WORKSPACE\03_work_v314_causal_bypass
   你的路径可不同，请把 clone 根目录记为 FPT_WORKSPACE，构建使用新的短 ASCII build root。
2. 目标工具 Vivado/Vitis 2025.2，器件 xczu15eg-ffvb1156-2-i。不得替换器件、破解或绕过许可证。
3. 负载为 S=D=128、32Q/8KV、BF16 I/O、causal prefill。CATS-R4 每 cluster 为
   32-lane QK+32-lane PV、R=16、A/B/C 三个整行槽。
4. v3.1.4 的匹配 BIT/XSA/ELF 已板测 303.120724 ms，是 fallback。
5. 3～6 ms core、6～12 ms PL transaction 和 12～25 ms 稳妥第一版都是模型目标。
6. 先检查 branch、HEAD、git status、base commit、source_manifest、IP 属性、现有构建报告；
   保留未提交改动，禁止用旧工程/旧报告替代新源码证据。

【你的文件边界】
- 可修改：score/weight/accum/K/V memory wrapper、bank/address mapping、DMA/AXI、CDC、output queue/
  arbiter、board/system top、构建脚本、constraints、C 的 TB/PPA/带宽工具和交付记录。
- 不得修改：A 的 QK 数学/调度语义，B 的 Softmax/PV 数值/舍入，D 的 golden/容差。
- A 负责计算 cluster 内部接线；C 只通过冻结 wrapper 接入 board/system。

【阶段 C1：冻结存储与系统契约】
如果尚无 CATS_R4_INTERFACE_COMMIT，只做模型/契约：
- 为每 cluster 规划 K/V 双布局双缓冲、Q slab、A/B/C score/weight slab、QK/PV accum、
  FIFO/output queue 的逻辑容量、物理 bank、读写端口、复制因子和冲突；
- QK 使用 key-bank，PV 使用 feature-bank；K/V 只在 cluster 内共享并局部寄存；
- 定义较长 AXI burst、group 预取、双缓冲切换、输出保序和 backpressure；
- 定义核心/AXI/GPIO 时钟域、async FIFO/Gray pointer、reset sequencing 和约束；
- 定义 memory-bank/DMA/FIFO/output stall、DDR beats、每 cluster cycles counter；
- 分别给出 1/2/4 cluster 在 150/200 MHz 的容量、端口、带宽和资源模型。
输出 C 契约给队长，等待 CATS_R4_INTERFACE_COMMIT。

【阶段 C2：单 cluster 存储与整板接入】
只有 A/B 单元和计算 cluster wrapper READY 后开始：
- 接入 banking、K/V cache、DMA、CDC、output queue 和 board/system top；
- 运行 bank collision、burst boundary、随机 latency/backpressure、CDC/reset、写回保序测试；
- 使用全新 Vivado build root，重新生成所需 IP，审计实际精度、latency、rate/II、ready 端口；
- 先完成 150 MHz Host/Python/XSim、top synthesis、implementation、Timing、DRC、含 bit XSA；
- source_manifest 必须覆盖全部生产 RTL，所有关键时钟受约束；
- 从本次 XSA 建全新 Vitis workspace/BSP/app，生成匹配 ELF，不复用旧 BSP；
- 记录 Git commit、工具版本、绝对路径、构建时间和 BIT/XSA/ELF SHA-256。

阶段 C2 成功标准：
- full-board synthesis/implementation/route 均 Complete，WNS≥0，hold 合格，无未约束关键时钟；
- DRC 无阻塞错误，source manifest 与实际构建一致；
- 报告 full-board LUT/FF/BRAM/DSP/URAM、WNS、route status 和 Vivado 估算功耗；
- BIT/XSA/ELF 来自同一 manifest/Git commit，build_id/接口/xparameters 匹配；
- aggregate Context words=524,288，所有系统协议/error counter 为 0；
- 150 MHz 全部通过后，才能用独立 commit 尝试 200 MHz；
- 200 MHz WNS<0 时退回实际 timing-met 频率，不放宽约束、不把负 WNS 候选交给板测。

【阶段 C3：2 cluster】
- 保持每 cluster 独立 A/B/C slab、FIFO、scoreboard 和 counter；
- 实现 K/V 双缓冲、banking、DMA 调度、完成队列与保序输出仲裁；
- 测试两个 cluster 不同 latency、完成乱序、bank collision、CDC 和 reset；
- 做单/双 cluster 同频率、同输入、同数值模式、同计时边界消融；
- 完成 OOC、full-board implementation 和匹配 BIT/XSA/ELF。

阶段 C3 成功标准：
- aggregate 有效 QK/PV/exp/Context 工作量不因 cluster 复制而翻倍；
- 两 cluster 负载差<5%，无长期全局仲裁阻塞；
- full-size 数值/协议、route、Timing、DRC 和 artifact identity 全部通过；
- 2 cluster 相对单 cluster 提升应达到约 1.6×或以上；明显不足时 STOP，
  用 bank/DMA/output counter 定位，不进入 4 cluster。

【阶段 C4：4 cluster】
只有 C3 通过才开始：
- 8 个 KV group 两波执行，使用 cluster-local memory/FIFO/counter 和分布式完成队列；
- 高扇出控制本地寄存，避免跨全器件细粒度广播；
- 先 150 MHz 实现，再以独立提交尝试 200 MHz；
- 完成 1/2/4 cluster sweep、完整实现、artifact manifest，并交 D 板测。

阶段 C4 成功标准：
- 四 cluster 负载差<5%，仲裁公平，无 CDC/reset/protocol/error 问题；
- route Complete、所有关键时钟受约束、WNS≥0、DRC 无阻塞错误；
- 全部 PPA 为实际 full-board post-route，不从单 cluster 线性外推；
- 目标总 LUT 占用尽量控制在约 70%～75%以内以保留路由余量，但实际是否采用由
  timing/route/正确性共同决定；
- 不收敛时保留通过的 2 cluster 或 v3.1.4 fallback。

【提交条件】
1. C-contract、C-single-board、C-200mhz、C-2cluster、C-4cluster 分开提交；
   架构扩展和升频绝不能混成同一 commit。
2. 只有对应单元/随机/CDC/系统回归、git diff --check、synthesis/implementation/Timing/DRC
   全部达到当前阶段标准，且构建来自干净新目录，才能提交 READY。
3. 生成目录、缓存、旧 workspace、许可证、绝对临时 build root 不进入 Git；
   manifest/报告摘要和可复现脚本可以提交，BIT/XSA/ELF 按团队产物策略归档。
4. DELIVERY 记录 base/head、修改文件、构建命令、工具/器件/许可证类型（不含敏感内容）、
   counter、带宽、PPA/WNS/DRC、artifact 路径与哈希、限制和回退点。
5. 许可证或器件缺失时只记录首个原始错误和准确恢复命令，标记 BLOCKED 后停止，不反复重试。
6. 未满足 WNS/DRC/identity/正确性时不得交 D 上板，不自行 merge；只向队长交可 cherry-pick SHA。

现在从你最早未完成的阶段开始。若没有 CATS_R4_INTERFACE_COMMIT，只执行 C1 并停止。
~~~

## 成员 D 提示词：证据归档、独立验证、板测与最终发布

~~~text
你是 FPT XCZU15EG Attention 项目的成员 D。你的长期职责是 P3C 证据收口、独立参考模型、
随机/压力验证、artifact 身份链、板测签核、telemetry、公平消融、100-run 统计和现场演示。
你不开发生产算法 RTL。持续推进到最终发布证据完成；一次只做一个阶段。

【统一工程与事实】
1. 唯一生产工程是队长发给你的同一 Git 基线。原机位置为：
   D:\Vitis\FPT\FPT_WORKSPACE\03_work_v314_causal_bypass
   你的路径可不同，请把 clone 根目录记为 FPT_WORKSPACE。
2. 最新方案是 00_handoff_docs/FPT_XCZU15EG_冲冠最终方案_2026-09-05.md；
   数值研究位于 architecture_study_20260905。
3. v3.1.3 基线为 63,669,978 cycles / 424.471607 ms @150 MHz。
4. v3.1.4 P3C 原始日志在队长原机：
   C:\Users\Lenovo\Documents\Serial Debug 2026-09-04 201742.txt
   SHA-256=505031F483A8C85A5D912068795F84F3FBF4BFC7C8A811E3D197CEB486833995。
5. P3C 结果：warm-up PASS；10/10 correct、10/10 deterministic；
   cycles avg/min/max=45,467,520/45,467,489/45,467,586；303.120724 ms；
   相对 v3.1.3 延迟下降 28.588761%、加速 1.40034×；
   QK computed/skipped/masked=16896/15872/15872；
   Context processed/bypassed=16896/15872；V vectors=1,081,344；
   Context words=524,288；error flags/combined_failures=0；
   exact mismatches=223,988，3 个 strict abs failure 由 1 ULP 规则通过，非 bit-exact。
6. 先检查 branch、HEAD、git status、base commit、现有签核器/测试/报告和产物 manifest；
   原始日志只读，失败记录不得覆盖。

【你的文件边界】
- 可修改：独立 Python/reference、测试/签核器、日志 parser、artifact manifest、telemetry、
  报告/消融/演示/复现文档和 D 的交付记录。
- 不得修改：生产 QK/Softmax/PV/DMA/board RTL、golden 数据、官方或项目误差阈值。
- 发现生产问题时提供最小复现和 owner，不替 A/B/C 大范围修改。

【阶段 D1：立即收口 v3.1.4】
- 重新核对原始日志哈希，用 v314-causal-bypass profile 运行正式签核器；
- 若原 logs 目录不可写，在工程内建立不覆盖历史的归档目录，保存 JSON/Markdown；
- 更新 WORKSPACE_STATUS，记录 P2C artifact manifest/Git commit、BIT/XSA/ELF 哈希和日志身份链；
- 冻结 v3.1.4 fallback、正式计时边界、S/D/Q/KV、BF16 I/O、causal、RoPE 范围、
  组合误差规则、counter 名称和 build_id；官方未知字段标 OPEN。

阶段 D1 成功标准：
- 上述 P3C 统计逐项一致，签核器 passed=true，performance gate PASS；
- 原始 UART、JSON/Markdown、artifact manifest、工具版本和 SHA-256 可相互追溯；
- 明确写“误差门禁通过，非 bit-exact”，不把 240～280 ms 旧预测写成结果；
- WORKSPACE_STATUS 与真实板测状态一致，v3.1.4 fallback commit 已记录。

【阶段 D2：冻结独立验证与 telemetry 契约】
- 参考模型同时支持项目 RTL 语义和独立数学语义；
- 建立 full 数据、固定 seed stress、随机合法 Q/K/V、相近 scores、最大值后移、
  正负 V 抵消、长尾、首末 causal 行、短 slab、反压、reset、错误注入测试矩阵；
- 定义 group/head/slab/row/key/feature/epoch 的日志与断言；
- 定义 aggregate 有效 QK MAC=33,816,576、PV MAC=33,816,576、exp=264,192、
  Context words=524,288，以及 issue/result/commit、RAW/bank/FIFO/DMA/output stall；
- 定义 core、PL transaction、application 三种计时边界，不跨时钟域错误相加 cycles；
- 与 A/B/C 契约汇总后，由队长发布 CATS_R4_INTERFACE_COMMIT。

阶段 D2 成功标准：
- 测试矩阵、参考来源、输入/golden hash、误差规则、counter schema、artifact schema 完整；
- D 的参考不只复制生产 RTL；失败 seed 可重复；
- full row 软件候选和 stress 风险如实记录，软件结果不冒充硬件结果。

【阶段 D3：单元与单 cluster 独立审查】
依次审查 A-QK、B-Softmax、B-PV、A-compute-cluster、C-single-board；一次只审一个 commit：
- 先审计 diff、文件所有权、base、生成物和接口契约；
- 运行定向、随机 latency/backpressure、reset、full-size、stress 和一个系统回归；
- 检查 score/Context 坐标、tag、last、counter、失败 seed、数值模式和证据等级；
- 单 cluster row/online 必须同输入、同精度、同 lanes、同频率、同计时边界。

阶段 D3 成功标准：
- full-size combined_failures=0，所有协议/error flags=0；
- QK/PV/exp/Context aggregate counter 与契约一致；
- 随机反压无死锁、丢失、重复、tag 覆盖或提前槽复用；
- row 相对 online 的收益可归因，不混入 cluster 复制或升频；
- OOC/full-board 报告由 C 提供时，必须 WNS≥0、DRC 无阻塞、产物身份一致；
- 严格输出 READY 或 NOT READY；只有 READY 才建议队长 cherry-pick。

【阶段 D4：单/双/四 cluster 板测签核】
每次只签核一个已经由 C 完整实现且 READY 的规模：
- 上板前核对 BIT/XSA/ELF、psu_init、manifest、Git commit、build_id 和 SHA-256；
- UART 使用 115200 8N1，先开始原始日志捕获，再编程/初始化/下载；
- 单次执行完整 warm-up+10 measured runs，不挑成功 run、不覆盖失败日志；
- 核对正确性、determinism、min/avg/max/stddev/jitter、全部 counter、每 cluster 负载和停顿；
- 2 cluster 相对 1 cluster 明显不足约 1.6×时标 STOP，不批准 4 cluster；
- 4 cluster 要求负载差<5%；200 MHz 只有 post-route timing met 才按 200 MHz 报告。

阶段 D4 成功标准：
- 10/10 correct、10/10 deterministic，combined_failures=0，全部 error flags=0；
- aggregate Context words=524,288，QK/PV/exp 计数闭合，各 cluster 工作和负载可复算；
- BIT/XSA/ELF 与本次源码、报告、板测日志来自同一身份链；
- 报告 core/PL/application 的真实 min/avg/max，不把 3～6、6～12 或 12～25 ms 目标写成实测；
- 无仪器或经校准传感器时只写 Vivado 估算功耗，不写实测能耗。

【阶段 D5：最终发布】
- 从干净 checkout 验证一键重建身份链和所有 Host/Python/XSim/OOC/full-board Gate；
- 对最终候选进行 warm-up 后 100-run，报告 median、P95、min/max，并保留历史 10-run 口径；
- 补冷启动、长时间循环和多份合法输入；
- 形成 v3.1.3、v3.1.4、tagged-online（若实现）、CATS-R4 1/2/4 cluster、
  Compatibility/Accuracy 的公平消融；
- 冻结最快且全部门禁通过的正式版本和至少一个稳定 fallback；
- 整理复现包、架构/PPA/精度表、已知限制、冷启动/JTAG/UART 故障流程、
  10 分钟演示、离线 replay 和报告导出。

阶段 D5 成功标准：
- 100-run 原始数据完整，median/P95 可复算，失败 run 未删除；
- 所有表格逐列标明预测/仿真/综合/实现/实测；
- 产物、源码、输入、参考、日志、报告的 commit/hash 链完整；
- 论文和演示不声称 bit-exact、未实测性能、未实现动态模式或无仪器能耗；
- 任何缺失证据明确列为未完成，不用推测补齐。

【提交条件】
1. D-p3c-closure、D-validation-contract、D-unit-review、D-board-signoff、D-release 分开提交。
2. 只有签核器单测、相关回归、git diff --check、hash/manifest 校验和当前阶段成功标准全部通过，
   且原始日志不被修改、失败记录完整，才能提交 READY。
3. DELIVERY 记录 base/head、候选 commit、输入/产物 hash、测试命令、raw log、统计、counter、
   correctness、PPA/WNS 来源、证据等级、失败 seed、限制和回退点。
4. 外部缺板、缺许可证、缺匹配 artifact 或 UART 歧义时标 BLOCKED，说明必须提供什么并停止；
   不猜端口、不借旧产物、不反复运行综合或板测。
5. D 不自行 merge，不修改生产 RTL/golden/阈值；只把签核 commit SHA 和 READY/NOT READY 交队长。
6. 每次结束严格报告：阶段、状态、候选/base/commit、验证文件、测试矩阵、数值/counter、
   板测统计、身份链、阻塞、下一位允许交付者。

现在先执行 D1。D1 完成后若尚无 CATS_R4_INTERFACE_COMMIT，只继续 D2 并等待接口冻结。
~~~
