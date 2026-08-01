# v3.0 Online Softmax 与 Streaming Context 融合设计

## 1. 目标和边界

v3.0 的目标不是单独缩短指数计算，而是删除完整概率矩阵 P 的物化、缓存和重放。
每个 4×4 QK tile 到达后，硬件维护 Online Softmax 状态并立即把权重作用到 V：

```text
m_new = max(m_old, max(score_tile))
alpha = exp(m_old - m_new)
l_new = alpha*l_old + Σ exp(score-m_new)
O_new = alpha*O_old + Σ exp(score-m_new)*V
Context = O/l
```

这里 `m` 为 Q20 有符号定点、`l` 为 Q1.15 累积和、`O` 为 FP32 Context。
exp LUT、alpha 和 weight 的量化点与 RTL/Python Golden 对齐，最终 reciprocal 量化到
BF16 后再做 FP32 归一化乘法。

## 2. 数据流与存储

在线核一次只保留：

- 4×4 score tile：512 bit；
- 4 行的 `(m,l)` 与 4×4 Q15 weight；
- 当前 query-row tile 的 4×128 FP32 Context：16,384 bit；
- 16 个 FP32 Context PE 的工作寄存器，以及 16 个独立单写口 Context bank；后者避免把整个二维数组综合成多写口寄存器堆，并允许映射为分布式 RAM。

对比每个 GQA group 的完整 P（4×128×128×BF16）为 1,048,576 bit，在线持久
payload 约为 Context 16,384 bit + score 512 bit，不包含完整 P。P 的理论 payload
减少约 98.4%，并删除独立 P replay/PV hierarchy。该数字是架构 payload 对比，
不是综合后的 BRAM 报告；最终资源必须以许可证可用后的综合报告为准。

## 3. RTL 组成

- `rtl/core/online/online_softmax_context_tile.sv`：Online 状态、V 请求、归一化和输出。
- `rtl/core/online/online_context_bank.sv`：每个 Context lane 的独立单写口分布式 RAM bank。
- `rtl/core/online/online_context_pe.sv`：FP32 Context scale/MAC/norm PE。
- `rtl/core/online/attention_online_system_with_rope_top.sv`：RoPE、双 QK lane、V Cache、
  Online core 和多 GQA group 调度。
- `rtl/board/fpt_attention_board_engine.sv`：Legacy/Online generate 选择以及 DDR 接口。
- `rtl/board/attention_board_top.sv`：默认 `ONLINE_MODE=1` 和 GPIO profiling 页面。

## 4. 多组累计计数器

子核在每组启动时清零，所以系统顶层在 `online_done` 时累加每组计数，避免 8 组运行
结束只看到最后一组。GPIO 新增：

| Page | 含义 | S128/D128、8 GQA 预期 |
|---:|---|---:|
| 47 | Online tiles processed | 2,112 |
| 48 | Online tiles skipped | 1,984 |
| 49 | Context rescale events | 输入相关，必须非零 |
| 50 | V TILE4 vectors read | 270,336 |
| 51 | 有效 scalar MAC terms | 33,816,576 |

Page 40–46 的 v2.6 因果计数 ABI 保留；Online 模式下 page 43/44 映射为在线有效/跳过
scalar MAC，page 45 映射为 V TILE4 读取数。

## 5. 验证覆盖

### 单元 Golden

`tb/tb_v30_online_softmax_context.sv` 使用 S8/D8 数据，覆盖：

- causal mask 和完整因果 tile skip；
- 后续 tile 出现更大 max 的 Context rescale；
- V 请求随机等待/响应延迟；
- Context 输出随机 backpressure；
- 逐元素 BF16 Golden、坐标、last 和计数器检查。

### 端到端小系统

`tb/tb_v30_online_attention_system.sv` 覆盖：

- 两个 GQA group 的 RoPE prepare/cache；
- 双 QK lane 和 causal tile skip；
- V Cache load/read；
- Online Context 输出；
- 跨组计数器累计和 global/group last。

两套测试均已由 Vivado 2025.2 XSim 通过。

## 6. 尚未关闭的板级事项

- 本机缺少 XCZU15EG Synthesis license，完整综合/布局布线未执行。
- 需要 NumPy 生成全尺寸 v3.0 Online Golden，再更新 A53 header。
- 需要重新生成 bitstream/XSA/ELF 并在 RK-XCZU15EG-F 实板完成 1 次 warm-up、
  10 次测量、Context 误差、计数器、WNS、资源和功耗验收。
- 在这些事项完成前，版本状态只能是 `SIM_PASS / RTL_ELAB_PASS / BOARD_NOT_RUN`。
