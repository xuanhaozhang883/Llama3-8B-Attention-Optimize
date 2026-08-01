#!/usr/bin/env python3
"""Generate the full S128/D128 v3.0 online-fused board Golden."""

from __future__ import annotations

import struct
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "vitis" / "data"
SEQ, DIM, TILE, GROUPS, Q_PER_GROUP = 128, 128, 4, 8, 4
SCORE_FRAC = 20


def read_words(path: Path, count: int) -> np.ndarray:
    words = np.fromiter(
        (int(x, 16) for x in path.read_text(encoding="ascii").splitlines()
         if x.strip()), dtype=np.uint16, count=count)
    if words.size != count:
        raise ValueError(f"{path}: expected {count} words, got {words.size}")
    return words


def bf16_to_f32(words: np.ndarray) -> np.ndarray:
    return (words.astype(np.uint32) << 16).view(np.float32)


def f32_to_bf16(values: np.ndarray) -> np.ndarray:
    bits = np.asarray(values, dtype=np.float32).view(np.uint32)
    upper, lower = bits >> 16, bits & np.uint32(0xFFFF)
    up = (lower > 0x8000) | ((lower == 0x8000) & ((upper & 1) != 0))
    return (upper + up.astype(np.uint32)).astype(np.uint16)


def bf16_scalar(value: float) -> np.float32:
    return bf16_to_f32(f32_to_bf16(np.asarray([value], np.float32)))[0]


def fp32_from_bits(bits: int) -> np.float32:
    return np.float32(struct.unpack("<f", struct.pack("<I", bits))[0])


def rotate_bf16(x_words: np.ndarray, sin_words: np.ndarray,
                cos_words: np.ndarray) -> np.ndarray:
    x = bf16_to_f32(x_words)
    sin, cos = bf16_to_f32(sin_words)[None], bf16_to_f32(cos_words)[None]
    x0, x1 = x[:, :, 0::2], x[:, :, 1::2]
    p0 = bf16_to_f32(f32_to_bf16(np.multiply(x0, cos, dtype=np.float32)))
    p1 = bf16_to_f32(f32_to_bf16(np.multiply(x1, sin, dtype=np.float32)))
    p2 = bf16_to_f32(f32_to_bf16(np.multiply(x0, sin, dtype=np.float32)))
    p3 = bf16_to_f32(f32_to_bf16(np.multiply(x1, cos, dtype=np.float32)))
    result = np.empty_like(x_words)
    result[:, :, 0::2] = f32_to_bf16(np.subtract(p0, p1, dtype=np.float32))
    result[:, :, 1::2] = f32_to_bf16(np.add(p2, p3, dtype=np.float32))
    return result


def score_fixed(words: np.ndarray) -> np.ndarray:
    values = bf16_to_f32(words).astype(np.float64)
    magnitude = np.floor(np.abs(values) * (1 << SCORE_FRAC) + 0.5)
    return np.where(values < 0, -magnitude, magnitude).astype(np.int64)


def q15_bf16(value: int) -> np.float32:
    return bf16_scalar(np.float32(value / float(1 << 15)))


def uq30_bf16(value: int) -> np.float32:
    return bf16_scalar(np.float32(value / float(1 << 30)))


def online_context(score_words: np.ndarray, v_words: np.ndarray,
                   lut: np.ndarray) -> tuple[np.ndarray, int]:
    scores, values = score_fixed(score_words), bf16_to_f32(v_words)
    output = np.zeros((SEQ, DIM), dtype=np.float32)
    rescales = 0
    for rb in range(0, SEQ, TILE):
        running_max = np.full(TILE, -(1 << 31), dtype=np.int64)
        running_sum = np.zeros(TILE, dtype=np.int64)
        initialized = np.zeros(TILE, dtype=np.bool_)
        context = np.zeros((TILE, DIM), dtype=np.float32)
        for cb in range(0, SEQ, TILE):
            tile = scores[rb:rb + TILE, cb:cb + TILE]
            rows = np.arange(rb, rb + TILE)[:, None]
            cols = np.arange(cb, cb + TILE)[None, :]
            mask = cols > rows
            row_valid = np.any(~mask, axis=1)
            next_max = running_max.copy()
            alpha = np.zeros(TILE, dtype=np.int64)
            weights = np.zeros((TILE, TILE), dtype=np.int64)
            for lr in range(TILE):
                if not row_valid[lr]:
                    alpha[lr] = 1 << 15 if initialized[lr] else 0
                    continue
                candidate = int(np.max(tile[lr, ~mask[lr]]))
                next_max[lr] = max(int(running_max[lr]), candidate) \
                    if initialized[lr] else candidate
                if initialized[lr]:
                    delta = int(next_max[lr] - running_max[lr])
                    alpha[lr] = 0 if delta > (8 << SCORE_FRAC) else \
                        int(lut[(delta + (1 << 13)) >> 14])
                    rescales += int(delta > 0)
                for lc in range(TILE):
                    if not mask[lr, lc]:
                        delta = int(next_max[lr] - tile[lr, lc])
                        weights[lr, lc] = 0 if delta > (8 << SCORE_FRAC) else \
                            int(lut[(delta + (1 << 13)) >> 14])
            for lr in range(TILE):
                if initialized[lr]:
                    context[lr] = np.multiply(
                        context[lr], q15_bf16(int(alpha[lr])),
                        dtype=np.float32)
                running_sum[lr] = (
                    (int(running_sum[lr]) * int(alpha[lr]) + (1 << 14)) >> 15
                ) + int(np.sum(weights[lr]))
                if row_valid[lr]:
                    running_max[lr], initialized[lr] = next_max[lr], True
            for lc in range(TILE):
                for lr in range(TILE):
                    product = np.multiply(q15_bf16(int(weights[lr, lc])),
                                          values[cb + lc], dtype=np.float32)
                    context[lr] = np.add(context[lr], product, dtype=np.float32)
        for lr in range(TILE):
            reciprocal = uq30_bf16((1 << 45) // int(running_sum[lr]))
            output[rb + lr] = np.multiply(context[lr], reciprocal,
                                          dtype=np.float32)
    return f32_to_bf16(output), rescales


def main() -> None:
    q = read_words(DATA / "q_before_rope_bf16.hex",
                   GROUPS * Q_PER_GROUP * SEQ * DIM).reshape(-1, SEQ, DIM)
    k = read_words(DATA / "k_before_rope_bf16.hex",
                   GROUPS * SEQ * DIM).reshape(GROUPS, SEQ, DIM)
    v = read_words(DATA / "v_bf16.hex",
                   GROUPS * SEQ * DIM).reshape(GROUPS, SEQ, DIM)
    sin = read_words(ROOT / "mem/sin_bf16.hex", SEQ * DIM // 2).reshape(SEQ, -1)
    cos = read_words(ROOT / "mem/cos_bf16.hex", SEQ * DIM // 2).reshape(SEQ, -1)
    lut = np.asarray([int(x, 16) for x in
                      (ROOT / "mem/exp_lut_q15.mem").read_text().splitlines()
                      if x.strip()], dtype=np.int64)
    q_rot, k_rot = rotate_bf16(q, sin, cos), rotate_bf16(k, sin, cos)
    scale = fp32_from_bits(0x3DB504F3)
    output = np.empty_like(q)
    total_rescales = 0
    for head in range(GROUPS * Q_PER_GROUP):
        group = head // Q_PER_GROUP
        qf, kf = bf16_to_f32(q_rot[head]), bf16_to_f32(k_rot[group])
        accum = np.zeros((SEQ, SEQ), dtype=np.float32)
        for dim in range(DIM):
            product = np.multiply(qf[:, dim, None], kf[None, :, dim],
                                  dtype=np.float32)
            accum = np.add(accum, product, dtype=np.float32)
        scores = f32_to_bf16(np.multiply(accum, scale, dtype=np.float32))
        output[head], count = online_context(scores, v[group], lut)
        total_rescales += count
        print(f"head {head + 1:02d}/32 complete, rescales={count}")
    path = DATA / "attn_out_online_fused_bf16.hex"
    path.write_text("".join(f"{int(x):04X}\n" for x in output.reshape(-1)),
                    encoding="ascii")
    legacy = read_words(DATA / "attn_out_per_head_bf16.hex", output.size)
    exact = int(np.count_nonzero(legacy != output.reshape(-1)))
    print(f"[PASS] wrote {path}")
    print(f"context_words={output.size} exact_delta_vs_legacy={exact}")
    print(f"online_rescale_events={total_rescales}")


if __name__ == "__main__":
    main()
