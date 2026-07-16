# Integration Plan

目标是把当前模块从“分散的单模块验证”推进到“可复现的 Attention Pipeline 验证”。建议按阶段推进，不要直接上完整系统。

## Phase 0: 仓库可复现性整理（已完成代码与文档修复，待 Windows 工具链复跑）

目标：任何队友 clone 仓库后，能在自己的机器上复现已有结果。

任务：

```text
1. [x] 修正 README，使其区分当前已完成模块和目标模块。
2. [x] 补齐 CPU_Baseline/requirements.txt。
3. [x] 修复 Softmax tb_file_paths.svh 中的绝对路径。
4. [x] 修复 RoPE tb_rope_qk_file.sv 中的绝对路径和 module 名不一致，并新增文件对拍。
5. [x] 修复 attention_mask_module/tools 默认路径，指向 golden_model_outputs/fpga_slice/*.npy。
6. 决定 golden_model_outputs/full 是否留在 Git。
```

交付标准：

```text
CPU_Baseline self_test PASS
Mask conversion script PASS
Softmax analyze script PASS
RoPE testbench 可通过 `RoPE/run_rope_sim.tcl` 在独立 xsim 工作目录下运行
```

## Phase 1: 标准化数据转换工具

目标：所有模块使用同一套 shape/layout/dtype 约定。

建议新增：

```text
scripts/
├── convert_npy_to_bf16_hex.py
├── convert_scores_to_softmax_mem.py
├── check_tensor_shapes.py
└── compare_bf16_hex.py
```

统一支持：

```text
--input
--output
--shape
--layout
--dtype
```

交付标准：

```text
fpga_slice 所有关键 .npy 能一键转换为 RoPE/Mask/Softmax/PV 所需输入。
转换后有 meta.txt 记录 shape、layout、dtype。
```

## Phase 2: RoPE 模块复现与修正

目标：RoPE 成为可独立验证的标准模块。

已完成：

```text
testbench 已实例化 rope_pair_engine。
Q/K/sin/cos 输入、Q/K golden 输出都统一放在 RoPE/data/。
testbench 默认使用仓库相对路径，run_rope_sim.tcl 使用 plusargs 传入绝对路径。
```

建议路线：

```text
1. [x] 统一 module 名为 `rope_pair_engine`。
2. [x] 将 q/k/sin/cos 输入文件放到 `RoPE/data/`。
3. [x] 将输出文件写到 `RoPE/results/`。
4. [x] testbench 逐元素比较 q_after_rope/k_after_rope。
5. [x] 输出 PASS/FAIL、mismatch count、前 16 个错误样例。
```

交付标准：

```text
RoPE Q path PASS
RoPE K path PASS
无绝对路径
误差容限明确
```

## Phase 3: Attention Mask 保持模块验证

目标：保留当前 Mask IP 的模块级验证价值，同时为后续融合 Softmax 做准备。

当前状态较好：

```text
ap_uint<16>
idx++
II=1 设计意图
sanity testbench
file golden testbench
```

建议修复：

```text
1. convert script 默认路径改为 golden_model_outputs/fpga_slice。
2. README 去掉 .npy.npy 旧命名。
3. 增加 run_hls_sanity.tcl / run_hls_file_tb.tcl，如当前目录没有。
```

交付标准：

```text
C Simulation PASS
C Synthesis PASS
C/RTL Co-Simulation PASS
若无法在当前机器跑 Vitis，至少提供 Windows GUI/TCL 步骤。
```

## Phase 4: Softmax 可复现仿真（路径修复已完成，待 Windows xsim 复跑）

目标：Softmax testbench 能在任意机器从相对路径运行。

当前已有结果：

```text
Total outputs = 65536
Fail count = 0
Max abs error = 1.953125e-3
Tolerance = 0.0025
```

已完成路径修复：

```text
tb_file_paths.svh 已使用 softmax_module/... 仓库相对路径。
prepare_softmax_golden.py 默认读取 golden_model_outputs/fpga_slice。
```

建议路线：

```text
1. [x] tb_file_paths.svh 改为相对路径。
2. [x] prepare 脚本默认读取 golden_model_outputs/fpga_slice。
3. 保留 input_masks.mem，后续 Mask+Softmax 融合时直接使用 mask bit。
4. README 说明 softmax 输出误差容限。
```

交付标准：

```text
Vivado/xsim simulation PASS
results/softmax_results.csv 可重新生成
analyze_softmax_results.py 输出 Overall PASS
```

## Phase 5: 实现缺失硬件模块

优先级：

```text
1. QK^T + scale
2. P x V
3. GQA head scheduler / KV reuse
4. Attention Top
5. AXI/DMA/DDR integration
```

建议先做 `fpga_slice`：

```text
Q heads = 4
KV heads = 1
seq_len = 128
head_dim = 128
```

完整 32Q/8KV 先不要一次性上，等单 group pipeline 通了再扩展。

## Phase 6: 单 group Attention Pipeline

目标 pipeline：

```text
q_after_rope + k_after_rope
-> QK^T + scale
-> Mask
-> Softmax
-> P x V
-> attn_out_per_head
```

对拍目标：

```text
golden_model_outputs/fpga_slice/attn_out_per_head.npy
```

交付标准：

```text
每个模块单测 PASS
模块串联 testbench PASS
输出误差统计可接受
latency/resource 可统计
```

## Phase 7: 性能对比

CPU baseline 已有：

```text
CPU_Baseline/CPU_PERFORMANCE_RESULT.md
```

FPGA 后续应输出：

```text
latency cycles
clock period
latency ms
resource LUT/FF/BRAM/DSP/URAM
throughput GOPS
```

对比公式：

```text
speedup_vs_cpu = cpu_latency_ms_median / fpga_latency_ms
```

注意：CPU baseline 目前是性能参考，不是 Golden Model；正确性对拍仍以 `golden_model_outputs` 为准。
