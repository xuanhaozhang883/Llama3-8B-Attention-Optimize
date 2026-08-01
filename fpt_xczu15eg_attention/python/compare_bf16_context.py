#!/usr/bin/env python3
"""Compare two BF16 hex streams using the project's correctness contract."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("expected", type=Path)
    parser.add_argument("actual", type=Path)
    parser.add_argument("--abs-tol", type=float, default=1e-4)
    parser.add_argument("--max-ulp", type=int, default=1)
    parser.add_argument("--json", type=Path)
    return parser.parse_args()


def read_words(path: Path) -> np.ndarray:
    values = np.fromiter(
        (int(item, 16) for item in path.read_text(encoding="ascii").split()),
        dtype=np.uint16,
    )
    if values.size == 0:
        raise ValueError(f"empty BF16 file: {path}")
    return values


def bf16_to_f32(words: np.ndarray) -> np.ndarray:
    return (words.astype(np.uint32) << 16).view(np.float32)


def ordered_key(words: np.ndarray) -> np.ndarray:
    values = words.astype(np.uint32)
    negative = (values & 0x8000) != 0
    return np.where(negative, (~values) & 0xFFFF, values ^ 0x8000).astype(np.int32)


def main() -> int:
    args = parse_args()
    expected = read_words(args.expected)
    actual = read_words(args.actual)
    if expected.size != actual.size:
        raise SystemExit(
            f"[FAIL] word-count mismatch: expected={expected.size}, actual={actual.size}"
        )

    expected_f32 = bf16_to_f32(expected)
    actual_f32 = bf16_to_f32(actual)
    abs_error = np.abs(expected_f32 - actual_f32)
    ulp = np.abs(ordered_key(expected) - ordered_key(actual))
    both_zero = ((expected & 0x7FFF) == 0) & ((actual & 0x7FFF) == 0)
    ulp[both_zero] = 0
    finite = np.isfinite(expected_f32) & np.isfinite(actual_f32)
    passes = finite & ((abs_error <= args.abs_tol) | (ulp <= args.max_ulp))
    exact = expected == actual
    failing = np.flatnonzero(~passes)
    result = {
        "words": int(expected.size),
        "exact_mismatches": int(np.count_nonzero(~exact)),
        "combined_failures": int(failing.size),
        "max_abs_error": float(np.max(abs_error[finite])) if np.any(finite) else None,
        "max_ulp": int(np.max(ulp)),
        "abs_tolerance": args.abs_tol,
        "max_allowed_ulp": args.max_ulp,
        "first_failure_indices": [int(index) for index in failing[:32]],
    }
    print(json.dumps(result, indent=2))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 0 if failing.size == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
