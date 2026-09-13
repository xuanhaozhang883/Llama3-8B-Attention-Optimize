# CATS-R4 A3 单 Cluster 三槽计算集群设计

日期：2026-09-13

负责人：成员 A

设计状态：已确认，待实施计划

目标状态：A3 compute-unit/OOC READY

## 1. 背景与目标

A2 已提供 QK、BF16 score formatter、全局 row max、A→B 行交接、slot 生命周期及 abort/cancel 基础能力。成员 B 已在独立分支交付 B2 Softmax、B3 PV 和 B4 组合 wrapper；成员 C 的集成分支包含 memory、CDC、output 和系统侧候选模块，但尚未完成真实 A/B compute cluster 的生产集成。

A3 的目标是在成员 A 拥有的计算集群 wrapper 内，将现有真实模块组合为单 cluster、三槽重叠的数据通路：

```text
Q-slab client
    ↓
QK 32-lane engine
    ↓
A2 formatter / row max / handoff
    ↕
A-owned 3 × 128 × 16-bit BF16 score-slot memory
    ↓
B4 Softmax + PV wrapper
    ↓
C-owned weight / V / Context services

B4 final_release → A2 slot lifecycle
A-side (A2/QK) abort + B4 error → A3 buffered error channel
```

A3 完成只代表计算单元功能和 150 MHz OOC 门禁闭合，不代表 C2 整板、BIT/XSA/ELF、板测或系统性能已经 READY。

## 2. 已冻结决策

1. A3 以 `origin/codex/cats-r4-local-integration` 的 `f9419e8d30d13f5aeba6cfeb6dd1403028f79d43` 为基础，而不是直接在 `member-b-cats-r4-a2-integration` 上开发。
2. A3 开发分支为 `codex/a-cats-r4-a3-compute-cluster`。
3. 只选择性接收成员 B 的 B1/B2/B3/B4 提交，不整体合并已经分叉的成员 B 分支。
4. A3 新增真实的 A-owned score-slot memory；TB 中的软件数组或行为模型不能作为生产存储实现。
5. A3 不修改成员 B 的 Softmax/PV 数值内部，不修改成员 C 的 DMA、CDC、DDR、board top 或生产 manifest。
6. A3 采用分层验证；完整协议/数值模型 PASS 不得表述为完整 real-IP XSim PASS。
7. D 的独立性能复核不阻止 A3 compute-unit/OOC READY，但缺少 D 复核时不得发布系统级性能结论。

## 3. Git 基线与上游接收

### 3.1 基线

```text
base branch: origin/codex/cats-r4-local-integration
base commit: f9419e8d30d13f5aeba6cfeb6dd1403028f79d43
A3 branch:   codex/a-cats-r4-a3-compute-cluster
worktree:    C:\lhm\2_Work\Llama3-8B-Attention-Optimize-a3
interface tag: CATS_R4_INTERFACE_V3_COMMIT
tag object:    abe7492f5cd547d3128707b4b1405fcfca6909be
tagged commit: 4d386e0f8f39c9f3c6de5ffa2ced408f254146ee
```

### 3.2 计划接收的成员 B 提交

按以下顺序 cherry-pick：

1. `eb70525918b36573e0ec31a31459c0a3c0120b62` — B contract。
2. `a59a214711c3b3c9693662c892d011e5026c0419` — B2 Softmax。
3. `07a1c87239349ae7bfe986ad78694f88f1f6fe93` — B3 PV。
4. `18cdd2335bfa60927b1fbb466020561681f725eb` — B4 wrapper/integration fix。

不接收 `a26cdc5...`：集成基线已经包含对应的 A2 abort/cancel 修复 `d50ff78...`，重复接收会扩大冲突和审查范围。

合入上述提交后必须先运行 A2、B2、B3、B4 和 C 接口基线回归。基线失败必须独立记录，不能通过 A3 功能提交掩盖。

## 4. 所有权和边界

### 4.1 A3 内部拥有

- Q-slab client 到 QK engine 的计算侧组合。
- A2 score formatter、row max、A→B handoff 和 slot 生命周期接线。
- `3 × 128 × 16-bit` BF16 score-slot memory。
- A2/B4 之间的组合 wrapper、final release 回送和局部 backpressure。
- A-side（A2/QK）/B4 错误汇聚、计算侧 telemetry、A3 TB、断言、OOC 脚本和交付文档。

### 4.2 A3 外部依赖

- C 提供 Q/K/V 存储服务。
- C 提供 weight write/commit/read/release 服务。
- C 接收 Context 输出、统一错误/abort 和完成/计数信息。
- B4 保持成员 B 冻结的 Softmax/PV 数值语义和内部错误码。

### 4.3 非目标

- 不做 C2 board/system top 集成。
- 不生成 BIT、XSA 或 ELF，不声称板测通过。
- 不实现 2/4 cluster；它们属于 A4 及后续阶段。
- 不改变 CATS-R4 Interface V3 tag。
- 不以 A3 提交修复 B/C owner-domain 内部缺陷。

## 5. 数据通路和外部服务

A3 wrapper 的逻辑外部接口分为六组：

1. job/transaction 控制：启动、epoch、group、head/row 范围、numeric mode、完成与取消。
2. Q-slab 与 Q/K 服务：沿用已有 Q-slab client 和 QK engine 的请求/响应握手。
3. V 服务：由 B4/PV 通过 wrapper 访问 C-owned V memory service。
4. weight 服务：由 B4 Softmax 产生 weight write/commit，并由 PV 执行 read/release。
5. Context 输出：保持 token、feature/chunk、last、valid/ready 的原子性。
6. 控制与观测：统一错误/abort、slot ownership、完成状态和性能 counter。

实现阶段首先建立逐端口映射表，将 B4 的实际端口映射到 CATS-R4 Interface V3；如果实际端口与冻结接口不兼容，停止实现并生成 integration request，不在 A3 内静默改协议。

## 6. Score-slot memory

### 6.1 容量和寻址

- 三个物理 slot。
- 每个 slot 保存最多 128 个 BF16 score，共 `3 × 128 × 16 bit`。
- 地址由 `{slot_id[1:0], key[6:0]}` 唯一确定。
- 每个 slot 另保存 token、numeric mode、row max、有效 key 范围和 epoch 元数据。

### 6.2 写入规则

- 只有处于 `A_FILL` 且 token/epoch 与 owner 一致的 slot 可以接受 score write。
- score 必须已经经过 A2 BF16 RNE formatter。
- 合法 score 按 `key=0..row` 写入；缺失、重复、越界或乱序写入触发 A2/A3 协议错误。
- row max 必须覆盖该行全部合法 key，完成最后一个合法 score 后才能提交该行。
- `A_READY` 之前，B4 不得观察到该行有效。

### 6.3 读取和反压

- A→B score stream 严格按 `key=0..row` 递增。
- `last` 只在 `key=row` 上置位。
- memory response 和 A→B 输出均遵守 valid/ready；`valid=1 && ready=0` 时全部字段稳定。
- B4 backpressure 只阻塞相关读流和必要的局部依赖，不无理由冻结其他可运行 slot。

## 7. Slot 状态和所有权

每个 score slot 使用以下状态：

```text
FREE
  → A_FILL        A2 写入格式化后的 BF16 score
  → A_READY       score[0..row] 与 row_max 均已提交
  → B_PROCESSING  B4 已接受该行并执行 Softmax/PV
  → FINAL_RELEASE B4 完成且下游已接受结果
  → FREE          final_release 握手完成后允许复用
```

必须满足：

- `numeric_mode` 在一行开始时锁存，在该行 busy 期间不能改变。
- A2 完成整行 score 与 row max 后才把 slot 所有权交给 B4。
- B4 的 `final_release` 完成握手后，A2 才能释放和复用该 slot。
- 数据有效性与 owner 状态分别保存，不能仅凭 RAM 内容推断有效性。
- 三个 slot 可以同时处于 A_FILL、B_PROCESSING 和等待下游释放等不同阶段。
- 状态转移必须由真实握手驱动，不能依赖固定 latency。
- 对每个 token，allocate、row commit、B accept、final release 和 reuse 必须一一守恒。

## 8. Reset、epoch 和取消

- reset 清空所有有效位、owner 状态、pending 输出和错误缓冲；旧 RAM 内容无需物理清零，但必须不可见。
- epoch 改变或 clear/abort 时，旧 epoch token 立即逻辑失效；任何迟到 response 必须丢弃并计数。
- slot 只有在相关错误已被统一错误通道接受、迟到 response 不再可能污染当前 owner、取消状态完成后才能返回 FREE。
- reset/abort 后不得输出旧 token 的 score、row max、weight、Context 或 final release。
- 正常错误计数与负向用例的期望错误增量分开报告。
- QK engine 返回匹配 token 的 `done_error` 时，Q-slab client 必须停止发出后续 engine job、产生一个 A-side 错误事件并进入可恢复的 retire 路径；错误事件被接受前保持稳定，之后等待 clear/abort 开启新事务，不能永久停在 `ST_WAIT_DONE`。

## 9. 统一错误通道

A2 与 B4 的内部接口和内部错误码保持不变。QK/Q-slab 错误归为 A-side source；A2 row-abort 与 QK job-error 先在 A-owned 范围内汇聚，再与 B4 错误进入 A3 统一错误通道。A3 对 C 输出：

```text
valid/ready
source[1:0]       // 0=A-side (A2/QK), 1=B4
epoch[15:0]
group[2:0]
global_q_head[4:0]
row[6:0]
slot_id[1:0]
numeric_mode[1:0]
error_code[3:0]  // A-side 3-bit code zero-extended; B4 keeps 4 bits
bad_key[6:0]
```

错误汇聚要求：

- A-side 与 B4 各有独立的一项输入缓冲，避免同周期错误丢失。
- 如果同周期各接受一个错误，确定性顺序为先 A-side、后 B4；A-side 内部优先接受 QK job error，再接受 A2 row abort。
- 已进入输出的 payload 在 `valid=1 && ready=0` 时保持稳定。
- 不允许新错误覆盖尚未消费的错误；源端通过 ready 得到背压。
- 与 slot 取消/释放相关的错误必须先被统一错误通道接受。
- A3 只向 C 发出统一错误/abort 事件；全局 drain、DMA outstanding 和 board recovery 仍由 C 负责。
- A2 保留错误码 `1..3`；A3 为 QK engine job error 保留 A-side 3-bit 错误码 `7`。该错误携带失败 job 的第一个 row、对应 slot 和 key-block 起始 key，并要求事务级 clear/abort。

若实际 B4 可能在统一错误出口阻塞期间连续产生多条不可背压错误，实现前必须扩大缓冲深度或冻结可背压约束，不能假设一项缓冲天然足够。

## 10. Telemetry 和公平消融

A3 至少提供或记录：

- first issue 与 last commit 时间戳。
- 三个 slot 的 occupancy、owner 和状态驻留周期。
- QK issue/result/commit 与 stall。
- Softmax exp/weight/sum 进度与 stall。
- PV issue/result/commit 与 stall。
- score/weight/V memory stall。
- RAW、FIFO、output backpressure stall。
- row commit、Context commit、final release 和 epoch drop。

row/online 候选比较必须保持：相同输入、相同 numeric mode、相同 QK/PV lane 数、相同 150 MHz 约束和相同计时边界。成员 A 交付候选结果，成员 D 后续独立复核。在 D 复核之前只能报告 A3 内部测量，不发布系统性能结论。

## 11. 验证策略

### 11.1 完整工作量协议与计数器

完整 `32 heads × 128 rows` 工作量的目标值：

| 项目 | 目标 |
|---|---:|
| rows | 4,096 |
| causal scores / valid exp | 264,192 |
| weight writes | 524,288 |
| QK valid MAC | 33,816,576 |
| PV valid MAC | 33,816,576 |
| Context words | 524,288 |
| final releases | 4,096 |
| Q slabs | 256 |
| engine jobs | 6,144 |
| normal-path errors | 0 |

覆盖无 backpressure、随机 backpressure、首行、末行、reset、abort、epoch 切换和长循环。所有 request/result/commit/release counter 必须闭合。

### 11.2 数值验证

- 使用保存的 Q/K/RoPE 数据执行完整规模数值回归。
- 正式支持范围要求 `combined_failures=0`。
- 保留现有 Compatibility/Accuracy 完整 numeric gate。
- 对真实 A3 链路增加抽样端到端比较：QK → A2 → B4 → Context。
- 不把 Compatibility 的通过描述为 bit-exact。

### 11.3 real-IP XSim

代表性真实 RTL/XSim 至少覆盖：

- 多行连续运行和三个 slot 同时占用。
- 随机阶段 latency 与 backpressure。
- reset、abort、旧 epoch 丢弃和 slot 复用。
- 两种 numeric mode。
- A2/B4 同周期错误。
- 输出阻塞时 payload 稳定。

完整 4,096 行不强制全部经过 real-IP XSim。报告必须分别标注“完整协议/数值回归”和“代表性 real-IP XSim”，不得互相替代。

### 11.4 OOC

- 顶层为完整 `cats_r4_a3_compute_cluster`。
- 器件为 `xczu15eg-ffvb1156-2-i`。
- 工具为 Vivado 2025.2。
- 目标时钟 150 MHz，周期 6.666 ns。
- READY 要求 synthesis Complete、关键时钟受约束、`WNS >= 0`，并记录 LUT/FF/BRAM/DSP/URAM、关键路径和工具版本。

## 12. READY 判定

只有同时满足以下条件，才能标记 `A3 compute-unit/OOC READY`：

1. slot 状态、所有权、epoch 和复用断言全部通过。
2. request/result/commit/release 和 aggregate counter 全部守恒。
3. 正式数值回归 `combined_failures=0`，正常错误计数为零。
4. 代表性 real-IP XSim 通过，证据等级标注准确。
5. reset、abort、epoch、错误注入和随机反压测试通过。
6. 完整 A3 wrapper 在 150 MHz 下 `WNS >= 0`。
7. 测试命令、PASS/FAIL 日志、源码 SHA、输入哈希和 Vivado 版本均已保存。
8. DELIVERY 明确剩余 C2、D 复核、整板和板测工作，未将其写成已完成。

## 13. 缺陷处理原则

- 优先用 A-owned wrapper/adapter 修复接口组合问题。
- 如果怀疑 B/C 内部缺陷，先添加最小失败 TB、固定 seed 和复现日志。
- 需要修改 B/C owner-domain 时，将独立 issue/patch 交给对应成员；只接收其返回的独立 owner commit。
- 跨 owner 修复不得混入 A3 READY commit。
- 无法满足冻结接口、数值、协议或时序门禁时，状态应为 NOT READY/BLOCKED，不得放宽阈值或删除失败证据。

## 14. 计划提交结构

实施阶段按单一目的拆分：

```text
docs(a3): freeze compute-cluster contract
feat(a3): add three-slot score memory
feat(a3): join A2 and B4 error channels
feat(a3): connect compute cluster wrapper
test(a3): close protocol numeric and reset gates
test(a3): record XSim OOC and telemetry evidence
docs(a3): deliver compute-cluster readiness
```

计划新增的核心文件：

```text
rtl/core/bc/qk/cats_r4_qk_score_slot_mem.sv
rtl/core/bc/integration/cats_r4_a3_error_join.sv
rtl/core/bc/integration/cats_r4_a3_compute_cluster.sv
```

最终推送 `codex/a-cats-r4-a3-compute-cluster`，通过审查后向 `codex/cats-r4-local-integration` 提交合并请求。A3 不直接合并到 `main`。

## 15. 实施前检查点

正式编码前必须完成：

1. cherry-pick 四个指定 B 提交并保存结果 SHA。
2. 建立 B4 ↔ Interface V3 的逐端口映射。
3. 确认 B4 错误输出是否可背压以及最大突发数。
4. 确认 weight/V/Context 外部服务的 response latency 和 ready 语义。
5. 为 Q-slab client 的匹配 `engine_done_error` 增加失败测试，证明当前实现会停在 `ST_WAIT_DONE`，再实现错误事件、retire 和 clear 恢复。
6. 运行修改前基线回归并保存日志。
7. 依据本文生成逐任务、逐文件、逐测试的实施计划。
