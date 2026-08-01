# FPT XCZU15EG Attention v3.0 — Online Softmax + Context Fusion

本版本基于 `FPT_XCZU15EG_Attention_v2.6_Causal_DualTile`，把原来的
`QK → 完整 Softmax/P 保存 → P 重放 → PV → Context` 改为块级在线融合：

```text
QK 4×4 score tile
        ↓
更新每行 running max m、running sum l
        ↓
旧 Context 乘 alpha 后重标定
        ↓
当前权重 × V 直接累加到 FP32 Context O
        ↓
行结束时只输出 O/l
```

在线路径不实例化 `score_rowtile_buffer`、`softmax_output_buffer`、
`pv_tile4_pingpong_buffer` 或独立 `pv_parallel_systolic_gqa_top`，因此不再
保存完整 P 矩阵，也不再执行 P 的 DDR/BRAM 重放和“Softmax 完成后等待 PV”阶段。
`ONLINE_MODE=0` 仍保留 v2.6 Legacy 路径，默认 `ONLINE_MODE=1`。

## 当前验证结论

- 最终 Context-bank 版本的开源仿真：单元 Golden 与端到端均 `SIM_PASS`。
- bank 改造前的同算法版本通过 Vivado 2025.2 双 XSim，并且 XCZU15EG
  `attention_board_top` RTL elaboration 为 0 error、0 critical warning。
- bank 改造后的 Vivado 最终重跑被本机损坏的 `XilinxTclStore` 阻塞；修复后需重跑。
- 完整 Synthesis：本机缺少 XCZU15EG Synthesis license，状态为
  `SYNTH_BLOCKED_LICENSE`，不是 RTL 编译失败。
- 实体板：`BOARD_NOT_RUN`。
- 完整 S128/D128 v3.0 Golden 生成器已提供，但本机没有 NumPy，因此尚未生成并替换
  A53 的完整 Context Golden；上板正确性验收前必须完成这一步。

详细设计、计数器和已知边界见
[`doc/V3_0_ONLINE_FUSED_DESIGN.md`](doc/V3_0_ONLINE_FUSED_DESIGN.md)，
文件清单见 [`doc/V3_0_CHANGE_INVENTORY.md`](doc/V3_0_CHANGE_INVENTORY.md)。

若 Vivado 启动时报告用户 `XilinxTclStore` catalog 损坏并无法加载
`xilinx::xsim`，应先在 Vivado Tcl Console 按报错提示执行
`tclapp::reset_tclstore`，重启 Vivado 后再运行下述回归；这属于本机 Vivado
环境故障，不是 RTL 编译错误。

## 最简单的 Vivado GUI 验证

双击：

```text
tests\run_v30_vivado_gui.bat
```

脚本会打开 Vivado GUI 并自动完成两套 XSim。默认生成目录为：

```text
%TEMP%\fpt_v30_online\v30_xsim\
```

仿真通过后，可直接在 GUI 打开：

```text
%TEMP%\fpt_v30_online\v30_xsim\v30_online_xsim.xpr
```

在 Simulation Sources 中切换两个顶层即可查看波形：

- `tb_v30_online_softmax_context`
- `tb_v30_online_attention_system`

## 整板 RTL 检查

打开 Vivado 2025.2，在 Tcl Console 中执行（路径改成实际交付目录）：

```tcl
set ::env(FPT_VIVADO_BUILD_ROOT) D:/fpt_build/v30_elab
cd D:/Vitis/FPT/Llama3-8B-Attention-Optimize/FPT_XCZU15EG_Attention_v3.0_Online_Fused_Delivery
source scripts/check_rtl_elaboration.tcl
```

脚本会生成可在 GUI 打开的工程：

```text
D:/fpt_build/v30_elab/fpt_attention_board_v3_online_fused/
fpt_attention_board_v3_online_fused.xpr
```

## 完整 Golden 与 A53 Header

安装 NumPy 后执行：

```powershell
python -m pip install numpy
python python\generate_v30_board_golden.py
```

成功后，将 `project_config.json` 中的 `context_golden_file` 改为：

```json
"attn_out_online_fused_bf16.hex"
```

再生成 A53 header：

```powershell
python python\generate_golden_header.py
```

不要在完整 v3.0 Golden 未生成时宣称实体板数值闭环通过。

## 综合、实现和上板

许可证可用后，在 Vivado Tcl Console 执行：

```tcl
set ::env(FPT_VIVADO_BUILD_ROOT) D:/fpt_build/v30_board
cd D:/Vitis/FPT/Llama3-8B-Attention-Optimize/FPT_XCZU15EG_Attention_v3.0_Online_Fused_Delivery
source tests/check_v30_board_synthesis.tcl
```

随后可沿用 `scripts/build_attention_board_all.tcl` 或 GUI 的
Run Synthesis → Run Implementation → Generate Bitstream。上板前必须重新生成
bitstream/XSA，并重新编译 Vitis A53 应用；v2.6 的 bit/XSA 不能代表 v3.0。
