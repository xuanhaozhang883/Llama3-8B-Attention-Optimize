# 四人最优化设计框架与分工（修订版）

## 1. 总目标与当前起点

当前可复算基线是 v3.1.3：`63,669,978 cycles / 424.471607 ms @150 MHz`。当前活动分支已完成 v3.1.4 causal consumer bypass 的 RTL、Host/Icarus、Python 数值模型和 Vivado XSim 验证，但 synthesis、implementation 和板测仍待许可证及板卡闭环。

后续不是简单增加 PE，而是依次解决四个问题：

1. 把 causal 无效工作从整条下游数据面删除；
2. 把 Context 的事务式等待改成 tagged/modulo-scheduled 流水；
3. 把 QK 内部的逐 MAC 等待改成连续发射和交织累加；
4. 单 cluster 达到高占用后，再用 banked memory 扩展到 2/4 cluster。

最终主线架构：

```text
DDR / AXI
   │
   ├─ Q/K/V 分块预取与 banked BRAM/URAM
   │
   ├─ GQA scheduler：8 groups → 4 clusters × 2 waves
   │
   ├─ Cluster 0..3
   │    ├─ RoPE
   │    ├─ tagged/interleaved QK
   │    ├─ local Score FIFO + causal metadata/bypass
   │    ├─ Online Softmax
   │    └─ FIT-Context：V request II=1 + feature-tag pipeline
   │
   ├─ 分布式完成队列 / Context 写回仲裁
   └─ profiler：issue/result/commit/stall/occupancy/cycles
```

## 2. 优化项目：为什么、怎么做、预计提升

下面的数字是相对同一 `424.47 ms` 基线的累计工程目标，不能把各行加速比继续相乘。除基线外均不是实测承诺。

| 阶段 | 为什么要做 | 主要实现方法 | 验收指标 | 累计性能目标 |
|---|---|---|---|---|
| O1：Causal consumer bypass | QK 已跳过上三角计算，但旧下游仍处理稠密 masked tile，浪费 Softmax、V 和 Context 周期 | 用 `all_masked && col_tile>row_tile` 在 consumer 入口旁路；对角 tile 保留逐元素 mask；修正 causal `row_last`；增加 counter/error | processed 16,896；bypass 15,872；V vectors 1,081,344；输出 524,288 | `240～280 ms`，约 `1.52～1.77×`；理想上限约 218.9 ms，不作承诺 |
| O2：FIT-Context | 现有 32 个 Context PE/128 DSP 数量够，但 FSM 逐次等待 V、乘法、加法，IP 的 II=1 没有转成系统吞吐 | 连续 V request；16 个 feature chunk 配 tag；乘法/product store/左结合加法/commit 解耦；所有 tag 按真实 valid/ready 推进 | V request II=1；feature II 先≤8、最终≤5；Context 3～5M cycles；结果顺序不变 | 整机 `70～120 ms`，约 `3.5～6.1×` |
| O3：QK continuous/interleaved | 小规模实测中 QK4→QK8 只快约 11.7%，说明瓶颈是共享请求、逐 MAC 等待和串行 scaler，不是 lane 数不够 | 多 tile/tag 交织；乘/加 issue-result-commit 解耦；增加 outstanding vector 请求；并行或流水 scaler；exact 模式保持逐 d 左结合顺序 | QK issue 空泡显著下降；QK/Context 吞吐差<20%；端到端结果过原误差门禁 | 目标 `≤70 ms`；规划区间约 `45～70 ms`，约 `6.1～9.4×`，高不确定性 |
| O4：2-cluster | 单 cluster 优化后，8 个 GQA group 的独立性可以转成并行；先用 2 cluster 验证存储和路由趋势 | 每 cluster 独立 FIFO/Context 状态；group 静态分配；Q/K/V 分 bank；避免全局大 mux | 负载差<5%；无长期全局仲裁阻塞；全板 WNS≥0 | `≤40 ms`，相对基线 `≥10.6×` 的设计目标 |
| O5：CATS-4 | 4 cluster 可用两波完成 8 个 group，比 8 cluster 更容易满足资源和时序 | 4 个本地 cluster、banked BRAM/URAM、分布式控制、Context 写回仲裁；计算域目标 200 MHz | 200 MHz timing met；10-run 正确确定；cluster 负载差<5% | `15～35 ms`，约 `12.1～28.3×`，冠军主目标 |
| O6：混合精度/250 MHz | vendor FP IP 在 4 cluster 下可能成为资源、功耗和 Fmax 限制 | 仅在 CATS-4 稳定后试自定义 BF16、块浮点/Kulisch、精度分层和更高频率 | 精度、功耗、时序、可复现性同时优于 O5 | `5～15 ms`，高风险冲刺；不作为当前正式主线 |

O1 已完成可用的非板卡验证，当前任务是补综合和实板闭环。O2、O3 可以在独立分支同时研究；正式主线先合 O2，确认 Context 不再主导后再合 O3。O4/O5 必须建立在高占用单 cluster 上，否则只是复制低效率。

## 3. 四人主要分工

### A：系统架构、因果协议与主线集成

主要负责“整条流水是否按同一个协议正确工作”。

- 收尾 O1：causal bypass、`row_last`、counter、protocol error、兼容开关和板级寄存器映射；
- 冻结模块间接口：坐标、head/group、valid/ready、clear/reset、last 和异常语义；
- 维护公共 top、board engine、生产 manifest、项目版本和合并分支；
- 为 B/C/D 定义 cluster 接口，不替他们改模块内部算法；
- 组织每次消融：baseline → O1 → O1+O2 → O1+O2+O3 → 2/4 cluster。

主要文件：`rtl/board/`、`rtl/core/online/*top.sv`、`scripts/source_manifest.tcl`、`project_config.json`。

个人验收：O1 全尺寸 counter 精确闭合；优化关闭时兼容基线；所有公共接口有 contract TB；每次合并能单独回退。

对应贡献：跨模块 causal-aware protocol。仅 O1 的目标是 240～280 ms；后续总性能由四人的模块共同决定。

### B：Online Softmax 与 FIT-Context 流水

主要负责把当前最大瓶颈从“有很多 PE 但一直等待”变成持续工作的流式 consumer。

- 先增加 Context 状态周期、V request/response、issue/result/commit、RAW stall 和 tag FIFO counter；
- 把 `REQ/RSP` 交替改成连续请求，做到 V request II=1；
- 设计 16-feature-tag 调度器、product store、partial accumulator 和 commit 队列；
- 保持每个 `(row, feature)` 跨 key tile 的依赖顺序，不跨 tile 重排；
- 将 O-state/product store 映射到规则的 banked LUTRAM/BRAM，避免大量 FF mux；
- 与 A 约定输入/输出接口，与 D 约定未来每 cluster 的本地 V bank。

主要文件：`rtl/core/online/flash_online_softmax_frontend.sv`、`flash_context_fusion_backend.sv`、`flash_context_update_pe.sv`、`rtl/core/bc/backend/`，以及对应 TB/Python 模型。

个人验收：Context consumer 3～5M cycles；V request II=1；feature-chunk II≤8 后冲 II=5；随机 V latency/backpressure 无丢失、重复或乱序；单 cluster 资源不超过 LUT 90k、FF 180k、BRAM36 140、DSP 450 的阶段预算。

对应贡献：FIT-Context tagged/modulo scheduling。合入 O1 后整机目标 70～120 ms。

### C：QK 连续流水、交织累加与数值模式

主要负责 O3，不继续用简单堆 QK lane 的方式换性能。

- 拆分 `WAIT_INPUT → SHIFT → ISSUE → WAIT_PE` 的全局等待，建立 tile/tag issue-result-commit 流水；
- 允许多个独立 row/tile 在 FP IP latency 内交织，但 exact 模式保持同一 score 的逐 d 左结合加法顺序；
- 改造共享 Q/K 请求通道，评估 2～4 outstanding 和局部 cache/bank；
- 将单共享 scaler 改成流水或多路服务，保持 score 输出坐标顺序；
- 建立 compatibility/exact 与 competition-fast 两种模式，fast 模式必须单独报告误差；
- 比较“tile interleave”和“D 维向量化”，以 cycles/DSP/WNS 决定，不预设 QK8。

主要文件：`rtl/core/bc/qk/`、QK/RoPE 数据面，以及对应 lane-equivalence、score-by-score 和随机回压 TB。

个人验收：QK/Context 吞吐差<20%；输出 score 坐标和数量完全一致；exact 模式通过既有数值门禁；每个方案给出 cycles、DSP、LUT、WNS 消融表。

对应贡献：dependency-aware QK interleaving。阶段目标是把整机推进到 ≤70 ms；具体收益必须等 O2 后的新瓶颈 counter 决定。

### D：多集群、存储系统、验证与 PPA 平台

主要负责把单 cluster 优化安全地扩展到 2/4 cluster，并提供全队统一的证据工具。

- 建立 1/2/4 cluster 参数化 wrapper 和 8 GQA group 的两波调度；
- 设计 Q/K/V banked BRAM/URAM、双缓冲、cluster-local FIFO 和 Context 写回仲裁；
- 先用带宽模型证明每个 cluster 的供数能力，再改 DDR/AXI，不做无收益的 DDR 优化；
- 维护一键 Host/XSim/OOC/top-level 回归、随机 latency/backpressure、counter closure 和日志签核；
- 汇总 utilization、WNS、route delay、功耗、10-run 延迟和 BIT/XSA/ELF SHA-256；
- 做 floorplan/CDC/reset sequencing，计算域 200 MHz，AXI/GPIO 可保留低频域。

主要文件：新建 `rtl/core/cluster/`、必要的 memory/arbiter 模块、`tests/`、`python/`、`vitis/`、实现/报告脚本。公共 board top 仍由 A 合入。

个人验收：2 cluster ≤40 ms；4 cluster 15～35 ms；cluster 周期差<5%；无全局仲裁长阻塞；4-cluster 预算上限 LUT 230k、FF 380k、DSP 2,400、BRAM36 480、URAM 64～96，且 WNS≥0。

对应贡献：CATS-4 multi-cluster + banked-memory architecture，以及全系统可复现证据链。

## 4. 实际协作顺序

### 第一阶段：现在即可并行

- A：冻结 O1，补全 synthesis/IP 属性/板测清单；许可证恢复后立即完成 Gate 2。
- B：在独立分支实现 Context profiler、连续 V request 和 FIT 调度器原型。
- C：先增加 QK issue/wait/scaler counter，完成 tile-interleave 与 D-vector 两个周期模型，再选择一个 RTL 原型。
- D：搭好统一回归矩阵、1/2/4 cluster 带宽模型、bank 地址规划和自动 PPA 汇总。

### 第二阶段：先合 O2，再合 O3

1. A+C/D 复核 O1 证据；
2. A 合入 B 的 FIT-Context，D 跑全套实现/报告；
3. 根据新 counter 判断 QK 是否成为主瓶颈；
4. A 合入 C 的 QK 方案，重新测单 cluster；
5. 单 cluster 达标后，D 先交付 2 cluster，再扩到 4 cluster。

### 第三阶段：竞赛收敛

- 正式版本优先选“正确、时序通过、10-run 稳定”的最低 Gate；
- CATS-4 达标后才能研究混合精度/250 MHz；
- 任一冲刺方案失败时，O1+O2+O3 或稳定的 2-cluster 版本必须能作为回退提交。

## 5. 所有人共同遵守的交付格式

每个人的优化提交都必须包含：设计假设与周期模型、RTL diff、定向 TB、随机 backpressure、full-size 数值回归、counter expected/actual、OOC 与 full-board PPA、匹配产物哈希、原始 UART 日志和与上一版的单变量消融。

每个人负责自己模块的单元测试；D 负责系统工具和汇总，不替其他人补缺失的模块验证。只有模型/仿真证据时标注“预测”或“仿真”，不能写成实板提升。
