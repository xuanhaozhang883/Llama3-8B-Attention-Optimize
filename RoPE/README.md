# RoPE RTL Verification

This directory verifies the **pair-level RoPE arithmetic** used by Llama3-style Attention. It does not implement the complete 128-dimension RoPE engine interface yet; `tb_rope_qk_file.sv` drives the existing combinational `rope_pair_engine` once for each pair and compares all generated Q/K values with the Python Golden Model.

## What Is Verified

For every `[head][token][pair_dimension]`, the RTL calculates:

```text
y0 = x0 * cos - x1 * sin
y1 = x0 * sin + x1 * cos
```

The test slice is:

```text
Q: [4][128][128]
K: [1][128][128]
sin/cos: [128][64]
data type: BF16 raw word
comparison: decoded BF16 absolute error <= 0.001
```

The target tolerance is `0.001`. Small BF16-rounding differences are accepted, but a larger numerical deviation is reported as a failure rather than hidden by widening the tolerance.

## Current Numerical Status

The repaired testbench uses the current shared `fpga_slice` Golden data, which exposed a real RTL numerical issue that the previous test flow hid. A source-level equivalence check of the current `bf16_mul.v` and `bf16_addsub.v` behavior against this Golden slice reports:

```text
Q: 175 / 65536 values exceed 0.001, maximum absolute error 0.03125
K:  45 / 16384 values exceed 0.001, maximum absolute error about 0.06201
```

Therefore, a run against the committed Golden data is currently expected to end with `TEST_RESULT: FAIL`. This is the correct result for the present RTL; it must not be changed into a false PASS by increasing the tolerance. The likely next engineering task is to improve the BF16 multiply/add-subtract rounding and cancellation behavior, then rerun this same testbench until it reports PASS.

The old files are now grouped under `RoPE/legacy/`. They are historical artifacts without their matching inputs. They are not used by the reproducible flow and must not be used as current PASS evidence.

## Standard File Layout

```text
RoPE/
├── bf16_mul.v
├── bf16_addsub.v
├── rope_engine.v                 module rope_pair_engine
├── rope_head_engine.v            optional stateful wrapper prototype
├── tb_rope_qk_file.sv            file-driven Q/K testbench
├── tools/prepare_rope_vectors.py
├── data/
│   ├── q_before_rope_bf16.hex
│   ├── k_before_rope_bf16.hex
│   ├── q_after_rope_golden_bf16.hex
│   ├── k_after_rope_golden_bf16.hex
│   ├── sin_bf16.hex
│   ├── cos_bf16.hex
│   └── meta.txt
├── legacy/                      historical outputs, not current inputs
└── results/                      generated outputs; ignored except .gitkeep
```

All vector files contain one uppercase 16-bit BF16 word per line. Q/K flatten order is `[head][token][dimension]`, and sin/cos flatten order is `[token][pair_dimension]`.

## Prepare or Refresh Vectors

Run from repository root:

```bash
python3 RoPE/tools/prepare_rope_vectors.py
```

The script reads `golden_model_outputs/fpga_slice/*.npy` and the prefix needed from the committed all-position sin/cos ROMs. It validates Q/K shapes and finite values before writing the standard files above.

## Run in Vivado 2025.2

In the Vivado Tcl Console, enter:

```tcl
cd D:/your-path/Llama3-8B-Attention-Optimize
source RoPE/run_rope_sim.tcl
```

The Tcl script compiles the three RTL files and the testbench, runs from `build/rope_xsim/`, then passes absolute vector paths as testbench plusargs. This removes dependence on Vivado's simulation working directory. Once the BF16 arithmetic issue described above is fixed, a successful run ends with:

```text
Q mismatch count = 0 / 65536
K mismatch count = 0 / 16384
TEST_RESULT: PASS
```

Generated `q_rope_verilog.hex` and `k_rope_verilog.hex` are written to `RoPE/results/`.

## Path Overrides

The testbench defaults to repository-relative `RoPE/data/...` paths. When using a custom simulation flow, override individual files without editing RTL:

```text
ROPE_Q_INPUT=<path>/q_before_rope_bf16.hex
ROPE_K_INPUT=<path>/k_before_rope_bf16.hex
ROPE_SIN=<path>/sin_bf16.hex
ROPE_COS=<path>/cos_bf16.hex
ROPE_Q_GOLDEN=<path>/q_after_rope_golden_bf16.hex
ROPE_K_GOLDEN=<path>/k_after_rope_golden_bf16.hex
ROPE_Q_OUTPUT=<path>/q_rope_verilog.hex
ROPE_K_OUTPUT=<path>/k_rope_verilog.hex
```

For Windows, use forward slashes in paths, such as `D:/FPT/.../RoPE/data/q_before_rope_bf16.hex`.

## Fixes Included

- `tb_rope_qk_file.sv` now instantiates `rope_pair_engine`, the module that actually exists in `rope_engine.v`; it no longer references the nonexistent `rope_pair`.
- Personal paths under `C:/Users/23858/Downloads/` were removed.
- The testbench now checks Q and K against Golden vectors, prints the first 16 mismatches, returns `TEST_RESULT: PASS/FAIL`, and validates files before calling `$readmemh`.
- The testbench reports Q/K maximum absolute error, so numerical regressions are visible even when the mismatch count is small.
- `rope_head_engine.v` ROM paths are configurable parameters, with repository-relative defaults.
