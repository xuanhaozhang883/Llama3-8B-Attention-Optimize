# CATS-R4 Interface Commit v1

状态：`FROZEN`

冻结标记：Git annotated tag `CATS_R4_INTERFACE_COMMIT`

目标：Vivado/Vitis 2025.2，`xczu15eg-ffvb1156-2-i`

负载：S=D=128、32Q/8KV、BF16 I/O、causal prefill、R=16、每 cluster 32-lane QK + 32-lane PV。

此文件与 `docs/CATS_R4_C1_SYSTEM_CONTRACT.md`、容量模型及测试位于同一 Git 提交。Git tag 是机器可检查的正式冻结标记；仅存在同名文本不算冻结。

## 1. 版本与修改规则

接口版本为 `CATS_R4_IF_V1`，数值编码建议为 32-bit 常量 `0x0001_0000`。以下内容属于 breaking interface，禁止在 v1 中静默修改：clock owner、端口方向/位宽、memory read latency/II、tag/epoch/last 含义、bank mapping、output 顺序、DDR beat/burst 口径和 counter 清零/快照语义。

breaking change 必须：新增 v2 文档；更新容量模型和测试；单独提交；发布不同 tag；由 A/B/C/D 重跑契约测试。实现可以增加内部 pipeline，但不能改变 v1 可见 latency、顺序或 ready/valid 行为。

## 2. 通用握手规则

- 所有 channel 使用 `valid && ready` 完成一次 transfer。
- producer 在 `valid=1 && ready=0` 时保持 payload、tag、last、error 和 epoch 全部稳定。
- transfer 不允许被重复、合并或丢弃；reset/abort 的旧 epoch completion 除外，但必须增加 `epoch_drop`。
- request/response 在各自 channel 内有序；不同 cluster 可以乱序完成。
- `epoch[15:0]` 每次 start/restart 递增；`cluster_id[1:0]`；`group_id[2:0]`；`context_tag[3:0]`；`row[6:0]`；`d[6:0]`；`global_q_head[4:0]`；`seq[11:0]`。
- 所有计数器为 64 bit。活动计数器不直接跨域读取，完成后由 owner domain 原子 snapshot。

## 3. 冻结的 system-to-cluster command/status wrapper

这些信号位于 `core_clk` 域；GPIO command 先经过 async command FIFO：

| Signal | Direction | Width | Contract |
|---|---|---:|---|
| `cmd_valid/cmd_ready` | system→cluster | 1/1 | group command transfer |
| `cmd_epoch` | system→cluster | 16 | 当前事务 epoch |
| `cmd_cluster_id` | system→cluster | 2 | 必须等于实例 ID |
| `cmd_group_id` | system→cluster | 3 | 0..7；owner=`group_id mod CLUSTERS` |
| `cmd_q_head_base` | system→cluster | 5 | 固定为 `group_id*4` |
| `cmd_kv_buffer` | system→cluster | 1 | 只引用 READY buffer |
| `done_valid/done_ready` | cluster→system | 1/1 | group completion descriptor |
| `done_epoch/group/error` | cluster→system | 16/3/1 | error 为 sticky group error 汇总 |

group done 只能在 4 个 Q head、全部 512 output rows 均进入本地 output queue、A/B/C 释放且 K/V outstanding read 为 0 后发出。

## 4. 冻结的 cluster memory-service wrapper

所有 request/response 位于 `core_clk`。buffer READY 时 request II=1；一次被接受的读请求固定在第 2 个后续 `core_clk` 周期产生 response。response 不支持回压，因此 consumer 必须保证接收；wrapper 必须保持请求 tag 并原样返回。buffer 切换期间 `req_ready=0`。

| Service | Request payload | Response payload | Bank mapping |
|---|---|---|---|
| Q | `context_tag[3:0], d[6:0]` | `context_tag[3:0], q_bf16[15:0]` | 4 banks，`bank=d[1:0]` |
| K | `context_tag[3:0], key_block[1:0], d[6:0]` | `context_tag[3:0], k_vec[511:0]` | 32 key banks，lane i=`k=32*key_block+i` |
| V | `context_tag[3:0], key[6:0], feature_block[1:0]` | `context_tag[3:0], v_vec[511:0]` | 32 feature banks，lane i=`d=32*feature_block+i` |

Q/K/V 数据均为 BF16 raw bits。C 不解释 NaN、舍入或数学语义。K/V response 在 wrapper 边界寄存，禁止把 32-bank combinational read/fanout 带出 cluster。K/V 只允许本 cluster 消费；没有跨 cluster K/V mux 或广播端口。

## 5. 冻结的 A/B/C slot 与 accumulator service

- A/B/C 为三个彼此独立的完整 128-element row slot；每 element 16 bit；每槽 32 banks、每 bank 1R1W。
- slot ownership token 为 `{epoch[15:0],global_q_head[4:0],row[6:0],kind[1:0]}`。只有 transfer token 的 owner 可以写槽；release transfer 后不得再访问。
- QK 和 PV accumulator 各有 R=16 contexts × 32 lanes × FP32 32 bit；`context_tag` 选择 context，lane 隐式选择 bank。
- C 只保证容量、端口、顺序和冲突检测。A 保持 QK 数学/调度依赖；B 保持 Softmax/PV 数值、归一化和舍入。
- 任意同周期同 bank 同址双写、active-buffer write 或非法 owner access 必须阻止 transfer 并增加 sticky error counter。

## 6. 冻结的 cluster-to-output wrapper

cluster 在 `core_clk` 域以 32-feature chunk 交付：

| Signal | Width | Contract |
|---|---:|---|
| `out_valid/out_ready` | 1/1 | 标准稳定握手 |
| `out_epoch` | 16 | 当前 epoch |
| `out_seq` | 12 | `global_q_head*128 + row` |
| `out_global_q_head` | 5 | 0..31 |
| `out_row` | 7 | 0..127 |
| `out_feature_block` | 2 | 0..3，严格递增 |
| `out_data_bf16` | 512 | 32 个 BF16，lane i 对应 `d=32*feature_block+i` |
| `out_row_last` | 1 | 仅 feature_block=3 时为 1 |
| `out_tensor_last` | 1 | 仅 q_head=31,row=127,feature_block=3 时为 1 |

C wrapper 将每个 512-bit chunk 串行化为 8 个 64-bit AXI-side beat；完整 row 为 32 beats。每 cluster output payload FIFO 为 64b×1024，row-tag FIFO 为 32 entries。全局 DDR commit 严格按 `(out_seq,feature_block,beat_in_chunk)` 递增；可乱序完成，不可乱序提交。

## 7. DMA/AXI 和固定流量

- 数据面：一个 64-bit `S_AXI_HP0_FPD` master，32-bit address、1-bit ID、150 MHz。
- INCR burst；正常 256 beats/2 KiB；任何 burst 不跨 4 KiB；descriptor 必须处理通用短尾。
- 固定负载：read 196,608 beats，write 131,072 beats，总 327,680 beats；read 768 bursts，write 512 bursts，总 1,280 bursts。
- 每 group：read 24,576 beats、write 16,384 beats，总 40,960 beats/160 bursts。
- output canonical DDR layout 为 BF16 `[q_head][row][feature]`，与 v3.1.4 context buffer layout 一致。
- AXI response error 后停止发新 descriptor，保留已排队数据和 sticky error，等待 host abort/reset。

## 8. 时钟、CDC 和 reset

- `axi_clk`：PL0=150 MHz；HP0/DMA/DDR writer 和 inactive buffer write port。
- `core_clk`：PL1=150 MHz 首版；200 MHz 是独立提交候选；cluster 和 active buffer read port。
- `gpio_clk`：PL2=100 MHz；HPM0_LPD/AXI GPIO/mailbox。v1 不启用 IRQ。
- 三域按异步关系约束，即使 150 MHz build 中 AXI/core 同频也不假设相位。
- 多 bit streaming 只用 async FIFO；K/V/Q 用 dual-clock BRAM + ownership handshake；single-bit level 用 2/3-FF；pulse 用 toggle/ack；Gray pointer 用两级同步、source-period max-delay 和 bus-skew。
- reset 异步置位、各域同步释放且不少于 16 个本域周期；只有三个 `reset_done` 完成后才接受 start。soft reset 先停止 descriptor，处理 outstanding，再清 FIFO/slot/buffer owner 并切换 epoch。

## 9. Counter 与验收闭合

counter 名称和 owner 以 `docs/CATS_R4_C1_SYSTEM_CONTRACT.md` 第 6 节为准。固定负载最低闭合：

- aggregate `rd_beats=196608`、`wr_beats=131072`、`rows_committed=4096`；
- aggregate QK floor work=1,310,720 key-bank cycles，PV floor work=1,056,768 feature-bank cycles；
- 1/2/4 cluster 扩展时 aggregate DDR/QK/PV 有效工作不变；
- 所有 bank conflict、active write、tag/seq/epoch、FIFO underflow/overflow 和 AXI response error 为 0；
- `sum(cluster groups_done)=8`，每 group 恰好 4 Q heads、512 rows。

## 10. 阶段边界

此冻结只完成 C1。C2 还必须同时具备：A/B 单元和计算 cluster wrapper READY；队长确认 C2 base/tag；使用新短 ASCII build root。C2 才允许加入 memory wrapper、DMA/CDC/output RTL 和修改 board/system top、manifest、BD、IP 与 constraints。150 MHz 全门禁通过后，200 MHz 必须独立提交；2/4 cluster 继续保持独立阶段。
