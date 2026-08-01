#!/usr/bin/env python3
"""Generate a full 8-GQA S128/D128 Golden matching the v3.0 RTL quantization.

This tool is deliberately output-explicit: it never writes into the project
unless the caller intentionally chooses a project path for --output.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path

import numpy as np


TILE = 4
SCORE_FRAC = 20


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--metadata", type=Path)
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_words(path: Path, count: int) -> np.ndarray:
    words = np.fromiter(
        (int(item, 16) for item in path.read_text(encoding="ascii").split()
         if item.strip()),
        dtype=np.uint16,
    )
    if words.size != count:
        raise ValueError(f"{path}: expected {count} words, got {words.size}")
    return words


def bf16_to_f32(words: np.ndarray) -> np.ndarray:
    return (np.asarray(words, dtype=np.uint32) << 16).view(np.float32)


def f32_to_bf16(values: np.ndarray) -> np.ndarray:
    bits = np.asarray(values, dtype=np.float32).view(np.uint32)
    upper = bits >> 16
    lower = bits & np.uint32(0xFFFF)
    increment = (lower > 0x8000) | ((lower == 0x8000) & ((upper & 1) != 0))
    return (upper + increment.astype(np.uint32)).astype(np.uint16)


def bf16_scalar(value: float) -> np.float32:
    return bf16_to_f32(f32_to_bf16(np.asarray([value], dtype=np.float32)))[0]


def fp32_from_bits(bits: int) -> np.float32:
    return np.float32(struct.unpack("<f", struct.pack("<I", bits))[0])


def rotate_bf16_split_half(
    words: np.ndarray, sin_words: np.ndarray, cos_words: np.ndarray
) -> np.ndarray:
    """Match RTL: x0=dim[pair], x1=dim[pair+HEAD_DIM/2]."""
    values = bf16_to_f32(words)
    half = values.shape[-1] // 2
    if values.shape[-1] % 2:
        raise ValueError("HEAD_DIM must be even for split-half RoPE")
    sin = bf16_to_f32(sin_words)[None, :, :]
    cos = bf16_to_f32(cos_words)[None, :, :]
    x0 = values[:, :, :half]
    x1 = values[:, :, half:]

    p0 = bf16_to_f32(f32_to_bf16(np.multiply(x0, cos, dtype=np.float32)))
    p1 = bf16_to_f32(f32_to_bf16(np.multiply(x1, sin, dtype=np.float32)))
    p2 = bf16_to_f32(f32_to_bf16(np.multiply(x0, sin, dtype=np.float32)))
    p3 = bf16_to_f32(f32_to_bf16(np.multiply(x1, cos, dtype=np.float32)))

    result = np.empty_like(words)
    result[:, :, :half] = f32_to_bf16(np.subtract(p0, p1, dtype=np.float32))
    result[:, :, half:] = f32_to_bf16(np.add(p2, p3, dtype=np.float32))
    return result


def score_fixed(words: np.ndarray) -> np.ndarray:
    values = bf16_to_f32(words).astype(np.float64)
    magnitude = np.floor(np.abs(values) * (1 << SCORE_FRAC) + 0.5)
    return np.where(values < 0, -magnitude, magnitude).astype(np.int64)


def q15_bf16(value: int) -> np.float32:
    return bf16_scalar(np.float32(value / float(1 << 15)))


def uq30_bf16(value: int) -> np.float32:
    return bf16_scalar(np.float32(value / float(1 << 30)))


def online_context(
    score_words: np.ndarray, v_words: np.ndarray, lut: np.ndarray
) -> tuple[np.ndarray, int]:
    seq, dim = score_words.shape
    scores = score_fixed(score_words)
    values = bf16_to_f32(v_words)
    output = np.zeros((seq, dim), dtype=np.float32)
    rescales = 0

    for row_base in range(0, seq, TILE):
        running_max = np.full(TILE, -(1 << 31), dtype=np.int64)
        running_sum = np.zeros(TILE, dtype=np.int64)
        initialized = np.zeros(TILE, dtype=np.bool_)
        context = np.zeros((TILE, dim), dtype=np.float32)

        for col_base in range(0, seq, TILE):
            tile = scores[row_base:row_base + TILE, col_base:col_base + TILE]
            rows = np.arange(row_base, row_base + TILE)[:, None]
            cols = np.arange(col_base, col_base + TILE)[None, :]
            mask = cols > rows
            row_valid = np.any(~mask, axis=1)
            next_max = running_max.copy()
            alpha = np.zeros(TILE, dtype=np.int64)
            weights = np.zeros((TILE, TILE), dtype=np.int64)

            for local_row in range(TILE):
                if not row_valid[local_row]:
                    alpha[local_row] = (1 << 15) if initialized[local_row] else 0
                    continue
                candidate = int(np.max(tile[local_row, ~mask[local_row]]))
                next_max[local_row] = (
                    max(int(running_max[local_row]), candidate)
                    if initialized[local_row] else candidate
                )
                if initialized[local_row]:
                    delta = int(next_max[local_row] - running_max[local_row])
                    alpha[local_row] = (
                        0 if delta > (8 << SCORE_FRAC)
                        else int(lut[(delta + (1 << 13)) >> 14])
                    )
                    rescales += int(delta > 0)
                for local_col in range(TILE):
                    if not mask[local_row, local_col]:
                        delta = int(next_max[local_row] - tile[local_row, local_col])
                        weights[local_row, local_col] = (
                            0 if delta > (8 << SCORE_FRAC)
                            else int(lut[(delta + (1 << 13)) >> 14])
                        )

            for local_row in range(TILE):
                if initialized[local_row]:
                    context[local_row] = np.multiply(
                        context[local_row], q15_bf16(int(alpha[local_row])),
                        dtype=np.float32,
                    )
                running_sum[local_row] = (
                    (int(running_sum[local_row]) * int(alpha[local_row]) + (1 << 14)) >> 15
                ) + int(np.sum(weights[local_row]))
                if row_valid[local_row]:
                    running_max[local_row] = next_max[local_row]
                    initialized[local_row] = True

            for local_col in range(TILE):
                key = col_base + local_col
                for local_row in range(TILE):
                    product = np.multiply(
                        q15_bf16(int(weights[local_row, local_col])),
                        values[key],
                        dtype=np.float32,
                    )
                    context[local_row] = np.add(
                        context[local_row], product, dtype=np.float32
                    )

        for local_row in range(TILE):
            denominator = int(running_sum[local_row])
            if denominator == 0:
                raise ArithmeticError(f"zero online denominator at row {row_base + local_row}")
            reciprocal = uq30_bf16((1 << 45) // denominator)
            output[row_base + local_row] = np.multiply(
                context[local_row], reciprocal, dtype=np.float32
            )

    return f32_to_bf16(output), rescales


def write_hex(path: Path, words: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "".join(f"{int(value):04X}\n" for value in words.reshape(-1)),
        encoding="ascii",
    )


def main() -> int:
    args = parse_args()
    root = args.project_root.resolve()
    data = root / "vitis/data"
    cfg = json.loads((root / "project_config.json").read_text(encoding="utf-8"))
    groups = int(cfg["run_groups"])
    q_heads = int(cfg["q_heads"])
    kv_heads = int(cfg["kv_heads"])
    seq = int(cfg["seq_len"])
    dim = int(cfg["head_dim"])
    if (groups, q_heads, kv_heads, seq, dim) != (8, 32, 8, 128, 128):
        raise ValueError("this baseline tool requires 8 GQA, 32Q/8KV, S128/D128")
    if q_heads % groups != 0 or kv_heads != groups:
        raise ValueError("expected four Q heads and one KV head per GQA group")

    inputs = {
        "q": data / "q_before_rope_bf16.hex",
        "k": data / "k_before_rope_bf16.hex",
        "v": data / "v_bf16.hex",
        "sin": root / "mem/sin_bf16.hex",
        "cos": root / "mem/cos_bf16.hex",
        "lut": root / "mem/exp_lut_q15.mem",
    }
    q = read_words(inputs["q"], q_heads * seq * dim).reshape(q_heads, seq, dim)
    k = read_words(inputs["k"], kv_heads * seq * dim).reshape(kv_heads, seq, dim)
    v = read_words(inputs["v"], kv_heads * seq * dim).reshape(kv_heads, seq, dim)
    sin = read_words(inputs["sin"], seq * dim // 2).reshape(seq, dim // 2)
    cos = read_words(inputs["cos"], seq * dim // 2).reshape(seq, dim // 2)
    lut = np.asarray(
        [int(item, 16) for item in inputs["lut"].read_text(encoding="ascii").split()],
        dtype=np.int64,
    )
    if lut.size != 513:
        raise ValueError(f"exp LUT must contain 513 entries, got {lut.size}")

    q_rot = rotate_bf16_split_half(q, sin, cos)
    k_rot = rotate_bf16_split_half(k, sin, cos)
    scale = fp32_from_bits(0x3DB504F3)
    output = np.empty_like(q)
    total_rescales = 0

    for head in range(q_heads):
        group = head // (q_heads // groups)
        qf = bf16_to_f32(q_rot[head])
        kf = bf16_to_f32(k_rot[group])
        accum = np.zeros((seq, seq), dtype=np.float32)
        for reduce_index in range(dim):
            product = np.multiply(
                qf[:, reduce_index, None], kf[None, :, reduce_index],
                dtype=np.float32,
            )
            accum = np.add(accum, product, dtype=np.float32)
        scores = f32_to_bf16(np.multiply(accum, scale, dtype=np.float32))
        output[head], head_rescales = online_context(scores, v[group], lut)
        total_rescales += head_rescales
        print(f"head {head + 1:02d}/{q_heads} complete; rescales={head_rescales}")

    output_path = args.output.resolve()
    write_hex(output_path, output)
    metadata_path = (
        args.metadata.resolve() if args.metadata
        else output_path.with_suffix(output_path.suffix + ".json")
    )
    metadata = {
        "version": "v3.0-online-fused-preopt-golden-v1",
        "scope": {"groups": groups, "q_heads": q_heads, "kv_heads": kv_heads,
                  "seq_len": seq, "head_dim": dim, "tile": TILE},
        "rope_pairing": "split-half: x0=dim[pair], x1=dim[pair+HEAD_DIM/2]",
        "context_words": int(output.size),
        "online_rescale_events": int(total_rescales),
        "input_sha256": {name: sha256(path) for name, path in inputs.items()},
        "output_sha256": sha256(output_path),
    }
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(f"[PASS] wrote {output_path}")
    print(f"[PASS] wrote {metadata_path}")
    print(f"context_words={output.size} rescale_events={total_rescales}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
