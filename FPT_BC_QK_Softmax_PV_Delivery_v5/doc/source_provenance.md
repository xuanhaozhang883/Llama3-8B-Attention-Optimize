# Source Provenance

以下 QK 文件来自用户提供的项目压缩包 `Llama3-8B-Attention-Optimize(3).zip`：

```text
bf16_to_fp32.v
fp32_to_bf16.v
fp32_mul_ip.v
fp32_add_ip.v
qk_result_scaler.sv
qk_systolic_pe.sv
qk_systolic_tile.sv
qk_systolic_gqa_top.sv
```

v3 只为部分文件增加 `timescale`，未改变 QK 计算结构。

Softmax 黄金数据来自该项目的：

```text
softmax_module/data/
```

完整 Q/K 可选向量来自：

```text
QK_PV_module/sim_data/
```
