# BF16 QK 分块脉动阵列（第一版）

## 设计选择

这套代码采用“全局可停顿的分块脉动阵列”。Q 数据水平传播，K 数据垂直传播，行/列 skew、wavefront 和 flush 都在 tile 内完成。每个 PE 内部继续使用已经验证通过的 FP32 Multiply + FP32 Add 路径，因此最容易保持和当前 Python/串行 RTL 黄金模型一致。

“最高性能”和“最少资源”不能同时达到。本工程把 `TILE` 参数暴露出来：

- `TILE=2`：4 个 PE，资源最少，优先用于第一次仿真和综合。
- `TILE=4`：16 个 PE，吞吐更高，是 KV260 上较平衡的比赛版本。
- 不建议一开始使用 `TILE=8`，因为会实例化 64 套 FP32 乘法/加法通路，综合资源和布线压力明显增加。

阵列只共享一个 scale 乘法器，避免每个 PE 都放一个 `1/sqrt(128)` 乘法器。

## 依赖的已有文件

不要删除或覆盖已经验证通过的文件：

- `bf16_to_fp32.v`
- `fp32_to_bf16.v`
- `fp32_mul_ip.v`
- `fp32_add_ip.v`
- `floating_point_0`：FP32 Multiply
- `floating_point_1`：FP32 Add
- `floating_point_2`：FP32 Multiply（scale）

新的 PE 会多次实例化 `fp32_mul_ip` 和 `fp32_add_ip`，Vivado 会生成多套硬件实例，这是正常的。

## 新增 RTL

- `qk_systolic_pe.sv`：单个 BF16 PE。
- `qk_result_scaler.sv`：共享 scale + BF16 转换。
- `qk_systolic_tile.sv`：参数化 TILE×TILE 脉动阵列。
- `qk_systolic_gqa_top.sv`：完整 head/row-tile/col-tile 调度器。

## 验证顺序

1. 先运行 `tb_qk_systolic_tile_2x2`，应得到 4 PASS / 0 FAIL。
2. 运行 `tb_qk_systolic_tile_4x4`，应得到 16 PASS / 0 FAIL。
3. 运行 `tb_qk_systolic_gqa_small`，应得到 16 PASS / 0 FAIL。
4. 运行 `tb_qk_systolic_gqa_4heads_seq4`，应得到 64 PASS / 0 FAIL。
5. 小矩阵通过后，再连接真实 BRAM/DDR loader。

## 顶层向量接口

`qk_systolic_gqa_top` 输出当前请求的：

- `req_head`
- `req_row_base`
- `req_col_base`
- `req_dim`

上游数据加载器应根据这些元数据提供：

- `q_vec_bf16[i] = Q[req_head][req_row_base+i][req_dim]`
- `k_vec_bf16[j] = K[req_col_base+j][req_dim]`

每次 `vec_valid && vec_ready` 传输一个 head-dimension beat。

## 重要说明

这是一个真正具有 PE 网格、A 水平传播、B 垂直传播、skew 和 wavefront 的脉动阵列。为了优先保证正确性，整个阵列在每次 FP32 MAC 期间会全局停顿。后续性能创新可以把 PE 改成 Floating-Point Accumulator/流水 FMA 结构，但必须重新与黄金模型验证舍入差异。
