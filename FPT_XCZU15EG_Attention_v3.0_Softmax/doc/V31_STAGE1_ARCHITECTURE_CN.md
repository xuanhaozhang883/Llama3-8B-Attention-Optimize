# V3.1 FlashAttention Stage 1 架构说明

## 1. 最终目标

本项目最终要实现的不是“单独加一个 FIFO”，而是下面这条连续 Tile 流水：

```text
QK Tile
  -> 在线更新每行 m、l
  -> 立即生成当前 P Tile
  -> 立即执行 P Tile x V Tile
  -> 更新 Context 累加值 O
```

其中“矩阵乘法和 Softmax 做到一起”表示三段计算形成连续 Tile 流水，并通过双缓冲或 FIFO 重叠执行；不是把 QK、指数、除法和 PV 塞入同一个时钟周期。

完整架构完成后，不应保存和重读完整的 `Score[SEQ_LEN][SEQ_LEN]` 或 `P[SEQ_LEN][SEQ_LEN]`。片上只保留当前工作 Tile、每行在线状态 `m/l`、Context 累加值 `O`，以及流水解耦所需的小容量缓冲。

## 2. 当前 Stage 1 做了什么

当前 v3.0 基线的数据路径是：

```text
QK 标量流
  -> Causal Mask
  -> score_rowtile_buffer
  -> softmax_bf16（仍保存并扫描整行 Score）
  -> softmax_output_buffer（仍保存 P）
  -> PV Backend
```

Stage 1 变为：

```text
QK 标量流
  -> 4x4 Complete Score Tile FIFO
  -> Causal Mask
  -> 原有 score_rowtile_buffer
  -> 原有 softmax_bf16
  -> 原有 softmax_output_buffer
  -> 原有 PV Backend
```

这一阶段只建立可靠的 Tile 事务边界。QK、Softmax 和 PV 的数学均不改变。

## 3. 为什么必须先做 Tile FIFO

### 3.1 保证 Tile 原子性

QK 当前每拍输出一个 BF16 Score。未来的 FlashAttention 核心必须以完整 `4x4` Tile 为计算单位。如果只收到了半个 Tile 就让下游开始，下游将无法可靠地区分“数据暂时停顿”和“Tile 已经结束”。

本 FIFO 只有在 16 个 Score 全部收到后，才把该 Tile 变成可读状态。因此 Partial Tile 永远不会进入下游。

### 3.2 建立标准反压

未来在线 `m/l`、指数近似、PV MAC 的吞吐不同。FIFO 通过 `valid/ready` 吸收短时速率波动；FIFO 满时，反压会沿 `score_ready` 精确返回 QK，数据不会丢失或覆盖。

### 3.3 为流水重叠提供边界

最终可以把 FIFO 的已提交 Tile 作为 Ping/Pong 工作项：

```text
时段 n:     QK 生成 Tile n+1
时段 n:     Online Softmax 处理 Tile n
时段 n:     PV 处理更早的 P Tile
```

FIFO 不是最终性能来源，但它让这些阶段可以独立停顿和并行调度。

## 4. FIFO 微架构

- Tile 大小：固定 `4x4`，每 Tile 16 个 Score。
- 默认深度：8 个 Tile。
- 存储内容：`BF16 Score + head + row + col + global_last`。
- 写入方式：每拍写一个窄标量存储单元。
- 提交方式：第 16 个标量成功握手后，Tile Occupancy 才增加。
- 读取方式：异步读分布式 RAM，逐标量重放给现有 Frontend。
- 连续性：FIFO 中还有下一 Tile 时，两个 Tile 之间没有结构性空拍。
- 非 2 次幂深度：指针显式回绕，深度 3 的测试已经覆盖。
- 同拍释放/接收：FIFO 满时，如果下游同拍取走旧 Tile 的最后一个标量，上游可以同拍接收新 Tile 的第一个标量。

在 Llama3 当前参数下，单个元素约为 33 bit：

```text
16 Score + 2 head + 7 row + 7 col + 1 last = 33 bit
```

默认深度 8 的原始存储量约为：

```text
8 Tile x 16 item/Tile x 33 bit = 4224 bit
```

综合工具会决定最终 LUTRAM/寄存器实现和资源数，必须以 Vivado 2024.2 报告为准。

## 5. 协议保护

FIFO 检查每个 Tile 是否满足：

1. 第一个元素的 `row` 和 `col` 都按 4 对齐。
2. Tile 内 `head` 不变。
3. 坐标严格按本地 Row-Major 顺序前进：`(0,0)` 到 `(3,3)`。
4. `global_last` 不能出现在 Tile 的前 15 个元素中。
5. Occupancy 不能上溢或下溢。

集成层在每个 GQA group 的最终概率被接受时，再检查：

```text
FIFO busy == 0
tiles_enqueued == tiles_dequeued
```

任何失败都会并入现有 `adapter_protocol_error`，因此上层错误通路不需要增加端口。

## 6. 本阶段不做什么

Stage 1 暂时不删除：

- `score_rowtile_buffer`
- `softmax_bf16` 内的整行 `score_mem`
- `softmax_output_buffer`
- 现有 PV Tile Buffer

所以本阶段不是完整 FlashAttention，预期也不会立刻产生大幅端到端加速。它可能增加少量启动延迟和 LUTRAM，却为后面的融合提供稳定边界。

## 7. 后续阶段

### Stage 2：Tile 在线统计核心

输入 Score Tile，按行维护在线状态：

```text
m_new = max(m_old, max(score_tile_row))
l_new = l_old * exp(m_old - m_new)
        + sum(exp(score_tile_row - m_new))
```

同时产生当前 Tile 的未归一化权重和重缩放因子。

### Stage 3：P Tile 与 V Tile 同步

当前权重 Tile 生成后立即请求对应 V Tile，不写完整 P Matrix；建立 `P Tile -> PV MAC` 的 Ready/Valid 边界。

### Stage 4：在线更新 O

维护每行 Context 累加值：

```text
O_new = O_old * exp(m_old - m_new) + P_tile x V_tile
```

序列全部 K/V Tile 完成后，再执行最终归一化 `O/l` 并输出 BF16 Context。

### Stage 5：双缓冲和性能收口

让 QK、在线统计、PV 三段真正重叠，并用计数器量化：

- QK 因 FIFO 满而停顿的周期。
- 在线核心因 P/V 不匹配而停顿的周期。
- PV MAC 利用率。
- 每组总周期、8 组总周期。
- LUT/FF/BRAM/URAM/DSP 和 WNS。

只有完成 Stage 2 至 Stage 5，才是项目定义下的完整 FlashAttention 数据流。
