#!/usr/bin/env python3
"""Convert Python Golden mask .npy tensors to BF16 raw hex vectors.

Expected input:
  before: float32 raw scores with shape [q_heads, seq_len, seq_len]
  after : float32 masked scores with the same shape

Expected causal relation:
  kt <= qt: after == before
  kt > qt : after == -inf
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np


MASK_VALUE_BF16 = 0xFF80


def fp32_to_bf16_rne(values: np.ndarray) -> np.ndarray:
    """Convert float32 array to BF16 raw uint16 with round-to-nearest-even."""
    fp32 = np.asarray(values, dtype=np.float32)
    bits = fp32.view(np.uint32)
    lsb = (bits >> 16) & np.uint32(1)
    rounding_bias = np.uint32(0x7FFF) + lsb
    bf16 = ((bits + rounding_bias) >> 16).astype(np.uint16)
    return bf16


def write_hex(path: Path, words: np.ndarray) -> None:
    flat = np.asarray(words, dtype=np.uint16).reshape(-1)
    with path.open("w", encoding="ascii", newline="\n") as f:
        for word in flat:
            f.write(f"{int(word):04X}\n")


def portable_path(path: Path, repo_root: Path) -> str:
    """Prefer a repository-relative metadata path over a machine-local path."""
    try:
        return path.relative_to(repo_root).as_posix()
    except ValueError:
        return path.as_posix()


def check_mask_pair(before: np.ndarray, after: np.ndarray) -> tuple[int, int, int]:
    if before.shape != after.shape:
        raise ValueError(f"Shape mismatch: before={before.shape}, after={after.shape}")
    if before.ndim != 3:
        raise ValueError(f"Expected ndim=3, got ndim={before.ndim}")

    q_heads, q_seq_len, k_seq_len = before.shape
    if q_seq_len != k_seq_len:
        raise ValueError(f"Expected square score matrix, got shape={before.shape}")

    if before.dtype != np.float32:
        raise ValueError(f"before dtype must be float32, got {before.dtype}")
    if after.dtype != np.float32:
        raise ValueError(f"after dtype must be float32, got {after.dtype}")

    if np.isnan(before).any() or np.isnan(after).any():
        raise ValueError("NaN is not allowed in mask golden tensors")

    keep = np.tril(np.ones((q_seq_len, k_seq_len), dtype=bool))
    future = np.triu(np.ones((q_seq_len, k_seq_len), dtype=bool), k=1)

    keep_3d = np.broadcast_to(keep, before.shape)
    future_3d = np.broadcast_to(future, before.shape)

    if not np.array_equal(before[keep_3d], after[keep_3d]):
        diff = np.abs(before[keep_3d] - after[keep_3d])
        raise ValueError(
            "Causal keep-region mismatch: "
            f"nonzero={int(np.count_nonzero(diff))}, max_abs={float(np.max(diff))}"
        )

    if not np.isneginf(after[future_3d]).all():
        bad = np.count_nonzero(~np.isneginf(after[future_3d]))
        raise ValueError(f"Future-token region must be -inf, bad_count={int(bad)}")

    if np.isinf(before).any():
        raise ValueError("before tensor should contain finite raw scores only")

    return q_heads, q_seq_len, q_heads * q_seq_len * k_seq_len


def default_paths() -> tuple[Path, Path, Path]:
    script_dir = Path(__file__).resolve().parent
    module_dir = script_dir.parent
    repo_root = module_dir.parent
    before = repo_root / "golden_model_outputs" / "fpga_slice" / "scores_before_mask.npy"
    after = repo_root / "golden_model_outputs" / "fpga_slice" / "scores_after_mask.npy"
    out_dir = module_dir / "mask_test_vectors"
    return before, after, out_dir


def parse_args() -> argparse.Namespace:
    before, after, out_dir = default_paths()
    parser = argparse.ArgumentParser(
        description="Convert mask golden .npy tensors to BF16 raw hex files."
    )
    parser.add_argument("--before", type=Path, default=before)
    parser.add_argument("--after", type=Path, default=after)
    parser.add_argument("--out-dir", type=Path, default=out_dir)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    before_path = args.before.resolve()
    after_path = args.after.resolve()
    out_dir = args.out_dir.resolve()
    repo_root = Path(__file__).resolve().parents[2]

    before = np.load(before_path)
    after = np.load(after_path)

    q_heads, seq_len, elements = check_mask_pair(before, after)

    raw_bf16 = fp32_to_bf16_rne(before)
    golden_bf16 = fp32_to_bf16_rne(after)

    future = np.triu(np.ones((seq_len, seq_len), dtype=bool), k=1)
    future_3d = np.broadcast_to(future, after.shape)
    if not np.all(golden_bf16[future_3d] == MASK_VALUE_BF16):
        raise ValueError("Converted -inf region did not become BF16 0xFF80")

    out_dir.mkdir(parents=True, exist_ok=True)
    raw_path = out_dir / "raw_scores.hex"
    golden_path = out_dir / "golden_masked_scores.hex"
    meta_path = out_dir / "meta.txt"

    write_hex(raw_path, raw_bf16)
    write_hex(golden_path, golden_bf16)

    with meta_path.open("w", encoding="ascii", newline="\n") as f:
        f.write(f"q_heads={q_heads}\n")
        f.write(f"seq_len={seq_len}\n")
        f.write(f"elements={elements}\n")
        f.write("mask_value_bf16=FF80\n")
        f.write("layout=[q_head][q_token][k_token], C-order flatten\n")
        f.write(f"before={portable_path(before_path, repo_root)}\n")
        f.write(f"after={portable_path(after_path, repo_root)}\n")

    print(f"PASS: wrote {raw_path}")
    print(f"PASS: wrote {golden_path}")
    print(f"PASS: wrote {meta_path}")
    print(f"shape=[{q_heads}, {seq_len}, {seq_len}], elements={elements}")
    print("mask_value_bf16=FF80")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
