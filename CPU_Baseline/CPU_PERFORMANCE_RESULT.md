# CPU Baseline Performance Result

This file is the final readable CPU performance result for FPT Track B FPGA comparison.

## Test Scope

CPU performance only for the GQA Attention kernel:

```text
QK^T -> causal mask -> softmax -> prob @ V
```

This is not the Golden Model and does not include full Llama inference.

## Test Configuration

| Item | Value |
| --- | --- |
| dtype | fp32 |
| causal | True |
| q_heads | 32 |
| kv_heads | 8 |
| group_size | 4 |
| seq_len | 128 |
| head_dim | 128 |
| repeat | 50 |
| warmup | 10 |

## Main Performance Result

| Metric | Value |
| --- | ---: |
| Median latency | 2.088770 ms |
| Mean latency | 2.088690 ms |
| P95 latency | 2.158706 ms |
| Min latency | 1.991541 ms |
| Max latency | 2.213667 ms |
| MatMul GOPS, median latency | 128.513619 GOPS |
| Rough total GOPS with softmax estimate | 129.768635 GOPS |
| Rough memory bandwidth | 4.518057 GB/s |

## FPGA Comparison Formula

Use median latency for the headline comparison:

```text
speedup_vs_cpu = CPU median latency ms / FPGA latency ms
```

For this run:

```text
speedup_vs_cpu = 2.088770 / FPGA_latency_ms
```

## Platform

| Item | Value |
| --- | --- |
| platform | macOS-26.5-arm64-arm-64bit |
| machine | arm64 |
| processor | arm |
| python | 3.9.6 |
| numpy | 2.0.2 |
| cpu_count | 10 |
