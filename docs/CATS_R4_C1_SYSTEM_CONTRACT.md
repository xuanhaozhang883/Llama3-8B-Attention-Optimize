# CATS-R4 C1 存储与系统契约提案（成员 C）

状态：`FROZEN / INTERFACE V1`

日期：2026-09-06

适用负载：`S=D=128`、`32Q/8KV`、BF16 I/O、causal prefill、每 cluster `32-lane QK + 32-lane PV`、`R=16`。

生效条件：Git annotated tag `CATS_R4_INTERFACE_COMMIT` 指向包含本文档与冻结声明的提交。该标记允许按 v1 wrapper 开展后续阶段，但不代表 A/B 单元 READY，也不代表 C2 可以越过自身入口门禁。

## 1. 基线审计与证据边界

- clone 根目录（`FPT_WORKSPACE`）：`D:/Vitis/FPT/FPT_WORKSPACE/03_work_v314_causal_bypass`。
- 当前分支/HEAD：`codex/v314-causal-bypass` / `e37948d1ac8d7b9c16708f5b5ce0013cd7dd7ab2`。
- 基准提交：本地 `main` 标签点 `c7f888b`（`workspace-v313-gate0`）；仓库无 remote，不能声称已与远端同步。
- 审计时工作区已有且必须保留的非 C1 改动：
  `docs/BOARD_BRINGUP_TUTORIAL_V314.md`、`docs/STEP_BY_STEP_PROMPTS_CN.md`，以及未跟踪的
  `docs/TEAM_4_COLLABORATION_PLAN.md`、`docs/WORKSPACE_CLEANUP_AUDIT_2026-09-05.md`。
- `scripts/source_manifest.tcl` 的生产入口仍为 `attention_board_top`，列出 32 个 RTL、3 个 memory 文件和 `scripts/attention_board.xdc`；C1 未改 manifest。
- 全仓搜索只找到提示词中对 `CATS_R4_INTERFACE_COMMIT` 的描述，没有真实冻结记录。因此本阶段只给模型与契约提案。
- 当前 PS/IP 事实：器件 `xczu15eg-ffvb1156-2-i`；PS `PL0=150 MHz` 且只有 PL0 enabled；数据面使用 `S_AXI_HP0_FPD`，现有自定义 master 为 32-bit address、64-bit data、1-bit ID、INCR burst，最多 256 beats（2 KiB）；控制面脚本启用 32-bit `M_AXI_HPM0_LPD`/AXI GPIO；IRQ 未启用；fabric reset 数为 1。
- 现有 full-board 报告来自 Vivado 2025.2、目标器件正确、routed、150.015 MHz，摘要为 LUT 66,866、FF 124,824、BRAM36 97、DSP 400、URAM 0、WNS 0.654 ns、WHS 0.010 ns。报告根记录为 `D:/Vitis/FPT/tmp/p2b_board_c1f41fe_01`。从 `c1f41fe` 到当前 HEAD，manifest 所覆盖的 RTL/memory/constraint/build-source 无路径 diff，但该报告仍只作为 v3.1.4 fallback 基线，不是 CATS-R4 新源码或 200 MHz 证据。
- 已知 fallback 是匹配的 v3.1.4 BIT/XSA/ELF，板测 303.120724 ms。C1 不重建、不替换、不重新解释该结果。

后续构建统一使用新的短 ASCII root，例如 `C:/fptb/cats_r4_c2_150_<sha>/`；绝不把生成工程放回 clone，也不复用 v3.1.4 的 XSA/BSP。

## 2. 冻结接口：cluster 工作集与所有权

调度单位为一个 GQA group：一个 KV head 对应连续 4 个 Q heads。静态分配为
`owner(group) = group_id mod CLUSTERS`；1/2/4 cluster 分别执行 8/4/2 个 group，4 cluster 是两波。K/V 不跨 cluster 共享、复制或广播；所有 K/V bank 读数据先在本 cluster 内寄存，再送计算 wrapper。

| 对象 | 每 cluster 逻辑容量 | 物理组织 | 端口/所有权 | 复制与冲突规则 |
|---|---:|---|---|---|
| K ping/pong | 2 × 128 × 128 × 16b = 64 KiB | 32 key banks；每 bank 1024×16 等价容量，约 1 RAMB18 | AXI 写 inactive buffer；core 每拍读 32×16b | `bank=k[4:0]`，`addr={buf,k[6:5],d[6:0]}`；无复制；active buffer 禁写 |
| V ping/pong | 2 × 128 × 128 × 16b = 64 KiB | 32 feature banks；每 bank 1024×16，约 1 RAMB18 | AXI 写 inactive buffer；PV 每拍读 32×16b | `bank=d[4:0]`，`addr={buf,d[6:5],k[6:0]}`；无复制；active buffer 禁写 |
| Q slab ping/pong | 2 × R × 128 × 16b = 8 KiB | 4 banks；每 bank 1024×16，约 1 RAMB18 | AXI 按 64b beat 写 inactive slab；QK 每拍读 1×16b 并广播 | `bank=d[1:0]`，`addr={buf,row[3:0],d[6:2]}`；slab 切换前禁止覆盖 |
| A/B/C 行槽 | 3 × 128 × 16b = 768 B | 三套独立的 32-bank LUTRAM/寄存器阵列 | 每槽每 bank 1R1W；slot token 交接 | `bank=k[4:0]`,`addr=k[6:5]`；三槽不可合并成两端口 RAM；有效周期不允许同址双写 |
| QK accum | R × 32 × FP32 = 2 KiB | 32 lane banks × 16 contexts | 每 lane 每拍 1R1W | `bank=lane`,`addr=context_tag`；同一 tag/lane 保持 A 定义的依赖顺序 |
| PV accum | R × 32 × FP32 = 2 KiB | 32 lane banks × 16 contexts | 每 lane 每拍 1R1W | `bank=lane`,`addr=context_tag`；数值/舍入完全由 B 冻结 |
| output payload queue | 32 rows × 128 × 16b = 8 KiB | async FIFO，64b×1024 beats，约 2 RAMB36 | core serializer 写，AXI writer 读 | 另设 row-tag FIFO；满时通过 ready 逐级回压，不丢弃 |
| metadata FIFO | 640 B 规划量 | cmd 16×128b、completion 16×64b、row-tag 32×64b、ownership token | Gray-pointer async FIFO 或单域 LUTRAM | descriptor 与 payload 的计数必须原子闭合 |

总逻辑容量是每 cluster 152,960 B（149.375 KiB）。规则 bank storage 为 36 BRAM36/cluster：K 16、V 16、Q 2、output 2；A/B/C、accum 和 metadata 合计 44,032 bit 采用分布式存储规划。基线方案不使用 URAM，保留 URAM 给实现后容量/布局调整，不以 URAM 换掉必需的 32 个独立读 bank。

K 的 DDR row-major beat 含同一 key 的 4 个相邻 feature，使用 BRAM mixed-width port（64b write/16b read）写一个 key bank；V/Q 的相邻 feature 分散到 4 个 feature bank。若器件 primitive/IP 实际不支持所需 mixed-width/dual-clock组合，C2 必须 STOP 并用显式 gearbox + 等价 bank 数重新综合，不能静默降低 32-lane 端口率。

A/B/C 的外部存储 payload 固定为 BF16 score 16 bit、opaque weight 16 bit，QK/PV accumulator 固定为 FP32 32 bit。本文只冻结容量、bank、位宽和握手；B 仍拥有 Softmax/PV 的数值解释、舍入和归一化语义。任何外部 payload 加宽都属于 interface v2，必须新建契约提交、重跑模型并发布新 tag，不能静默修改 v1。

## 3. AXI/DMA、预取和切换

第一版保留已验证的单个 64-bit HP0 数据口和 150 MHz AXI 域，不预先增加 HP 口。固定 burst 策略：

- 64-bit beat，`ARSIZE/AWSIZE=3`，INCR burst，正常 `ARLEN/AWLEN=255`，即 256 beats/2 KiB。
- 任一 burst 不跨 4 KiB 边界；descriptor 生成器取 `min(256, remaining_beats, beats_to_4KiB)`。
- Q/K/V/context 基址与每个 group 区段至少 2 KiB 对齐；短尾只允许发生在通用参数化路径，本固定负载没有短尾。
- 每个 group 顺序预取 K、V 和 Q slab 0；计算 active group 时填充另一 K/V buffer，并以 16-row 为单位交替预取 Q slab。
- DMA descriptor 带 `{epoch,cluster,group,kind,buffer,base,beats}`；数据完成只能产生一次 matching `buffer_ready` token。

K/V buffer 状态机为 `EMPTY -> FILLING -> READY -> ACTIVE -> EMPTY`。只有同时满足以下条件才允许原子切换：inactive K 和 V 的 tag/beat count 都完整；当前 group 的 4 个 Q head 全部结束；没有未返回的 K/V read；A/B/C 均已释放；该 group 的最后一个 output row 已进入本地输出队列。AXI 只写 `FILLING` buffer，core 只读 `ACTIVE` buffer。

固定负载的 DDR 流量（不含寄存器访问、cache line 和协议开销）：

| 项目 | Bytes | 64-bit beats | 256-beat bursts |
|---|---:|---:|---:|
| Q read | 1,048,576 | 131,072 | 512 |
| K read | 262,144 | 32,768 | 128 |
| V read | 262,144 | 32,768 | 128 |
| output write | 1,048,576 | 131,072 | 512 |
| 合计 | 2,621,440 | 327,680 | 1,280 |

每 GQA group 是 320 KiB、40,960 beats、160 个完整 burst；causal 只减少片上计算，不减少这版完整 Q/K/V/output 布局的 DDR bytes。64-bit × 150 MHz 理论峰值 1.2 GB/s；6/12 ms 事务目标分别要求 436.9/218.5 MB/s，即理论口利用率 36.4%/18.2%。因此 C2 先以长 burst、双缓冲和 stall counter 验证单 HP0；只有实测 AXI 成为瓶颈才提多 HP 方案。

## 4. 输出保序和 backpressure

全局 row sequence 为 `seq=(global_q_head * 128 + row)`，row 内 feature 0..127 固定递增。每 cluster 的 row-tag 为 `{epoch,seq,cluster,group,q_head,row}`；payload 必须恰好 32 个 64-bit beats，`row_last` 与第 32 beat 同步。

每 cluster 先按本地递增 seq 写 payload/tag FIFO。全局 commit arbiter 只接受 `tag.seq == expected_seq` 的队首；写响应成功后才推进 `expected_seq`。不同 cluster 完成可以乱序，但 DDR commit 不乱序。若期望 row 尚未就绪，记 `output_reorder_wait`；其他 cluster 队列可继续吸收，队列满后按 `output_ready` 回压到 PV、再通过 C/B/A slot token 回压到 QK。任何 valid payload/tag 在 ready=0 时必须保持稳定。AXI BRESP/RRESP 错误粘滞并停止发新 descriptor，不吞掉待提交 row。

仲裁不是用 round-robin 改变可见顺序；round-robin 只用于同一时刻的 DMA fill descriptor 或不影响 canonical commit 的后台请求。epoch 在 soft reset/restart 时递增，旧 epoch completion 必须丢弃并计错，不能写入新事务。

## 5. 时钟、CDC、reset 与约束

当前 v3.1.4 只有 PL0 150 MHz。CATS-R4 v1 冻结为三个物理/逻辑域，须在进入 C2 后重新生成 PS/BD 和全部 IP：

| 域 | 来源/频率 | 内容 | 跨域方式 |
|---|---|---|---|
| `axi_clk` | PS PL0，150 MHz | HP0 master、DMA descriptor、BRAM inactive 写口、DDR writer | 到 core 的 descriptor/token 用 async FIFO；K/V/Q 用双时钟 BRAM + ownership handshake |
| `core_clk` | PS PL1，先 150 MHz，独立提交再 200 MHz | 1/2/4 cluster、A/B/C、QK/PV accum、output serializer | output payload/tag async FIFO 到 AXI；禁止裸多位总线跨域 |
| `gpio_clk` | PS PL2，100 MHz | 32-bit AXI GPIO/mailbox、start/abort/status snapshot | cmd/status async FIFO；单 bit level 用 2/3-FF synchronizer；pulse 用 toggle/ack |

即使 `axi_clk` 和 150 MHz `core_clk` 同频，也按异步域处理，不依赖相位关系。async FIFO 指针使用 `ADDR_W+1` Gray code，经两级同步后比较 full/empty；pointer 每次只变一 bit。每条 Gray 总线增加不超过源周期的 datapath max-delay 和 bus-skew 约束。所有单 bit synchronizer 标 `ASYNC_REG`。禁止用宽泛 `set_false_path` 掩盖普通数据路径；只有已审计的 synchronizer/async FIFO crossing 可切断异步时序分析。

reset 采用异步置位、各域同步释放：

1. PS 上电/fabric reset 保持三域 local reset；等待对应时钟稳定。
2. 每域至少经过 2 级同步并保持不少于 16 个本域周期后释放 local reset。
3. GPIO `start` 只有在 AXI/core 的 `reset_done` 都返回后才可入队。
4. soft reset/abort 先阻止新 descriptor，等待或取消 AXI outstanding，随后清空两侧 FIFO pointer、slot token 和 buffer ownership；两侧 reset epoch 一致后才重新 ready。
5. core 200 MHz 尝试必须有独立 commit/新 build root；150 MHz 与 200 MHz 都要报告所有生成时钟、inter-clock paths、unconstrained paths、recovery/removal 和 FIFO CDC 检查。

## 6. Counter 契约

所有计数器为每事务清零、64-bit、在 owner domain 累加、完成后 snapshot；GPIO 读取 snapshot，不直接跨域读取活动二进制 counter。公共前缀为 `cN_`，shared DMA 为 `dma_`：

- cycles：`cycles_active`、`cycles_qk_busy`、`cycles_sm_busy`、`cycles_pv_busy`、`cycles_output_busy`、`cycles_no_work`。
- bank：`q_bank_conflict`、`k_bank_conflict`、`v_bank_conflict`、`score_bank_conflict`、`accum_bank_conflict`、`active_buffer_write_error`、`buffer_tag_error`。
- DMA/DDR：`rd_desc`、`wr_desc`、`rd_bursts`、`wr_bursts`、`rd_beats`、`wr_beats`、`ar_stall`、`r_stall`、`aw_stall`、`w_stall`、`b_stall`、`rresp_error`、`bresp_error`、`boundary_split`。
- FIFO：各 FIFO 的 `push/pop/max_occupancy/full_stall/empty_stall`，另有 `payload_tag_mismatch`、`underflow`、`overflow`。
- output：`rows_enqueued`、`rows_committed`、`output_reorder_wait`、`output_axi_wait`、`output_queue_full_stall`、`seq_error`、`epoch_drop`。
- workload：每 cluster `groups_done`、`q_heads_done`、`rows_done`、`qk_key_blocks`、`pv_key_steps`；shared aggregate 必须等于 cluster 求和，不能因复制 cluster 增加有效工作量。

正确性门禁：所有 conflict/protocol/error/underflow/overflow/seq counter 为 0；总 `rd_beats=196,608`、`wr_beats=131,072`、`rows_committed=4,096`；1/2/4 cluster 的 aggregate QK/PV 有效工作量保持不变。

## 7. 1/2/4 cluster 容量、端口、带宽和周期模型

| Clusters | groups/Q heads 每 cluster | 片上逻辑容量合计 | C-owned 规则 BRAM36（local/shared） | 64-bit DDR beats 每 cluster R/W/total |
|---:|---:|---:|---:|---:|
| 1 | 8 / 32 | 149.375 KiB | 36 / 38 | 196,608 / 131,072 / 327,680 |
| 2 | 4 / 16 | 298.750 KiB | 72 / 74 | 98,304 / 65,536 / 163,840 |
| 4 | 2 / 8 | 597.500 KiB | 144 / 146 | 49,152 / 32,768 / 81,920 |

每 cluster 的 K 与 V 读端口均是 32×16b=64 B/core-cycle；QK 和 PV 可同时使用各自独立 memory，故两者合计本地读峰值为 128 B/core-cycle。单 cluster 在 150/200 MHz 的 K 峰值分别为 9.6/12.8 GB/s，V 相同；aggregate 随 cluster 数线性增加，但 DDR bytes 不增加。

causal 理想发射下限（不含 Softmax、FP latency fill/drain、slot 切换、DDR/输出/回压 stall）：

| Clusters | QK cycles/cluster | PV cycles/cluster | 150 MHz core floor | 200 MHz core floor |
|---:|---:|---:|---:|---:|
| 1 | 1,310,720 | 1,056,768 | 8.738 ms | 6.554 ms |
| 2 | 655,360 | 528,384 | 4.369 ms | 3.277 ms |
| 4 | 327,680 | 264,192 | 2.185 ms | 1.638 ms |

公式：每 Q head 的 QK 为 `sum(ceil((row+1)/32)*128)=40,960 cycles`；PV 为 `sum(4*(row+1))=33,024 cycles`；当 A/B/C 真正重叠时 core 下限取各阶段最大值。3–6 ms core、6–12 ms PL transaction、12–25 ms 稳妥第一版仍是模型目标，不是实测承诺。B 的完整 Softmax 周期、A 的 wrapper II 和实际 stall 必须在 interface commit 后代入。

C-owned banking/DMA/CDC/arbiter 的规划上限（不是综合结果）为 shared `4k LUT + 6k FF + 2 BRAM36`，每 cluster `3k LUT + 6k FF + 36 BRAM36`、0 DSP、0 URAM：

| Clusters | LUT ceiling | FF ceiling | BRAM36 | 器件占比 LUT/FF/BRAM36 |
|---:|---:|---:|---:|---:|
| 1 | 7,000 | 12,000 | 38 | 2.05% / 1.76% / 5.11% |
| 2 | 10,000 | 18,000 | 74 | 2.93% / 2.64% / 9.95% |
| 4 | 16,000 | 30,000 | 146 | 4.69% / 4.40% / 19.62% |

这些数字只覆盖 C 的基础设施，不能与计算 core 的资源混称 full-board PPA。4-cluster full-board 的团队采用门仍是 post-route 实测 LUT 尽量不超过约 230k、FF 380k、BRAM36 480、DSP 2,400，并保留路由余量；URAM 64–96 是可选规划区间，不是要求消耗。任何 1/2/4 cluster 的实际 PPA、WNS、功耗都必须来自对应新源码的 full-board route，禁止线性外推。

## 8. 队长冻结结论与后续入口门禁

1. QK memory service 固定每次返回 32 个 key 的 BF16 vector；PV memory service 固定每次返回 32 个 feature 的 BF16 vector。请求 II=1、有序响应、固定 2 个 `core_clk` 周期 latency；`context_tag` 为 4 bit，对应 R=16。
2. A/B/C 三槽外部 payload 固定为 16 bit；QK/PV accumulator 固定为 32-bit FP32。slot 的数值生成、舍入和依赖顺序分别仍归 A/B 所有，C 不改变其语义。
3. 三 FCLK 固定为 PL0=AXI 150 MHz、PL1=core 150 MHz 首版/200 MHz 独立候选、PL2=GPIO 100 MHz。IRQ v1 不启用，完成与错误由 mailbox/status snapshot 读取。
4. canonical output 固定为 `(global_q_head,row,feature)` 递增，DDR layout 与 v3.1.4 的 BF16 context layout一致；D 使用本文 expected beats/rows/counter closure，但容差仍归 D。
5. 精确信号、位宽、ready/valid、epoch、last、owner domain 和变更规则见 `docs/CATS_R4_INTERFACE_COMMIT.md`。C2 仍须等待 A/B wrapper READY；tag 只解除“接口未冻结”阻塞，不替代单元入口条件。

可复算模型：`python/cats_r4_c1_capacity_model.py`；运行后先做内置 invariant 检查再输出 JSON。配套测试验证 cluster 扩展不复制 DDR/QK/PV 有效工作。v1 冻结后本阶段停止，不进入 C2 RTL。
