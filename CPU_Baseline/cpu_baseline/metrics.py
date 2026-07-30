from __future__ import annotations

import csv
import json
import os
from pathlib import Path
import platform
import statistics
import time

import numpy as np

from .config import BenchmarkConfig


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    return float(np.percentile(np.asarray(values, dtype=np.float64), pct))


def estimate_matmul_ops(config: BenchmarkConfig) -> int:
    # QK^T and Prob x V each use multiply+add, counted as 2 ops.
    return int(4 * config.q_heads * config.seq_len * config.seq_len * config.head_dim)


def estimate_softmax_ops(config: BenchmarkConfig) -> int:
    # Rough scalar estimate: max, subtract/exp, sum, divide.
    return int(5 * config.q_heads * config.seq_len * config.seq_len)


def estimate_bytes_accessed(config: BenchmarkConfig) -> int:
    dtype_bytes = config.dtype_bytes
    q = config.q_heads * config.seq_len * config.head_dim
    k = config.kv_heads * config.seq_len * config.head_dim
    v = config.kv_heads * config.seq_len * config.head_dim
    scores = config.q_heads * config.seq_len * config.seq_len
    probs = scores
    out = config.q_heads * config.seq_len * config.head_dim
    return int((q + k + v + scores + probs + out) * dtype_bytes)


def platform_info() -> dict:
    return {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "processor": platform.processor(),
        "python": platform.python_version(),
        "numpy": np.__version__,
        "cpu_count": os.cpu_count(),
    }


def build_perf_metrics(config: BenchmarkConfig, samples_ms: list[float], checksum: float) -> dict:
    samples = [float(x) for x in samples_ms]
    median_ms = float(statistics.median(samples))
    mean_ms = float(statistics.mean(samples))
    std_ms = float(statistics.pstdev(samples)) if len(samples) > 1 else 0.0
    min_ms = float(min(samples))
    max_ms = float(max(samples))
    seconds = median_ms / 1000.0
    matmul_ops = estimate_matmul_ops(config)
    softmax_ops = estimate_softmax_ops(config)
    total_ops = matmul_ops + softmax_ops
    bytes_accessed = estimate_bytes_accessed(config)

    return {
        "benchmark_type": "cpu_performance_only",
        "timestamp_unix": time.time(),
        "config": config.to_dict(),
        "latency_ms": {
            "mean": mean_ms,
            "median": median_ms,
            "min": min_ms,
            "max": max_ms,
            "std": std_ms,
            "p90": percentile(samples, 90),
            "p95": percentile(samples, 95),
            "p99": percentile(samples, 99),
            "samples": samples,
        },
        "ops_estimate": {
            "matmul_ops": matmul_ops,
            "softmax_ops_rough": softmax_ops,
            "total_ops_rough": total_ops,
            "gops_by_median_latency_matmul_only": matmul_ops / seconds / 1e9 if seconds > 0 else 0.0,
            "gops_by_median_latency_with_softmax_estimate": total_ops / seconds / 1e9 if seconds > 0 else 0.0,
        },
        "memory_estimate": {
            "bytes_accessed_rough": bytes_accessed,
            "bandwidth_gb_s_by_median_latency": bytes_accessed / seconds / 1e9 if seconds > 0 else 0.0,
        },
        "output_checksum": float(checksum),
        "platform": platform_info(),
        "comparison_note": (
            "Use median latency for CPU-vs-FPGA comparison. "
            "This CPU baseline measures only the GQA attention kernel with synthetic Q/K/V."
        ),
    }


def save_metrics_json(path: Path, metrics: dict) -> None:
    path.write_text(json.dumps(metrics, indent=2), encoding="utf-8")


def save_summary_csv(path: Path, metrics: dict) -> None:
    c = metrics["config"]
    row = {
        "dtype": c["dtype"],
        "causal": c["causal"],
        "q_heads": c["q_heads"],
        "kv_heads": c["kv_heads"],
        "group_size": c["group_size"],
        "seq_len": c["seq_len"],
        "head_dim": c["head_dim"],
        "latency_ms_median": metrics["latency_ms"]["median"],
        "latency_ms_mean": metrics["latency_ms"]["mean"],
        "latency_ms_p95": metrics["latency_ms"]["p95"],
        "matmul_gops_median": metrics["ops_estimate"]["gops_by_median_latency_matmul_only"],
        "bandwidth_gb_s_median": metrics["memory_estimate"]["bandwidth_gb_s_by_median_latency"],
    }
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(row))
        writer.writeheader()
        writer.writerow(row)


def write_report(path: Path, metrics: dict) -> None:
    c = metrics["config"]
    text = f"""CPU Performance Baseline Report

Scope:
  CPU performance only for GQA Attention kernel.
  This is not a Golden Model and does not replace the Golden Model block.

Shape:
  q_heads={c['q_heads']}, kv_heads={c['kv_heads']}, group_size={c['group_size']}
  seq_len={c['seq_len']}, head_dim={c['head_dim']}, dtype={c['dtype']}, causal={c['causal']}

Latency:
  median_ms={metrics['latency_ms']['median']:.6f}
  mean_ms={metrics['latency_ms']['mean']:.6f}
  p95_ms={metrics['latency_ms']['p95']:.6f}
  min_ms={metrics['latency_ms']['min']:.6f}
  max_ms={metrics['latency_ms']['max']:.6f}

Throughput Estimate:
  matmul_ops={metrics['ops_estimate']['matmul_ops']}
  matmul_gops_by_median_latency={metrics['ops_estimate']['gops_by_median_latency_matmul_only']:.6f}
  total_ops_rough_with_softmax={metrics['ops_estimate']['total_ops_rough']}
  total_gops_rough_by_median_latency={metrics['ops_estimate']['gops_by_median_latency_with_softmax_estimate']:.6f}

Memory Estimate:
  bytes_accessed_rough={metrics['memory_estimate']['bytes_accessed_rough']}
  bandwidth_gb_s_by_median_latency={metrics['memory_estimate']['bandwidth_gb_s_by_median_latency']:.6f}

Platform:
  {metrics['platform']['platform']}
  python={metrics['platform']['python']}, numpy={metrics['platform']['numpy']}

Compare with FPGA:
  speedup_vs_cpu = cpu_latency_ms_median / fpga_latency_ms
"""
    path.write_text(text, encoding="utf-8")


def write_final_result_markdown(path: Path, metrics: dict) -> None:
    c = metrics["config"]
    latency = metrics["latency_ms"]
    ops = metrics["ops_estimate"]
    memory = metrics["memory_estimate"]
    platform_data = metrics["platform"]
    text = f"""# CPU Baseline Performance Result

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
| dtype | {c['dtype']} |
| causal | {c['causal']} |
| q_heads | {c['q_heads']} |
| kv_heads | {c['kv_heads']} |
| group_size | {c['group_size']} |
| seq_len | {c['seq_len']} |
| head_dim | {c['head_dim']} |
| repeat | {c['repeat']} |
| warmup | {c['warmup']} |

## Main Performance Result

| Metric | Value |
| --- | ---: |
| Median latency | {latency['median']:.6f} ms |
| Mean latency | {latency['mean']:.6f} ms |
| P95 latency | {latency['p95']:.6f} ms |
| Min latency | {latency['min']:.6f} ms |
| Max latency | {latency['max']:.6f} ms |
| MatMul GOPS, median latency | {ops['gops_by_median_latency_matmul_only']:.6f} GOPS |
| Rough total GOPS with softmax estimate | {ops['gops_by_median_latency_with_softmax_estimate']:.6f} GOPS |
| Rough memory bandwidth | {memory['bandwidth_gb_s_by_median_latency']:.6f} GB/s |

## FPGA Comparison Formula

Use median latency for the headline comparison:

```text
speedup_vs_cpu = CPU median latency ms / FPGA latency ms
```

For this run:

```text
speedup_vs_cpu = {latency['median']:.6f} / FPGA_latency_ms
```

## Platform

| Item | Value |
| --- | --- |
| platform | {platform_data['platform']} |
| machine | {platform_data['machine']} |
| processor | {platform_data['processor']} |
| python | {platform_data['python']} |
| numpy | {platform_data['numpy']} |
| cpu_count | {platform_data['cpu_count']} |
"""
    path.write_text(text, encoding="utf-8")
