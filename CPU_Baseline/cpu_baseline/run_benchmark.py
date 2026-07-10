from __future__ import annotations

import argparse
from pathlib import Path
import time

import numpy as np

from .attention import generate_qkv, gqa_attention_cpu
from .config import BenchmarkConfig, PRESETS
from .metrics import (
    build_perf_metrics,
    save_metrics_json,
    save_summary_csv,
    write_final_result_markdown,
    write_report,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run CPU performance baseline for FPT Track B GQA Attention."
    )
    parser.add_argument("--preset", choices=sorted(PRESETS), default="llama3_like_seq128")
    parser.add_argument("--q-heads", type=int)
    parser.add_argument("--kv-heads", type=int)
    parser.add_argument("--seq-len", type=int)
    parser.add_argument("--head-dim", type=int)
    parser.add_argument("--dtype", choices=["fp32", "bf16_emulated"], default="fp32")
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--repeat", type=int, default=30)
    parser.add_argument("--no-causal", action="store_true")
    parser.add_argument("--out", type=Path, default=Path("results/cpu_perf"))
    return parser.parse_args()


def make_config(args: argparse.Namespace) -> BenchmarkConfig:
    base = PRESETS[args.preset].copy()
    if args.q_heads is not None:
        base["q_heads"] = args.q_heads
    if args.kv_heads is not None:
        base["kv_heads"] = args.kv_heads
    if args.seq_len is not None:
        base["seq_len"] = args.seq_len
    if args.head_dim is not None:
        base["head_dim"] = args.head_dim

    config = BenchmarkConfig(
        **base,
        dtype=args.dtype,
        causal=not args.no_causal,
        seed=args.seed,
        warmup=args.warmup,
        repeat=args.repeat,
    )
    config.validate()
    return config


def run_timed_once(q: np.ndarray, k: np.ndarray, v: np.ndarray, config: BenchmarkConfig) -> tuple[float, float]:
    start = time.perf_counter()
    out = gqa_attention_cpu(q, k, v, config)
    end = time.perf_counter()
    checksum = float(np.sum(out, dtype=np.float64))
    return (end - start) * 1000.0, checksum


def main() -> None:
    args = parse_args()
    config = make_config(args)
    out_dir = args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    q, k, v = generate_qkv(config)

    for _ in range(config.warmup):
        gqa_attention_cpu(q, k, v, config)

    samples_ms: list[float] = []
    checksum = 0.0
    for _ in range(config.repeat):
        latency_ms, checksum = run_timed_once(q, k, v, config)
        samples_ms.append(latency_ms)

    metrics = build_perf_metrics(config, samples_ms, checksum)
    config.save_json(out_dir / "config.json")
    save_metrics_json(out_dir / "cpu_perf_metrics.json", metrics)
    save_summary_csv(out_dir / "summary.csv", metrics)
    write_report(out_dir / "report.txt", metrics)
    write_final_result_markdown(out_dir / "final_result.md", metrics)

    print("PASS: CPU performance benchmark finished")
    print(f"  output_dir: {out_dir}")
    print(
        "  shape: "
        f"q_heads={config.q_heads}, kv_heads={config.kv_heads}, "
        f"seq_len={config.seq_len}, head_dim={config.head_dim}, causal={config.causal}"
    )
    print(f"  dtype: {config.dtype}")
    print(f"  latency_ms_median: {metrics['latency_ms']['median']:.6f}")
    print(f"  latency_ms_p95: {metrics['latency_ms']['p95']:.6f}")
    print(f"  matmul_gops_median: {metrics['ops_estimate']['gops_by_median_latency_matmul_only']:.6f}")
    print("  compare formula: speedup_vs_cpu = cpu_latency_ms_median / fpga_latency_ms")


if __name__ == "__main__":
    main()
