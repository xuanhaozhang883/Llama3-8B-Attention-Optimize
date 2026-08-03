# v3.0 发布产物 SHA-256

发布日期：2026-08-03  
目标器件：`xczu15eg-ffvb1156-2-i`  
验证工具：Vivado / Vitis 2024.2

| 文件 | 字节数 | SHA-256 |
|---|---:|---|
| `export/fpt_attention_board_v30_causal_dualtile.bit` | 28,700,869 | `A770CCB457E30B32BCB7AA4270F2BCA4A8C784369B752370B0631841628DB31F` |
| `export/fpt_attention_board_v30_causal_dualtile.xsa` | 772,801 | `A1956DE4A740BE0B06C2824CC74E6EB03DCE904775CA07DAAF60CAEF713EC8F1` |
| `rtl/core/bc/softmax/softmax_bf16.sv` | 23,931 | `A75940DB10016ED5E330F7E35ED3FA690F4EEA47A7A643185440A790C4571249` |
| `logs/v3.0_online_softmax_exact_denom_10run_pass.txt` | 12,396 | `6811FB61CAA33A633AD188327E58DC84F37AF26C102E180FAFD3C50DD1120CCE` |

说明：`fpt_attention_board_v26_causal_dualtile.bit/.xsa` 是为兼容既有 Tcl、Vitis 和上板脚本保留的同内容副本；发布时优先使用上表中的 `v30` 文件名。
