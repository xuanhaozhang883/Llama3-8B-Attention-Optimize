# Llama3-8B Attention FPGA Accelerator

This repository is an FPT Track B engineering workspace for **Llama3-style GQA Attention**. It is currently a module-level verification project: the Python Golden Model produces reference tensors, and each hardware module is verified against the committed FPGA slice.

It is **not** a complete Llama3 inference accelerator yet. The existing hardware modules are RoPE RTL, causal-mask HLS, and Softmax RTL. QK matrix multiplication, scale, PV matrix multiplication, an Attention top module, and DDR/DMA integration remain future work.

## Quick Start

Clone the repository, keep its directory layout unchanged, then run the commands from the repository root.

```text
Llama3-8B-Attention-Optimize/
├── RoPE/                    RoPE RTL, portable vectors, and file testbench
├── attention_mask_module/   Vitis HLS causal-mask IP and test vectors
├── softmax_module/          Softmax RTL, golden preparation, and testbench
├── CPU_Baseline/            CPU latency/GOPS baseline for FPGA comparison
├── golden_model_outputs/    Committed float32 containers holding BF16-rounded golden tensors
├── docs/                    Interface contract, integration plan, and reproducibility guide
└── llama3_attention_golden_model.py
```

The first document to read is [docs/REPRODUCIBILITY_GUIDE.md](docs/REPRODUCIBILITY_GUIDE.md). It lists every standard path, command, expected PASS marker, and path override option.

## Reference Configuration

```text
Llama3 style: q_heads=32, kv_heads=8, group_size=4, head_dim=128
Committed FPGA verification slice: q_heads=4, kv_heads=1, seq_len=128, head_dim=128
Golden .npy storage: float32; values are already rounded to BF16 at module boundaries
RTL/HLS hardware interface: BF16 raw 16-bit words
```

Tensor layouts are defined in [docs/INTERFACE_SPEC.md](docs/INTERFACE_SPEC.md):

```text
Q/K/V/RoPE: [head][token][dimension]
Score/Mask/Softmax: [q_head][q_token][k_token]
```

## Reproducible Verification Flows

### RoPE RTL

The RoPE testbench consumes only committed, repository-relative vectors in `RoPE/data/`, compares Q and K results against BF16 golden vectors, and writes simulation outputs under `RoPE/results/`.

```bash
python3 RoPE/tools/prepare_rope_vectors.py
```

In Vivado, source `RoPE/run_rope_sim.tcl` from the Tcl Console. The testbench is now a valid Golden comparison. At the current RTL revision it exposes a BF16 arithmetic mismatch instead of claiming a false PASS; see [RoPE/README.md](RoPE/README.md) for the measured baseline and the repair target. Once that arithmetic issue is corrected, the terminal result should be:

```text
TEST_RESULT: PASS
```

More detail: [RoPE/README.md](RoPE/README.md).

### Attention Mask HLS

The conversion script defaults to the committed FPGA slice and produces BF16 vectors under `attention_mask_module/mask_test_vectors/`.

```bash
python3 attention_mask_module/tools/convert_mask_pair_to_hex.py
```

The file testbench compares bit-for-bit because the mask module only copies a BF16 word or writes `0xFF80` (`-inf`). See [attention_mask_module/README.md](attention_mask_module/README.md).

### Softmax RTL

The golden preparation script also defaults to the committed FPGA slice.

```bash
python3 softmax_module/scripts/prepare_softmax_golden.py
```

`softmax_module/tb/tb_file_paths.svh` now uses repository-relative paths. Start xsim at the repository root.

### CPU Baseline

The CPU baseline measures only the GQA Attention kernel (`QK^T`, causal mask, softmax, and `P @ V`) for performance comparison. It does not need model weights and is not the Golden Model.

```bash
cd CPU_Baseline
python -m pip install -r requirements.txt
python -m cpu_baseline.self_test
python -m cpu_baseline.run_benchmark --preset llama3_like_seq128 --dtype fp32 --repeat 30 --warmup 5 --out results/llama3_seq128_fp32
```

## Current Status

| Area | Status | Primary evidence |
| --- | --- | --- |
| Python reference data | Available | `golden_model_outputs/fpga_slice/` |
| CPU performance baseline | Runnable | `CPU_Baseline/cpu_baseline/self_test.py` |
| RoPE pair RTL | Portable file testbench added | `RoPE/tb_rope_qk_file.sv` |
| Causal Mask HLS | Module-level verification flow | `attention_mask_module/` |
| Softmax RTL | Golden file simulation flow | `softmax_module/` |
| QK/scale, PV, Attention top | Not implemented as standalone hardware | [docs/PRIORITY_TODO.md](docs/PRIORITY_TODO.md) |

## Important Notes

- Do not commit Vivado/Vitis generated files (`.Xil`, `.metadata`, `xsim.dir`, logs, waves, HLS build folders). They are ignored by `.gitignore`.
- `golden_model_outputs/full/` is much larger than `fpga_slice/`. Keep the FPGA slice in normal Git; decide as a team whether the full dump should use Git LFS or a release artifact.
- Re-generating `golden_model_outputs/` with `llama3_attention_golden_model.py` requires local Llama3 weights. Re-running the module testbenches does not: the committed `fpga_slice` data is sufficient.
