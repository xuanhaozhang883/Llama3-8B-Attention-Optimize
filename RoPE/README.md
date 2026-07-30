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

The repaired testbench uses the current shared `fpga_slice` Golden data. The previous BF16 multiplier could wrap a rounded fraction from `0x7F` to `0x00` without incrementing its exponent, producing errors as large as `0.06201`.

`bf16_mul.v` and `bf16_addsub.v` now implement BF16 round-to-nearest-even arithmetic, preserve guard/round/sticky information during addition, and handle zero, subnormal, infinity, and NaN inputs. A source-level regression of the corrected arithmetic against the committed Golden slice reports:

```text
Q: 0 / 65536 values exceed 0.001, maximum absolute error 0.0009765625
K: 0 / 16384 values exceed 0.001, maximum absolute error 0.0009765625
```

Therefore, the committed file testbench is now expected to end with `TEST_RESULT: PASS` at its documented `0.001` absolute tolerance. Some output words can still differ by one BF16 ULP because the RTL rounds each BF16 multiplication before the add/subtract, whereas the Python Golden path preserves higher precision until its final BF16 conversion. This is intentional staged-BF16 behavior, and its maximum observed error remains within the stated tolerance.

The old files are now grouped under `RoPE/legacy/`. They are historical artifacts without their matching inputs. They are not used by the reproducible flow and must not be used as current PASS evidence.

## Standard File Layout

```text
RoPE/
├── bf16_mul.v
├── bf16_addsub.v
├── rope_engine.v                 module rope_pair_engine
├── rope_head_engine.v            optional stateful wrapper prototype
├── tb_rope_qk_file.sv            file-driven Q/K testbench
├── tb_bf16_arith.sv              directed BF16 arithmetic regression
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

## Arithmetic Unit Regression

`tb_bf16_arith.sv` is a fast directed testbench for the BF16 building blocks. It includes the former multiplier carry failures, RNE tie cases, cancellation, subnormal, infinity, and NaN cases. In a Vivado project, add `bf16_mul.v` and `bf16_addsub.v` as design sources, add `tb_bf16_arith.sv` as a simulation source, set `tb_bf16_arith` as the simulation top, then run Behavioral Simulation. The expected terminal line is:

```text
BF16_ARITH_TEST: PASS
```

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
- `bf16_mul.v` now performs RNE rounding with a correct exponent carry; `bf16_addsub.v` retains guard/round/sticky bits instead of truncating aligned operands.
- `tb_bf16_arith.sv` provides a short arithmetic regression before the full Q/K vector simulation.
