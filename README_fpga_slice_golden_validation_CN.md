# FPGA slice 全链条 Python 黄金模型验证

## 结论先说

这组 `fpga_slice` 不是单头，而是一个完整 GQA Group：

- Q：`[4,128,128]`，4 个 Query heads；
- K：`[1,128,128]`，1 个 KV head；
- V：`[1,128,128]`；
- Context：`[4,128,128]`，共 65536 个 BF16 输出。

测试链路是：

`q_before_rope + k_before_rope -> RTL RoPE -> QK -> causal mask -> Softmax -> real PV -> Context`

正式顶层仍保留 8 个 GQA Groups 的接口宽度和缓存容量。本测试通过
`RUN_GQA_GROUPS=1` 只执行第 0 组，不能把一组 slice 假装成八组 full 数据。

## 文件放置位置

把交付包中的文件放到项目根目录下的这些位置：

| 交付文件 | 放置位置 |
| --- | --- |
| `attention_system_with_rope_pv_top.sv` | `A_attention_integration_final_v5/rtl/top/`，替换之前同名文件 |
| `tb_attention_system_with_rope_pv_fpga_slice_golden.sv` | `A_attention_integration_final_v5/tb/` |
| `prepare_attention_fpga_slice_vectors.py` | `A_attention_integration_final_v5/scripts/` |
| `run_vivado_attention_rope_pv_fpga_slice_golden.tcl` | `A_attention_integration_final_v5/scripts/` |
| `golden_fpga_slice_data/` 整个目录 | `A_attention_integration_final_v5/tb/golden_fpga_slice_data/` |

不要替换 `QK_after_RoPE/rtl/rope/rope_pair_pipeline.sv`。当前 staged-BF16
RoPE 是项目文档明确记录的数值实现，TB 会按其公开容差验证。

## 黄金数据来源

TB 不生成随机 Q、K 或 V。交付数据来自项目现有黄金文件：

- Q/K、RoPE 后 Q/K、sin/cos：`RoPE/data/`；
- V、Softmax、Context：`PV_module/sim_data/`；
- 第三个期望输出就是 `attn_out_per_head.npy` 对应的 65536 个 BF16 字。

已经完成以下同源核对：

- Q HEX 与上传的 `q_before_rope.npy`：65536/65536 完全一致；
- K HEX 与上传的 `k_before_rope.npy`：16384/16384 完全一致；
- Context HEX 与上传的 `attn_out_per_head.npy`：65536/65536 完全一致；
- V HEX 还原为标准 `(1,128,128)` NumPy 文件后的 SHA-256，与仓库
  `fpga_slice/v.npy` 的 Git LFS 对象 ID 完全一致。

`golden_fpga_slice_data/attention_fpga_slice_manifest.json` 记录了全部来源、
形状、字数和 SHA-256。

## 可选：从真实 `.npy` 重新生成 HEX

如果本机 `golden_model_outputs/fpga_slice/*.npy` 是真实数组，可以在项目根目录运行：

```powershell
python A_attention_integration_final_v5/scripts/prepare_attention_fpga_slice_vectors.py --project-root .
```

成功时会显示：

```text
[PASS] fpga_slice golden vectors validated
```

脚本严格读取以下 7 个文件：

- `q_before_rope.npy`
- `k_before_rope.npy`
- `v.npy`
- `q_after_rope.npy`
- `k_after_rope.npy`
- `softmax_weights.npy`
- `attn_out_per_head.npy`

如果文件只是约 130 字节的 Git LFS 指针，脚本会停止并提示 `git lfs pull`，
不会把文本指针误当作数组。交付包已经带有经过同源核对的 HEX，所以不重新生成
也可以直接仿真。

## 推荐的一键 Vivado 运行方式

尽量把项目放到纯英文路径，例如 `D:/FPT/Llama3-8B`。在 Vivado Tcl Console：

```tcl
cd D:/FPT/Llama3-8B/A_attention_integration_final_v5
source scripts/run_vivado_attention_rope_pv_fpga_slice_golden.tcl
```

Tcl 会新建独立工程：

`A_attention_integration_final_v5/vivado_attention_rope_pv_fpga_slice_golden`

不会覆盖刚才已经通过的小规模 smoke 工程。

## 如果手工添加 Vivado Sources

建议直接用 Tcl，因为它已经列全所有 RTL。手工添加时分类如下：

- Design Sources：与上一轮全链 smoke 完全相同的全部 A、B+C、RoPE bridge、
  real PV RTL；其中顶层使用本包更新后的 `attention_system_with_rope_pv_top.sv`。
- Simulation Sources：
  - `A_attention_integration_final_v5/tb/tb_attention_system_with_rope_pv_fpga_slice_golden.sv`
  - `FPT_BC_QK_Softmax_PV_Delivery_v5/sim_models/floating_point_behavioral.sv`
- Memory Initialization Files：
  - `FPT_BC_QK_Softmax_PV_Delivery_v5/rtl/softmax/exp_lut_q15.mem`
  - `golden_fpga_slice_data/q_before_rope_bf16.hex`
  - `golden_fpga_slice_data/k_before_rope_bf16.hex`
  - `golden_fpga_slice_data/v_bf16.hex`
  - `golden_fpga_slice_data/q_after_rope_golden_bf16.hex`
  - `golden_fpga_slice_data/k_after_rope_golden_bf16.hex`
  - `golden_fpga_slice_data/softmax_weights_bf16.hex`
  - `golden_fpga_slice_data/attn_out_per_head_bf16.hex`
  - `golden_fpga_slice_data/sin_bf16.hex`
  - `golden_fpga_slice_data/cos_bf16.hex`
- Constraints：空。Behavioral Simulation 不添加任何 XDC。
- Design top：`attention_system_with_rope_pv_top`
- Simulation top：`tb_attention_system_with_rope_pv_fpga_slice_golden`

不要把 `.npy` 加入 Vivado；`$readmemh` 读取的是转换后的 BF16 HEX。

## 如何判断结果

最终成功行是：

```text
[PASS] fpga_slice full-chain numerical comparison passed
```

TB 同时报告两类指标：

1. `mismatches`：BF16 字是否逐位相等；
2. `tolerance failures`：数值误差是否超过项目规定的范围。

本项目的 RoPE 和 LUT Softmax 是近似/分阶段舍入实现，因此 `mismatches` 可以非零；
这不等于错误。必须满足：

- RoPE Q/K：绝对误差不超过 `0.001`；
- Softmax：绝对误差不超过 `0.0021`；
- 最终 Context：绝对误差不超过 `0.0001`；
- 所有 `tolerance failures = 0`；
- `Protocol error vector = 000000`；
- 65536 个 Context 坐标全部出现且没有重复；
- Group completion 和 system done 都等于 1。

完整软件镜像对这组真实数据的跑前预测为：Softmax 最大绝对误差
`0.001953125`，Context 最大绝对误差 `0.00006103515625`，均低于上述阈值。

如果失败，日志标签可以直接定位：

- `[ROPE-Q]` / `[ROPE-K]`：RoPE 或 split-half 输入顺序问题；
- `[SOFTMAX]`：QK、mask 或 Softmax 数值问题；
- `[CONTEXT]`：PV、V 地址、repack 或最终输出问题；
- `[META]`：head/group/row/col 元数据映射问题。

128×128 的真实 slice 比 4×4 smoke test 慢很多，Vivado 仿真持续数分钟甚至更久
是正常现象，不要在仍有波形活动时手动停止。
