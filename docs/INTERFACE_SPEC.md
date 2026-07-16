# Interface Spec

本文档定义当前模块之间应统一遵守的数据 shape、layout、dtype 和接口边界。后续所有 RTL/HLS testbench 建议以此为准。

## 1. 全局参数

```text
Model style      = Llama3-8B / Llama3-style GQA
q_heads          = 32
kv_heads         = 8
group_size       = 4
head_dim         = 128
current seq_len  = 128 for fpga_slice
data type        = BF16 raw word or float32 golden storage
```

Golden Model 的 `fpga_slice` 当前使用：

```text
q_heads = 4
kv_heads = 1
seq_len = 128
head_dim = 128
```

这是完整 GQA 中一个 KV group 的验证切片：4 个 Q head 共享 1 个 KV head。

## 2. 数据类型约定

Python `.npy`：

```text
dtype=float32
数值已按模块边界 round 到 BF16 精度
```

RTL/HLS 输入输出：

```text
BF16 raw 16-bit word
SystemVerilog: logic [15:0]
HLS: ap_uint<16>
```

Mask 特殊值：

```text
0xFF80 = BF16 -inf
0xCE6E = approximately BF16(-1e9)
```

当前 Golden 数据 `scores_after_mask.npy` 使用 `-inf`，所以 Mask/Softmax 对拍默认应使用 `0xFF80` 或单独 mask bit。

## 3. Golden fpga_slice 文件接口

```text
golden_model_outputs/fpga_slice/
├── q_before_rope.npy       shape=(4, 128, 128)
├── k_before_rope.npy       shape=(1, 128, 128)
├── q_after_rope.npy        shape=(4, 128, 128)
├── k_after_rope.npy        shape=(1, 128, 128)
├── v.npy                   shape=(1, 128, 128)
├── scores_before_mask.npy  shape=(4, 128, 128)
├── scores_after_mask.npy   shape=(4, 128, 128)
├── softmax_weights.npy     shape=(4, 128, 128)
└── attn_out_per_head.npy   shape=(4, 128, 128)
```

## 4. Layout 约定

### Q / K / V / RoPE / PV 输出

Q:

```text
q[q_head][token][dim]
shape = [q_heads, seq_len, head_dim]
```

K/V:

```text
k[kv_head][token][dim]
v[kv_head][token][dim]
shape = [kv_heads, seq_len, head_dim]
```

Flatten C-order：

```text
idx = (head * seq_len + token) * head_dim + dim
```

### Score / Mask / Softmax

```text
scores[q_head][q_token][k_token]
shape = [q_heads, seq_len, seq_len]
```

Flatten C-order：

```text
idx = (q_head * seq_len + q_token) * seq_len + k_token
```

## 5. GQA 映射

完整 Llama3-style GQA：

```text
kv_head = q_head // group_size
group_size = q_heads / kv_heads = 4
```

对于 `fpga_slice`：

```text
q_heads = 4
kv_heads = 1
group_size = 4
所有 q_head 0..3 都映射到 kv_head 0
```

## 6. 模块边界

### RoPE

输入：

```text
q_before_rope[q_head][token][dim]
k_before_rope[kv_head][token][dim]
sin[token][dim/2]
cos[token][dim/2]
```

输出：

```text
q_after_rope[q_head][token][dim]
k_after_rope[kv_head][token][dim]
```

当前验证实现：

```text
RoPE/tb_rope_qk_file.sv 使用 rope_pair_engine，默认读取 RoPE/data/ 下的仓库内向量。
运行 RoPE/tools/prepare_rope_vectors.py 可从 fpga_slice Golden 数据重新生成这些向量。
```

### QK^T + Scale

尚缺硬件模块。

输入：

```text
q_after_rope[q_head][q_token][dim]
k_after_rope[kv_head][k_token][dim]
```

映射：

```text
kv_head = q_head // group_size
```

输出：

```text
scores_before_mask[q_head][q_token][k_token]
```

公式：

```text
score = dot(q, k) / sqrt(head_dim)
```

### Attention Mask

HLS 顶层：

```cpp
void attention_mask(
    const ap_uint<16> raw_scores[AM_MAX_ELEMENTS],
    ap_uint<16> masked_scores[AM_MAX_ELEMENTS],
    int q_heads,
    int seq_len,
    bool causal,
    ap_uint<16> mask_value
);
```

规则：

```text
if causal and k_token > q_token:
    masked_scores = mask_value
else:
    masked_scores = raw_scores
```

当前 `fpga_slice` 文件对拍：

```text
q_heads = 4
seq_len = 128
mask_value = 0xFF80
```

### Softmax

RTL streaming row interface：

```text
input one row: scores[q_head][q_token][0:seq_len-1]
in_data  = BF16 score
in_mask  = 1 if masked
in_last  = final column of row
output   = BF16 probability
```

当前参数：

```text
NUM_HEADS = 4
NUM_ROWS  = 128
MAX_LEN   = 128
TOL_ABS   = 0.0025
```

当前 Softmax 使用单独 `input_masks.mem`，这比直接依赖 `0xFF80` 更安全。后续集成时建议 Mask 与 Softmax 融合，直接生成 `in_mask`。

### P x V

尚缺硬件模块。

输入：

```text
softmax_weights[q_head][q_token][k_token]
v[kv_head][k_token][dim]
```

映射：

```text
kv_head = q_head // group_size
```

输出：

```text
attn_out_per_head[q_head][q_token][dim]
```

## 7. 推荐统一文件格式

`.npy` 用于 Python Golden：

```text
float32 values, C-order
```

`.hex` / `.mem` 用于 RTL/HLS：

```text
one value per line
BF16 raw word: 4 uppercase/lowercase hex digits
mask bit: 0 or 1
```

建议后续所有转换脚本都支持：

```text
--input
--output
--shape
--format bf16_hex/fp32_hex/mask_bit
```

避免硬编码本机路径。
