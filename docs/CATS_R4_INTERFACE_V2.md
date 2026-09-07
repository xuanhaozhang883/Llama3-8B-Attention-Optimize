# CATS-R4 Interface v2：独立 Q-slab 生命周期

状态：`LOCAL FROZEN / PENDING TEAM AUDIT AND TAG`

接口版本常量：`CATS_R4_IF_V2 = 0x0002_0000`

本文件是 `CATS_R4_INTERFACE_COMMIT` v1 的最小 breaking-change
增量。v1 的数值格式、QK/PV 数学、bank mapping、两拍 memory response、
AXI 流量、输出顺序、时钟和 counter 口径全部保持不变。v2 只修复 v1 中
Q slab 与 K/V group buffer 共用 ownership、且缺少 A/C slab 交接信号的问题。
在本文件获得团队审计并发布独立 v2 tag 前，C2 不得接入 production manifest。

## 1. 不变项

- QK 的 32 lane 沿 key 维展开；K response 为 `32×BF16=512 bit`。
- 四个 Q head 顺序复用同一 32-lane QK 核心；Q response 保持 scalar BF16。
- Q request/response 仍为 `context_tag[3:0],d[6:0]`，固定 N+2 response、II=1。
- Q ping/pong 总容量仍为 `2×16×128×16 bit = 8 KiB`；不增加四倍复制。
- K/V ping/pong、A/B/C slot、FP32 accumulator、DDR 总 bytes/beats/bursts均不变。

## 2. 两套独立 buffer 生命周期

K/V buffer 以 GQA group 为生命周期：

`EMPTY -> FILLING -> READY -> ACTIVE -> EMPTY`

同一 half 的 K 与 V 必须全部完成才能产生一个 paired-ready token。一次 group
计算期间 K/V active selector 保持不变。

Q slab buffer 以 `{epoch,group,global_q_head,row_window}` 为生命周期：

`FREE -> FILLING -> READY -> ACTIVE -> RETIRING -> FREE`

`row_window=0..7`，`row_base=row_window<<4`。每个 group 的四个 Q head 顺序
执行，每个 head 使用八个 16-row window，因此恰好 32 slabs/group、全负载
256 slabs。Q 与 K/V 必须拥有独立的 state、fill selector 和 active selector；
K/V ACTIVE 不得阻止向 inactive Q half 预取下一 slab。

## 3. 新增 A/C wrapper channel

以下信号属于 `core_clk`，均遵守 v1 的 `valid && ready` 和 stall-stable 规则。
token 字段必须逐项匹配，不允许只比较 buffer bit。

| Channel | Direction | Payload | Transfer semantics |
|---|---|---|---|
| `q_slab_need` | A→C | `epoch[15:0],group[2:0],global_q_head[4:0],row_window[2:0]` | A 请求下一块 Q slab；每 token 只能接受一次 |
| `q_slab_ready` | C→A | need token + `buffer[0:0]` | DMA 512 beats 全部完成且 tag/epoch 匹配后发布；A 接受时原子切为 active Q half |
| `q_slab_retire` | A→C | ready token + `buffer[0:0]` | A 的最后一个 Q request 已发出；C 等待该 slab outstanding response 为 0 后接受并释放 half |

精确信号名：

```text
q_slab_need_valid / q_slab_need_ready
q_slab_need_epoch[15:0]
q_slab_need_group[2:0]
q_slab_need_global_q_head[4:0]
q_slab_need_row_window[2:0]

q_slab_ready_valid / q_slab_ready_ready
q_slab_ready_epoch[15:0]
q_slab_ready_group[2:0]
q_slab_ready_global_q_head[4:0]
q_slab_ready_row_window[2:0]
q_slab_ready_buffer

q_slab_retire_valid / q_slab_retire_ready
q_slab_retire_epoch[15:0]
q_slab_retire_group[2:0]
q_slab_retire_global_q_head[4:0]
q_slab_retire_row_window[2:0]
q_slab_retire_buffer
```

合法 token 必须满足：

```text
global_q_head[4:2] == group
row_window < 8
epoch == active transaction epoch
```

A 只有在 `q_slab_ready` transfer 后才能对该 slab 发 Q request；retire transfer
后不得再引用该 token。C 不得在 outstanding Q response 非零时接受 retire，
也不得覆盖 READY/ACTIVE/RETIRING half。任何 stale epoch、重复 need、提前
retire、token mismatch 或 active overwrite 都必须阻止状态转换并计错。

## 4. Q DMA descriptor 闭合

每个 slab 的 DDR 地址和固定传输量为：

```text
q_slab_addr = q_base
            + ((global_q_head * 128 + (row_window << 4)) * 128 * 2)
q_slab_bytes  = 4,096
q_slab_beats  = 512
q_slab_bursts = 2
```

每 group 的 Q 为 32 descriptors、16,384 beats、64 bursts、128 KiB。全负载
仍为 1 MiB、131,072 beats、512 bursts；v2 不改变 v1 的 DDR 总量。K/V
descriptor 仍分别为每 group 32 KiB，output 仍为每 group 128 KiB。

Q prefetch 可与当前 slab 计算及另一 group 的 K/V fill 重叠，但 shared HP0
descriptor arbiter 必须保证公平，并保留 `valid && !ready` payload 稳定。

## 5. 新增 counter 和验收

每 cluster 新增 64-bit counter：

- `q_slab_need`, `q_slab_fill`, `q_slab_ready`, `q_slab_activate`,
  `q_slab_retire`；
- `q_slab_refill_wait`, `q_slab_reuse_stall`, `q_slab_outstanding_max`；
- `q_slab_tag_error`, `q_slab_epoch_error`, `q_slab_overwrite_error`,
  `q_slab_early_retire_error`；
- `kv_paired_ready_error`，以及独立的 `q_buffer_reuse_stall`、
  `kv_buffer_reuse_stall`；
- DMA `q_slab_desc`, `q_slab_beats`, `q_slab_bursts`。

单 cluster full workload 的正确闭合为：256 个 need/fill/ready/activate/retire、
256 Q descriptors、131,072 Q beats、512 Q bursts，所有 slab/KV ownership error
为 0；aggregate DDR/QK/PV 工作量继续满足 v1 数值。

## 6. 进入 C2 的新门禁

A 的 READY wrapper 必须实现上述 need/ready/retire channel，并证明四个 Q head
顺序复用、每 group 32 slab exactly-once、retire 前 outstanding 为 0。C 的
memory/DMA wrapper 必须证明 Q/KV selector 独立、随机 latency/backpressure 下
不覆盖 active half。满足这些条件并发布单独的 v2 interface tag 后，C2 才可
修改 production manifest、board/system top 和 Vivado build。
