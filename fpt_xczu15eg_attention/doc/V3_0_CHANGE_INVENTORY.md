# v3.0 修改与交付文件清单

本清单以 `FPT_XCZU15EG_Attention_v2.6_Causal_DualTile` 为比较基线。最终逐文件
SHA256/新增/修改统计在生成交付目录时重新计算，避免把 `.Xil`、日志、旧 report、
bit/XSA 和 Vitis workspace 等工程杂质计入源码改动。

2026-07-31 最终清点：交付清单共 34 个文件，其中相对上述基线新增 23 个、修改
11 个、相同 0 个。该统计只覆盖 v3.0 有意交付的 overlay；完整交付副本同时保留
当前 v2.6 工程已有的 RTL、Block Design、ROM 和基础脚本，保证工程可重建。
34 个文件的逐项权威路径见根目录 `delivery_manifest_v30.txt`。

## 核心新增

- `rtl/core/online/online_context_pe.sv`
- `rtl/core/online/online_context_bank.sv`
- `rtl/core/online/online_softmax_context_tile.sv`
- `rtl/core/online/attention_online_system_with_rope_top.sv`

## 板级与已有 RTL 修改

- `rtl/board/fpt_attention_board_engine.sv`
- `rtl/board/attention_board_top.sv`
- `rtl/core/bc/qk/qk_parallel_systolic_gqa_top.sv`

## 验证、Golden 和静态守卫

- `tb/tb_v30_online_softmax_context.sv`
- `tb/tb_v30_online_attention_system.sv`
- `tb/sim_models/floating_point_behavioral.sv`
- `tests/run_v30_online_fused_regression.tcl`
- `tests/run_v30_vivado_gui.bat`
- `tests/check_v30_board_synthesis.tcl`
- `python/generate_v30_online_golden.py`
- `python/generate_v30_board_golden.py`
- `python/validate_v30_online_architecture.py`
- `python/generate_golden_header.py`
- `tests/data/v30_online_scores_s8.hex`
- `tests/data/v30_online_v_s8.hex`
- `tests/data/v30_online_context_s8.hex`

## 配置、软件和文档

- `scripts/project_config.tcl`
- `project_config.json`
- `vitis/src/fpt_attention_board_test.c`
- `README.md`
- `doc/V3_0_ONLINE_FUSED_DESIGN.md`
- `doc/V3_0_CHANGE_INVENTORY.md`

## 明确不应进入交付源码包

- `.Xil/`、`*.jou`、`*.log`
- Vivado `*.runs/`、`*.gen/`、`*.cache/`、`*.sim/`
- `vitis/workspace/`
- 旧 v2.6 `export/`、bitstream、XSA、ELF
- 旧 `reports/` 和板测日志（它们不能证明 v3.0 已上板）
