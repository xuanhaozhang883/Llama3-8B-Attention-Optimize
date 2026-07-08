#!/usr/bin/env python3
"""
Generate Vivado-readable .mem files from golden-model .npy files for softmax_bf16 simulation.

Input:
  scores_after_mask.npy: float32, shape [NUM_HEADS, NUM_ROWS, MAX_LEN]
  softmax_weights.npy:  float32, same shape

Output files under ../data:
  input_scores_bf16.mem      one BF16 hex value per line
  input_masks.mem            one 0/1 mask bit per line, 1 means masked
  expected_probs_bf16.mem    expected probability converted to BF16 hex
  expected_probs_fp32.mem    expected probability raw FP32 bits hex
  golden_shape.txt           shape and simple statistics
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import numpy as np


def float32_to_bf16_hex(values: np.ndarray) -> np.ndarray:
    """Round FP32 to BF16 using round-to-nearest-even and return uint16."""
    arr = np.asarray(values, dtype=np.float32)
    u32 = arr.view(np.uint32)
    lsb = (u32 >> 16) & np.uint32(1)
    rounding_bias = np.uint32(0x7FFF) + lsb
    bf16 = ((u32 + rounding_bias) >> 16).astype(np.uint16)
    return bf16


def float32_to_hex(values: np.ndarray) -> np.ndarray:
    """Return raw IEEE-754 FP32 bits as uint32."""
    return np.asarray(values, dtype=np.float32).view(np.uint32)


def write_hex_file(path: Path, values: np.ndarray, width: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    flat = values.reshape(-1)
    fmt = f"0{width}x"
    with path.open("w", encoding="ascii") as f:
        for v in flat:
            f.write(format(int(v), fmt) + "\n")


def main() -> None:
    here = Path(__file__).resolve().parent
    default_root = here.parent
    parser = argparse.ArgumentParser(description="Prepare softmax golden .mem files.")
    parser.add_argument("--scores", default=str(default_root / "golden_npy" / "scores_after_mask.npy"),
                        help="Path to scores_after_mask.npy")
    parser.add_argument("--weights", default=str(default_root / "golden_npy" / "softmax_weights.npy"),
                        help="Path to softmax_weights.npy")
    parser.add_argument("--out-dir", default=str(default_root / "data"),
                        help="Output data directory")
    args = parser.parse_args()

    scores_path = Path(args.scores)
    weights_path = Path(args.weights)
    out_dir = Path(args.out_dir)

    scores = np.load(scores_path).astype(np.float32, copy=False)
    weights = np.load(weights_path).astype(np.float32, copy=False)

    if scores.shape != weights.shape:
        raise ValueError(f"Shape mismatch: scores {scores.shape}, weights {weights.shape}")
    if scores.ndim != 3:
        raise ValueError(f"Expected 3-D arrays [heads, rows, cols], got shape {scores.shape}")

    # In this golden data, masked positions are -inf after causal mask.
    # We use a separate mask signal because the RTL ignores in_data when in_mask=1.
    masks = (~np.isfinite(scores)).astype(np.uint8)

    input_bf16 = float32_to_bf16_hex(scores)
    expected_bf16 = float32_to_bf16_hex(weights)
    expected_fp32 = float32_to_hex(weights)

    write_hex_file(out_dir / "input_scores_bf16.mem", input_bf16, 4)
    write_hex_file(out_dir / "input_masks.mem", masks, 1)
    write_hex_file(out_dir / "expected_probs_bf16.mem", expected_bf16, 4)
    write_hex_file(out_dir / "expected_probs_fp32.mem", expected_fp32, 8)

    heads, rows, cols = scores.shape
    valid_counts = np.isfinite(scores).sum(axis=-1)
    with (out_dir / "golden_shape.txt").open("w", encoding="utf-8") as f:
        f.write(f"scores_path={scores_path}\n")
        f.write(f"weights_path={weights_path}\n")
        f.write(f"shape={scores.shape}\n")
        f.write(f"NUM_HEADS={heads}\n")
        f.write(f"NUM_ROWS={rows}\n")
        f.write(f"MAX_LEN={cols}\n")
        f.write(f"TOTAL_VALUES={scores.size}\n")
        f.write(f"masked_values={int(masks.sum())}\n")
        f.write(f"valid_values={int((1 - masks).sum())}\n")
        f.write(f"valid_count_min={int(valid_counts.min())}\n")
        f.write(f"valid_count_max={int(valid_counts.max())}\n")
        f.write(f"weights_min={float(np.nanmin(weights))}\n")
        f.write(f"weights_max={float(np.nanmax(weights))}\n")
        f.write("flatten_order=head-major, then row-major, then col-major\n")

    print("Generated softmax golden data files:")
    print(f"  shape              : heads={heads}, rows={rows}, max_len={cols}")
    print(f"  total values       : {scores.size}")
    print(f"  masked values      : {int(masks.sum())}")
    print(f"  output directory   : {out_dir}")
    print("  files:")
    for name in ["input_scores_bf16.mem", "input_masks.mem", "expected_probs_bf16.mem", "expected_probs_fp32.mem", "golden_shape.txt"]:
        print(f"    - {out_dir / name}")


if __name__ == "__main__":
    main()
