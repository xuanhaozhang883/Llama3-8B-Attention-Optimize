# BF16 PV 脉动矩阵乘法模块

## 1. 本工程完成什么

本工程实现一个 GQA 分组的 PV：

```text
Context[h] = P[h] × V

P       : [4, 128, 128]
V       : [1, 128, 128]
Context : [4, 128, 128]
```

这里 4 个 P head 共享同一个 V head。

PV 与 QK 的关键区别：

```text
QK: Q[row][d] × K[col][d]，最后还要乘 1/sqrt(128)
PV: P[row][k] × V[k][feature]，最后不做 scale
```

因此，本工程复用了 QK 中已经验证过的 BF16→FP32、FP32 乘法、
FP32 累加、4×4 skew/wavefront/PE 网格，但新增了 PV 专用读取方式、
矩阵调度器和“只做 FP32→BF16”的结果转换器。

## 2. 目录

```text
PV_systolic_module/
├── rtl/
│   ├── pv_bf16_to_fp32.v
│   ├── pv_fp32_to_bf16.v
│   ├── pv_fp32_mul_ip.sv
│   ├── pv_fp32_add_ip.sv
│   ├── pv_systolic_pe.sv
│   ├── pv_result_converter.sv
│   ├── pv_systolic_tile.sv
│   ├── pv_systolic_gqa_top.sv
│   └── pv_systolic_gqa_tile4_cfg.sv
├── tb/
│   ├── tb_pv_systolic_tile_4x4.sv
│   ├── tb_pv_systolic_4heads_rows4_cols4.sv
│   ├── tb_pv_systolic_4heads_rows8_cols8.sv
│   └── tb_pv_systolic_4heads_full.sv
├── sim_data/
│   ├── softmax_weights.npy
│   ├── v.npy
│   ├── attn_out_per_head.npy
│   ├── softmax_weights_bf16.hex
│   ├── v_bf16.hex
│   ├── attn_out_per_head_bf16.hex
│   └── pv_data_manifest.json
├── constraints/
│   └── pv_100mhz.xdc
└── python/
    ├── generate_pv_hex.py
    ├── compare_rtl_pv.py
    └── inspect_pv_data.py
```

## 3. 已验证的 Python 数据

生成脚本已执行并确认：

```text
P shape       = [4,128,128]
V shape       = [1,128,128]
Context shape = [4,128,128]

使用 BF16 输入、FP32 multiply、逐项 FP32 add、最终 BF16 RNE：
65536 / 65536 与 attn_out_per_head.npy 完全一致
```

首个 BF16 值应为：

```text
P[0,0,0]       = 3f80
V[0,0,0]       = bc39
Context[0,0,0] = bc39
```

## 4. Vivado Floating Point IP

PV 只需要两个 IP：

```text
floating_point_0：FP32 Multiply
floating_point_1：FP32 Add
```

最稳的方式是从已经 65536 PASS 的 QK Vivado 工程中直接复用这两个
`.xci` 和它们的 output products。

配置必须与 QK 成功版本一致：

```text
floating_point_0
- Multiply
- Single precision
- AXI4-Stream Blocking
- A/B/result TREADY enabled
- ACLKEN enabled
- ARESETn enabled

floating_point_1
- 固定 Add only
- Single precision
- AXI4-Stream Blocking
- A/B/result TREADY enabled
- ACLKEN enabled
- ARESETn enabled
```

PV 不需要 QK 的 `floating_point_2`，因为 PV 末尾不乘 `1/sqrt(128)`。

## 5. 安装仿真数据到纯英文目录

Vivado 2018.3 对中文路径不够稳定。打开 Windows Terminal：

```bat
cd /d <你的PV工程目录>\python
python generate_pv_hex.py --install-dir D:/pv_sim_data
```

应看到：

```text
Reference check: 65536/65536 PASS
Vivado simulation data installed to: D:/pv_sim_data
```

最终目录：

```text
D:/pv_sim_data/softmax_weights_bf16.hex
D:/pv_sim_data/v_bf16.hex
D:/pv_sim_data/attn_out_per_head_bf16.hex
```

所有 testbench 默认读取这个目录。

## 6. 添加 Vivado Design Sources

新建 Vivado 工程后，在 Design Sources 中加入：

```text
pv_bf16_to_fp32.v
pv_fp32_to_bf16.v
pv_fp32_mul_ip.sv
pv_fp32_add_ip.sv
pv_systolic_pe.sv
pv_result_converter.sv
pv_systolic_tile.sv
pv_systolic_gqa_top.sv
pv_systolic_gqa_tile4_cfg.sv
```

所有 `.sv` 文件确认：

```text
File Type = SystemVerilog
```

再添加 QK 工程中已经验证成功的：

```text
floating_point_0.xci
floating_point_1.xci
```

如果 IP 提示 output products 未生成：

```text
右键 IP → Generate Output Products
```

## 7. 添加 testbench

在 Simulation Sources 中加入：

```text
tb_pv_systolic_tile_4x4.sv
tb_pv_systolic_4heads_rows4_cols4.sv
tb_pv_systolic_4heads_rows8_cols8.sv
tb_pv_systolic_4heads_full.sv
```

不要把 testbench 加进 Design Sources。

## 8. 仿真顺序

### 8.1 4×4 单 tile

该 testbench 使用 falling-edge 驱动、rising-edge 握手，避免同一 reduction 数据被重复接收。


设置：

```text
tb_pv_systolic_tile_4x4
```

为 Simulation Top，然后：

```tcl
run -all
```

预期：

```text
Expected = 16
PASS     = 16
FAIL     = 0
[PASS] PV 4x4 tile
```

### 8.2 4 head × 4 rows × 4 cols

设置：

```text
tb_pv_systolic_4heads_rows4_cols4
```

预期：

```text
Expected   = 64
Seen       = 64
PASS       = 64
FAIL       = 0
Duplicates = 0
context_last = 1
[PASS] PV systolic matrix
```

注意：这里虽然只输出 4×4 区域，但每个元素仍然完整累加 128 项。

### 8.3 4 head × 8 rows × 8 cols

设置：

```text
tb_pv_systolic_4heads_rows8_cols8
```

预期：

```text
Expected = 256
PASS     = 256
FAIL     = 0
```

### 8.4 完整 PV

设置：

```text
tb_pv_systolic_4heads_full
```

完整输出：

```text
4 × 128 × 128 = 65536
```

预期：

```text
Expected   = 65536
Seen       = 65536
PASS       = 65536
FAIL       = 0
Duplicates = 0
Missing    = 0
context_last = 1
[PASS] PV systolic matrix
```

同时生成：

```text
D:/pv_sim_data/rtl_pv_context_bf16.hex
```

再运行：

```bat
python compare_rtl_pv.py
```

预期：

```text
[PASS] 65536 / 65536 exact BF16 match
```

## 9. 运行时间

当前设计与 QK 一样，是“全局可停顿脉动阵列”：

```text
每个 reduction 项等待 FP32 multiply 和 FP32 add 完成
再让整个阵列前进一步
```

因此 XSim 全量仿真会很慢，这是软件事件仿真造成的，不代表 FPGA 上板
也需要同样的墙钟时间。

## 10. 综合

将 Design Top 设置为：

```text
pv_systolic_gqa_tile4_cfg
```

添加：

```text
constraints/pv_100mhz.xdc
```

然后运行：

```text
Run Synthesis
Open Synthesized Design
Report Utilization
Report Timing Summary
```

重点记录：

```text
LUT
FF
DSP
BRAM
WNS
TNS
```

PV 比 QK 少一个共享 scale multiplier，因此理论上会少使用该后处理乘法器的资源。

## 11. 将来与 QK 共享阵列

此文件夹是独立 PV 工程，便于单独验证。最终 Attention 顶层可以将：

```text
pv_systolic_pe
pv_systolic_tile
```

与 QK 的 PE 网格抽成一个通用 matmul core，然后通过模式选择：

```text
MODE_QK：Q × K^T，结果乘 1/sqrt(128)
MODE_PV：P × V，结果直接 FP32→BF16
```

第一步先把本独立 PV 工程跑到 65536/65536 PASS，再做 QK/PV 阵列复用，
最容易定位问题。
