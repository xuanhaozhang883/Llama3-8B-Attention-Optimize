# Priority TODO

本列表按“先让仓库可运行，再做新硬件模块”的顺序排列。

> 状态更新：原 P0 的路径/文档工作已完成，包括 RoPE testbench、Mask 默认 Golden 路径、Softmax 路径和 CPU 依赖。旧问题描述保留作历史记录；新机器执行请以 `docs/REPRODUCIBILITY_GUIDE.md` 为准。当前剩余的 P0 团队决策是 `golden_model_outputs/full/` 的存储策略，以及在 Windows Vitis/Vivado 机器上完成一次复跑。

## P0: 立即处理

### 1. 修复 Softmax 绝对路径

文件：

```text
softmax_module/tb/tb_file_paths.svh
```

当前问题：

```text
C:/Users/liuhe/Desktop/...
```

建议改为相对路径：

```text
softmax_module/data/input_scores_bf16.mem
softmax_module/data/input_masks.mem
softmax_module/data/expected_probs_bf16.mem
softmax_module/data/expected_probs_fp32.mem
softmax_module/results/softmax_results.csv
softmax_module/results/softmax_row_summary.csv
softmax_module/rtl/exp_lut_q15.mem
```

验收：

```text
换机器后 Vivado/xsim 能直接找到文件。
```

### 2. 修复 RoPE testbench 模块名和绝对路径

文件：

```text
RoPE/tb_rope_qk_file.sv
```

当前问题：

```text
实例化 rope_pair，但当前源码定义 rope_pair_engine。
使用 C:/Users/23858/Downloads/... 绝对路径。
```

验收：

```text
RoPE testbench 可编译。
输入输出文件使用相对路径。
能比较 q_after_rope/k_after_rope golden。
```

### 3. 修复 Mask 转换脚本默认路径

文件：

```text
attention_mask_module/tools/convert_mask_pair_to_hex.py
```

当前默认路径：

```text
repo_root/Golden_model/scores_before_mask.npy.npy
repo_root/Golden_model/scores_after_mask.npy.npy
```

总仓库实际路径：

```text
golden_model_outputs/fpga_slice/scores_before_mask.npy
golden_model_outputs/fpga_slice/scores_after_mask.npy
```

验收：

```text
python attention_mask_module/tools/convert_mask_pair_to_hex.py
```

无需额外参数即可生成 mask vectors。

### 4. 补齐 CPU_Baseline 文档和依赖文件

当前总仓库 `CPU_Baseline` 缺少：

```text
README.md
requirements.txt
```

验收：

```text
cd CPU_Baseline
pip install -r requirements.txt
python -m cpu_baseline.self_test
```

## P1: 本周内处理

### 5. 修正根 README

当前 README 把目标 pipeline 写得像已经完整实现。

建议改为：

```text
已完成:
- Python Golden Model
- CPU Baseline
- RoPE prototype
- Attention Mask HLS
- Softmax RTL + golden comparison

未完成:
- QK^T hardware
- Scale hardware
- P x V hardware
- Attention Top
- AXI/DMA integration
```

### 6. 决定 golden_model_outputs/full 是否进入 Git

当前：

```text
golden_model_outputs ≈ 209MB
.git ≈ 145MB
```

建议：

```text
保留 fpga_slice 用于模块验证。
full 数据可移到 release artifact / 网盘 / Git LFS。
```

### 7. 统一转换脚本

建议新增：

```text
scripts/convert_npy_to_bf16_hex.py
scripts/check_tensor_shapes.py
```

减少每个模块一套转换脚本造成的路径和 rounding 不一致。

## P2: 下一阶段开发

### 8. 实现 QK^T + scale

输入：

```text
q_after_rope: (4, 128, 128)
k_after_rope: (1, 128, 128)
```

输出：

```text
scores_before_mask: (4, 128, 128)
```

验收：

```text
与 golden_model_outputs/fpga_slice/scores_before_mask.npy 对拍。
```

### 9. 实现 P x V

输入：

```text
softmax_weights: (4, 128, 128)
v: (1, 128, 128)
```

输出：

```text
attn_out_per_head: (4, 128, 128)
```

验收：

```text
与 golden_model_outputs/fpga_slice/attn_out_per_head.npy 对拍。
```

### 10. 做单 group Attention Top

目标：

```text
QK -> Mask -> Softmax -> PV
```

先不接完整 32Q/8KV，先跑：

```text
4Q / 1KV / seq128 / head_dim128
```

验收：

```text
最终 attn_out_per_head 误差在容限内。
```

## P3: 性能优化

### 11. Mask 融合进 Softmax

当前独立 Mask IP 适合验证，但最终会多一次 score 读写。

优化方向：

```text
QK score streaming
-> if k_token > q_token, in_mask=1
-> Softmax
```

收益：

```text
减少 DDR traffic
减少 masked_scores materialization
降低 end-to-end latency
```

### 12. GQA KV reuse

完整 32Q/8KV 中，每 4 个 Q head 共享一个 KV head。

优化方向：

```text
一个 KV tile 被 4 个 Q head 复用
减少 K/V 重复读取
```

### 13. CPU vs FPGA 性能表

CPU baseline 使用：

```text
CPU_Baseline/CPU_PERFORMANCE_RESULT.md
```

FPGA 结果需要补：

```text
latency cycles
clock MHz
latency ms
LUT/FF/BRAM/DSP/URAM
GOPS
speedup_vs_cpu
```

## 当前推荐推进顺序

```text
1. 修路径和文档，让仓库可复现。
2. 修 RoPE testbench。
3. 固化 Mask/Softmax 一键验证。
4. 做 QK^T + scale。
5. 做 P x V。
6. 串单 group pipeline。
7. 扩展到 32Q/8KV。
8. 做性能优化和 FPGA vs CPU 对比。
```
