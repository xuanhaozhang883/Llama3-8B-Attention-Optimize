# Validation

Directory layout:

```text
D:/FPT_VERIFY/
├── A_attention_with_real_pv_v2_corrected/
├── FPT_BC_QK_Softmax_PV_Delivery_v5/
└── PV_module/
```

Dependency audit:

```bat
cd /d D:\FPT_VERIFY\A_attention_with_real_pv_v2_corrected
python scripts\check_bc_pv_dependencies.py ^
  ..\FPT_BC_QK_Softmax_PV_Delivery_v5 ^
  ..\PV_module
```

Vivado:

```tcl
cd D:/FPT_VERIFY/A_attention_with_real_pv_v2_corrected
source scripts/run_vivado_attention_with_pv_smoke.tcl
```

Expected final line:

```text
[PASS] Corrected A+B+C+real-PV full-path smoke test
```

This small test uses:

```text
QK_TILE=4
BC_PV_TILE=2
REAL_PV_TILE=4
SEQ_LEN=4
HEAD_DIM=4
Q_HEADS=4
GQA_GROUPS=8
```

It verifies through real Context output. It does not include RoPE yet.
