#!/usr/bin/env python3
"""Prepare portable BF16 RoPE vectors from the committed FPGA golden slice.

The generated files are consumed by RoPE/tb_rope_qk_file.sv.  Q, K and the
golden outputs use C-order flattening of [head][token][dimension].  Sin/cos
use C-order flattening of [token][pair_dimension].
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np


def fp32_to_bf16_rne(values: np.ndarray) -> np.ndarray:
    """Return BF16 raw words using IEEE round-to-nearest-even."""
    fp32 = np.asarray(values, dtype=np.float32)
    bits = fp32.view(np.uint32)
    lsb = (bits >> np.uint32(16)) & np.uint32(1)
    return ((bits + np.uint32(0x7FFF) + lsb) >> np.uint32(16)).astype(np.uint16)


def write_hex(path: Path, words: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii", newline="\n") as handle:
        for value in np.asarray(words, dtype=np.uint16).reshape(-1):
            handle.write(f"{int(value):04X}\n")


def read_hex_prefix(path: Path, count: int) -> np.ndarray:
    words: list[int] = []
    with path.open("r", encoding="ascii") as handle:
        for line_number, line in enumerate(handle, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                words.append(int(stripped, 16))
            except ValueError as exc:
                raise ValueError(f"{path}:{line_number}: invalid hex word {stripped!r}") from exc
            if len(words) == count:
                break
    if len(words) != count:
        raise ValueError(f"{path} contains {len(words)} usable words; expected at least {count}")
    return np.asarray(words, dtype=np.uint16)


def portable_path(path: Path, repo_root: Path) -> str:
    """Keep metadata valid after the repository is copied to another machine."""
    try:
        return path.resolve().relative_to(repo_root.resolve()).as_posix()
    except ValueError:
        return path.resolve().as_posix()


def load_tensor(path: Path, name: str) -> np.ndarray:
    tensor = np.load(path)
    if tensor.dtype != np.float32:
        raise ValueError(f"{name} must use float32 storage, got {tensor.dtype}: {path}")
    if tensor.ndim != 3:
        raise ValueError(f"{name} must have layout [head][token][dim], got {tensor.shape}: {path}")
    if not np.isfinite(tensor).all():
        raise ValueError(f"{name} must be finite: {path}")
    return tensor


def parse_args() -> argparse.Namespace:
    rope_dir = Path(__file__).resolve().parents[1]
    repo_root = rope_dir.parent
    golden_dir = repo_root / "golden_model_outputs" / "fpga_slice"

    parser = argparse.ArgumentParser(description="Create RoPE BF16 test vectors from fpga_slice golden tensors.")
    parser.add_argument("--golden-dir", type=Path, default=golden_dir)
    parser.add_argument("--sin-source", type=Path, default=rope_dir / "sin_bf16_all.hex")
    parser.add_argument("--cos-source", type=Path, default=rope_dir / "cos_bf16_all.hex")
    parser.add_argument("--out-dir", type=Path, default=rope_dir / "data")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    repo_root = Path(__file__).resolve().parents[2]
    golden_dir = args.golden_dir.resolve()
    out_dir = args.out_dir.resolve()

    q_before = load_tensor(golden_dir / "q_before_rope.npy", "q_before_rope")
    k_before = load_tensor(golden_dir / "k_before_rope.npy", "k_before_rope")
    q_after = load_tensor(golden_dir / "q_after_rope.npy", "q_after_rope")
    k_after = load_tensor(golden_dir / "k_after_rope.npy", "k_after_rope")

    if q_before.shape != q_after.shape:
        raise ValueError(f"Q shape mismatch: before={q_before.shape}, after={q_after.shape}")
    if k_before.shape != k_after.shape:
        raise ValueError(f"K shape mismatch: before={k_before.shape}, after={k_after.shape}")
    if q_before.shape[1:] != k_before.shape[1:]:
        raise ValueError(f"Q/K token-dimension mismatch: Q={q_before.shape}, K={k_before.shape}")

    q_heads, seq_len, head_dim = q_before.shape
    k_heads, _, _ = k_before.shape
    if head_dim % 2:
        raise ValueError(f"head_dim must be even, got {head_dim}")
    half_dim = head_dim // 2
    table_words = seq_len * half_dim

    # The committed all-position ROM is ordered [token][pair_dimension].
    # The FPGA slice always starts at token 0, so its prefix is sufficient.
    sin_words = read_hex_prefix(args.sin_source.resolve(), table_words)
    cos_words = read_hex_prefix(args.cos_source.resolve(), table_words)

    files = {
        "q_before_rope_bf16.hex": fp32_to_bf16_rne(q_before),
        "k_before_rope_bf16.hex": fp32_to_bf16_rne(k_before),
        "q_after_rope_golden_bf16.hex": fp32_to_bf16_rne(q_after),
        "k_after_rope_golden_bf16.hex": fp32_to_bf16_rne(k_after),
        "sin_bf16.hex": sin_words,
        "cos_bf16.hex": cos_words,
    }
    for name, words in files.items():
        write_hex(out_dir / name, words)

    with (out_dir / "meta.txt").open("w", encoding="ascii", newline="\n") as handle:
        handle.write("source=golden_model_outputs/fpga_slice\n")
        handle.write(f"q_heads={q_heads}\n")
        handle.write(f"k_heads={k_heads}\n")
        handle.write(f"seq_len={seq_len}\n")
        handle.write(f"head_dim={head_dim}\n")
        handle.write(f"half_dim={half_dim}\n")
        handle.write("dtype=BF16 raw 16-bit word, round-to-nearest-even\n")
        handle.write("qk_layout=[head][token][dimension], C-order flatten\n")
        handle.write("sincos_layout=[token][pair_dimension], C-order flatten\n")
        handle.write(f"sin_source={portable_path(args.sin_source, repo_root)}\n")
        handle.write(f"cos_source={portable_path(args.cos_source, repo_root)}\n")

    print("PASS: RoPE vectors prepared")
    print(f"  golden_dir={golden_dir}")
    print(f"  out_dir={out_dir}")
    print(f"  Q shape={q_before.shape}, K shape={k_before.shape}, sin/cos words={table_words}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
