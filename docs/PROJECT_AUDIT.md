# Project Audit

本审查基于当前仓库真实文件结构，范围是 `Llama3-8B-Attention-Optimize/`。当前结论：仓库已经具备 Golden 数据、CPU 性能基线、RoPE、Attention Mask、Softmax 的模块级雏形，但距离完整 Attention Pipeline 集成还缺少 QK、Scale、PV、Top、数据搬运和系统级验证。

> 更新：Mask/Softmax 默认 Golden 路径、RoPE 模块名与文件路径、CPU 依赖声明已修复。最新执行入口和剩余验证项以 `docs/REPRODUCIBILITY_GUIDE.md` 为准；下文保留的是修复前的审查快照。

## 1. 真实目录结构

```text
Llama3-8B-Attention-Optimize/
├── README.md
├── .gitignore
├── llama3_attention_golden_model.py
├── CPU_Baseline/
├── RoPE/
├── attention_mask_module/
├── golden_model_outputs/
└── softmax_module/
```

## 2. 文件分类

源码：

```text
llama3_attention_golden_model.py
CPU_Baseline/cpu_baseline/*.py
attention_mask_module/src/*.cpp, *.hpp
attention_mask_module/tools/*.py
softmax_module/rtl/*.sv
softmax_module/scripts/*.py
RoPE/*.v
```

测试代码：

```text
attention_mask_module/tb/*.cpp
softmax_module/tb/*.sv, *.svh
RoPE/tb_rope_qk_file.sv
CPU_Baseline/cpu_baseline/self_test.py
```

Golden 数据：

```text
golden_model_outputs/full/*.npy
golden_model_outputs/fpga_slice/*.npy
attention_mask_module/mask_test_vectors/*.hex
softmax_module/data/*.mem
RoPE/*_bf16_all.hex
RoPE/q_after_rope.hex
RoPE/k_after_rope.hex
```

运行结果：

```text
softmax_module/results/*.csv
RoPE/rope_compare_result.txt
CPU_Baseline/CPU_PERFORMANCE_RESULT.md
```

当前未发现已存在的 Vitis/Vivado 生成目录：

```text
.ide/
.metadata/
csim/
cosim/
build/
solution*/
__pycache__/
*.pyc
```

## 3. 关键发现

### 3.1 README 与真实状态不完全一致

根目录 `README.md` 写了完整 Attention Pipeline，并列出 QK、PV、Output Projection 等模块。但真实硬件目录目前只有：

```text
RoPE
attention_mask_module
softmax_module
```

没有看到独立硬件实现：

```text
qk_matmul
scale
pv_matmul
attention_top
AXI/DMA/DDR control
```

建议 README 改成“当前已完成模块 + 目标 pipeline”，避免评审误以为完整硬件 pipeline 已完成。

### 3.2 Golden Model 数据健康

`golden_model_outputs/fpga_slice` 关键 shape：

```text
q_before_rope       (4, 128, 128)
k_before_rope       (1, 128, 128)
q_after_rope        (4, 128, 128)
k_after_rope        (1, 128, 128)
v                   (1, 128, 128)
scores_before_mask  (4, 128, 128)
scores_after_mask   (4, 128, 128)
softmax_weights     (4, 128, 128)
attn_out_per_head   (4, 128, 128)
```

`scores_after_mask` 中 `-inf` 数量为 32512，等于 `4 * 128 * 127 / 2`，符合 causal mask。

### 3.3 Golden Model 脚本依赖本地权重路径

`llama3_attention_golden_model.py` 中：

```python
LOCAL_SAFETENSORS_DIR = "../llama3_weights"
```

这要求用户本地提前放置 Llama3 权重。当前仓库包含输出数据，所以验证可以不重新跑 Golden Model；但如果别人要复现 Golden 数据，需要 README 明确权重准备方式。

### 3.4 Attention Mask 模块较成熟

Mask HLS 模块满足主要约束：

```text
score_t = ap_uint<16>
max shape = [32, 128, 128]
layout = [q_head][q_token][k_token]
causal condition = k_token > q_token
core loop uses idx++
PIPELINE II=1
file testbench does逐元素比较
```

风险点：

```text
convert_mask_pair_to_hex.py 默认路径仍指向 repo_root/Golden_model/*.npy.npy
当前总仓库实际数据在 golden_model_outputs/fpga_slice/*.npy
attention_mask_module/README.md 仍提到 .npy.npy 旧命名
```

### 3.5 Softmax 模块有可用对拍结果，但路径不可复现

已验证：

```text
softmax_module/results/softmax_results.csv
Total outputs = 65536
Fail count = 0
Max abs error = 1.953125e-3
Tolerance = 0.0025
Overall = PASS
```

主要风险：

```text
softmax_module/tb/tb_file_paths.svh 使用 C:/Users/liuhe/... 绝对路径
softmax_module/data/golden_shape.txt 使用 /mnt/data/... 旧路径
scripts/prepare_softmax_golden.py 默认读取 softmax_module/golden_npy/，但当前没有该目录
```

这会导致队友换机器后 testbench 很可能不能直接运行。

### 3.6 RoPE 模块集成风险较高

发现：

```text
RoPE/rope_engine.v 定义 module rope_pair_engine
RoPE/rope_head_engine.v 实例化 rope_pair_engine
RoPE/tb_rope_qk_file.sv 实例化 rope_pair
```

`rope_pair` 在当前仓库中未找到对应 module 定义。testbench 还使用了：

```text
C:/Users/23858/Downloads/...
```

因此 RoPE 当前更像“已有 RTL 原型和结果文件”，但 testbench 可复现性不足，需先修路径和模块名。

### 3.7 CPU_Baseline 可运行，但当前总仓库副本不完整

`CPU_Baseline/cpu_baseline/self_test.py` 通过：

```text
ALL CPU BASELINE SELF TESTS PASSED
```

但当前总仓库中的 `CPU_Baseline/` 缺少之前单独目录里的：

```text
CPU_Baseline/README.md
CPU_Baseline/requirements.txt
```

建议补回，否则队友不知道如何运行 CPU benchmark。

### 3.8 仓库体积偏大

当前体积：

```text
golden_model_outputs 约 209MB
.git 约 145MB
```

如果比赛平台或 GitHub 限制仓库大小，建议只保留 `fpga_slice`，把 `full` 数据移到 release artifact 或网盘。

## 4. 不建议 Git 跟踪的内容

建议 `.gitignore` 继续覆盖：

```text
.ide/
.metadata/
.Xil/
csim/
cosim/
solution*/
build/
__pycache__/
*.pyc
*.jou
*.log
*.wdb
*.wcfg
.DS_Store
```

可考虑新增忽略：

```text
softmax_module/results/top_error_cases.csv
softmax_module/results/plots/
CPU_Baseline/results/
```

对于 `golden_model_outputs/full/`，是否提交需要团队决策。

## 5. 当前完成度判断

已较可靠：

```text
Golden fpga_slice 数据
CPU performance benchmark
Attention Mask HLS module
Softmax module offline golden comparison result
```

需要修复后才能稳定复现：

```text
RoPE testbench
Softmax file path configuration
Mask conversion script default path
README 与真实结构一致性
```

尚缺硬件模块：

```text
QK^T MatMul
Scale
P x V MatMul
GQA head scheduler / KV reuse
Attention Top
AXI/DMA/DDR system integration
System-level testbench
```
