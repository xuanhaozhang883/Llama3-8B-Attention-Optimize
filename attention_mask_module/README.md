# Llama3-8B Attention Optimize

This repository contains FPGA/HLS-oriented modules and validation flows for **Llama3-style attention acceleration**.  
The current development focus is building a reliable verification pipeline before moving toward higher-performance attention modules.

Current core workflow:

```text
Python Golden Model
        ↓
Generate Q/K/V or score tensors
        ↓
Export golden data / test vectors
        ↓
Vitis HLS C Simulation
        ↓
C Synthesis
        ↓
C/RTL Co-Simulation
        ↓
Package IP for Vivado integration
```

---

## 1. Project Goal

The long-term goal is to explore FPGA acceleration for the attention layer used in Llama3-style models.

Key technical directions include:

- Grouped Query Attention (GQA)
- Causal attention mask
- BF16 / mixed-precision data format
- Softmax hardware approximation
- Streaming / tiled attention dataflow
- Python Golden Model based verification
- Vitis HLS IP packaging and Vivado integration

This repository is currently in the **module-level verification stage**, not full Llama3 deployment.

---

## 2. Repository Structure

```text
.
├── RoPE/
│   └── Rotary Position Embedding related files
│
├── attention_mask_module/
│   └── HLS causal attention mask module and validation files
│
├── golden_model_outputs/
│   └── Python golden model output data and reference tensors
│
├── softmax_module/
│   └── Softmax module development files
│
├── llama3_attention_golden_model.py
│   └── Python golden model for Llama3-style attention data generation
│
├── .gitignore
│
└── README.md
```

---

## 3. Llama3 Attention Background

Llama3-8B uses a GQA-style attention configuration.

Typical reference parameters:

```text
hidden_size = 4096
num_attention_heads = 32
num_key_value_heads = 8
head_dim = 128
group_size = num_attention_heads / num_key_value_heads = 4
```

For the attention score matrix after `QK^T`, the causal mask module operates on:

```text
scores[q_head][q_token][k_token]
```

For a local test case, the current golden data shape is:

```text
[4, 128, 128]
```

The HLS module is designed to support a maximum shape of:

```text
[32, 128, 128]
```

---

## 4. Attention Mask Module

### 4.1 Function

The `attention_mask_module` applies causal masking to the attention score matrix.

Mask rule:

```text
if causal == true and k_token > q_token:
    masked_score = mask_value
else:
    masked_score = raw_score
```

This is used before Softmax to prevent a token from attending to future tokens.

---

### 4.2 Data Layout

The tensor layout is:

```text
[q_head][q_token][k_token]
```

Flattened index:

```cpp
idx = (q_head * seq_len + q_token) * seq_len + k_token;
```

Example:

```text
raw_scores.hex
    ↓
attention_mask()
    ↓
masked_scores
    ↓
compare with golden_masked_scores.hex
```

---

### 4.3 Data Type

The current HLS module uses:

```cpp
typedef ap_uint<16> score_t;
```

This represents a **BF16 raw 16-bit word**.

Important values:

```text
0xFF80 = BF16 representation of -inf
0xCE6E ≈ BF16 representation of -1e9
```

For the current Python golden output, masked positions use:

```text
-inf
```

Therefore, the current file-based testbench uses:

```cpp
mask_value = 0xFF80;
```

---

## 5. Golden Model Verification Flow

The current validation flow uses two Python-generated NumPy files:

```text
scores_before_mask.npy.npy
scores_after_mask.npy.npy
```

Their meaning:

```text
scores_before_mask.npy.npy
    = raw attention scores before causal mask

scores_after_mask.npy.npy
    = Python golden output after causal mask
```

These files are converted into BF16 raw hex files:

```text
raw_scores.hex
golden_masked_scores.hex
```

Then the file-based HLS testbench reads these hex files and performs bit-level comparison.

Validation flow:

```text
scores_before_mask.npy.npy
        ↓
convert to BF16 raw hex
        ↓
raw_scores.hex
        ↓
HLS attention_mask()
        ↓
HLS output
        ↓
compare with golden_masked_scores.hex
        ↑
scores_after_mask.npy.npy
        ↓
convert to BF16 raw hex
```

For the mask module, exact bit-level matching is expected because the module only copies data or writes a fixed mask value. It does not perform floating-point arithmetic, multiplication, accumulation, or Softmax approximation.

---

## 6. Main Files

### 6.1 HLS Source Files

```text
attention_mask_module/src/attention_mask.cpp
attention_mask_module/src/attention_mask.hpp
```

Main HLS interface:

```cpp
extern "C" {
void attention_mask(
    const score_t raw_scores[AM_MAX_ELEMENTS],
    score_t masked_scores[AM_MAX_ELEMENTS],
    int q_heads,
    int seq_len,
    bool causal,
    score_t mask_value
);
}
```

---

### 6.2 Testbench Files

```text
attention_mask_module/tb/tb_attention_mask.cpp
attention_mask_module/tb/tb_attention_mask_from_file.cpp
```

#### `tb_attention_mask.cpp`

Self-generated sanity testbench.

Purpose:

```text
Generate raw scores inside C++
Run attention_mask()
Compare output with C++ expected result
```

This testbench is useful for quick functional checks and does not depend on external files.

#### `tb_attention_mask_from_file.cpp`

File-based golden testbench.

Purpose:

```text
Read raw_scores.hex
Read golden_masked_scores.hex
Run attention_mask()
Compare HLS output with Python golden output
```

This testbench is used to verify that the HLS module matches the Python Golden Model.

---

### 6.3 Conversion Script

```text
attention_mask_module/tools/convert_mask_pair_to_hex.py
```

Function:

```text
Input:
    scores_before_mask.npy.npy
    scores_after_mask.npy.npy

Output:
    raw_scores.hex
    golden_masked_scores.hex
    meta.txt
```

It converts float32 NumPy tensors to BF16 raw uint16 hex format.

---

## 7. How to Run

### 7.1 Generate Hex Test Vectors

Put the Python golden files in the expected location, then run:

```bash
python attention_mask_module/tools/convert_mask_pair_to_hex.py
```

Expected outputs:

```text
raw_scores.hex
golden_masked_scores.hex
meta.txt
```

---

### 7.2 Run Vitis HLS C Simulation

In Vitis HLS 2025.2:

```text
C Simulation
→ Run
```

Expected result:

```text
PASS
matched
```

This means the HLS C model matches the Python golden output.

---

### 7.3 Run C Synthesis

```text
C Synthesis
→ Run
```

Expected design properties:

```text
Target device: xc7z015-clg485-2
Clock target: 10 ns / 100 MHz
Data type: ap_uint<16>
Max shape: [32, 128, 128]
Max elements: 524,288
Core loop II: 1
Core loop DSP: 0 expected
Top DSP: 0 or 1 acceptable
URAM: 0
```

---

### 7.4 Run C/RTL Co-Simulation

```text
C/RTL Co-Simulation
→ Run
```

Expected result:

```text
PASS
```

This verifies that the generated RTL also matches the Python golden output through the C++ testbench.

---

### 7.5 Package IP

After successful synthesis and co-simulation:

```text
Package
→ Run
```

The generated IP can then be imported into Vivado through:

```text
Vivado
→ Settings
→ IP
→ Repository
→ Add Repository
```

---

## 8. Current Attention Mask Status

| Item | Status |
|---|---|
| Python golden data prepared | Done |
| `.npy` to BF16 hex conversion | Done |
| Self-generated C++ testbench | Done |
| File-based golden testbench | Done |
| C Simulation | PASS / matched |
| C Synthesis | Done |
| C/RTL Co-Simulation | To be confirmed or recorded |
| IP Packaging | Done when HLS Package finishes |

Update this table when new reports are generated.

---

## 9. Notes for Integration

The standalone attention mask IP uses memory-based interfaces:

```text
raw_scores    → M_AXI read
masked_scores → M_AXI write
control       → AXI-Lite
```

This is useful for modular verification and early-stage integration.

However, for final performance optimization, this module should ideally be fused into the Softmax stage:

```text
QK score streaming
        ↓
mask inside softmax
        ↓
softmax output
```

Reason:

```text
Standalone mask IP introduces extra memory read/write traffic.
Fusing mask into Softmax can reduce DDR bandwidth pressure.
```

---

## 10. Common Issues

### 10.1 Cannot Open Hex File

Error example:

```text
Cannot open file: raw_scores.hex
Cannot open file: golden_masked_scores.hex
```

Reason:

```text
Vitis C Simulation working directory is different from the file location.
```

Fix:

- Use correct relative path.
- Or use absolute path in the testbench.
- On Windows, use `/` instead of `\`.

Example:

```cpp
"D:/Vitis/Llama3-8B-Attention-Optimize/attention_mask_module/test_vectors/raw_scores.hex"
```

---

### 10.2 C Simulation PASS but Co-Simulation FAIL

Possible reasons:

- Testbench file path not found during RTL co-simulation.
- The testbench relies on files not copied into the co-simulation working directory.
- Interface depth or array size setting is inconsistent.

Recommended check:

```text
1. Confirm hex files are accessible.
2. Confirm q_heads and seq_len match the test vector shape.
3. Confirm mask_value is 0xFF80 for -inf golden output.
4. Check cosim log for mismatch index.
```

---

### 10.3 DSP Is Still 1

For this module, the core mask loop should not require DSP.

If top-level DSP is 1, it may come from address/control logic generated by HLS. This is acceptable for the first validation version as long as the core loop DSP is 0 and II is 1.

---

## 11. Future Work

Planned next steps:

- Verify Softmax module against Python Golden Model.
- Combine Attention Mask with Softmax.
- Explore finite mask value such as BF16 `-1e9`.
- Build a streaming attention pipeline.
- Compare FPGA baseline and optimized FPGA design.
- Extend test cases from `[4,128,128]` to more Llama3-like settings.
- Prepare performance and correctness reports for FPT Track B.

---

## 12. Suggested PR Summary

```text
This PR adds the HLS Attention Mask validation module.

It includes HLS source code, self-generated and file-based testbenches,
a Python script for converting golden NumPy outputs to BF16 raw hex,
test vectors, and README documentation.

The current file-based C Simulation matches the Python golden output.
The standalone module is intended for modular verification, while the final
optimized pipeline should fuse masking into Softmax to reduce extra memory traffic.
```
