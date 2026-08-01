#!/usr/bin/env python3
"""Generate the deterministic S8/D8 Online-Softmax RTL unit vectors.

The model intentionally mirrors the RTL quantization points: scores are BF16,
exp/alpha are Q1.15 LUT values converted to BF16 before FP32 Context MACs,
the denominator stays integer Q1.15, and the final reciprocal is rounded to
BF16 before the last FP32 multiply.
"""

from __future__ import annotations

import math
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "tests" / "data"
SEQ = 8
DIM = 8
TILE = 4
SCORE_FRAC = 20


def f32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", value))[0]


def f32_bits(value: float) -> int:
    return struct.unpack("<I", struct.pack("<f", f32(value)))[0]


def bf16_bits(value: float) -> int:
    bits = f32_bits(value)
    upper = bits >> 16
    lower = bits & 0xFFFF
    if lower > 0x8000 or (lower == 0x8000 and (upper & 1)):
        upper = (upper + 1) & 0xFFFF
    return upper


def bf16_value(bits: int) -> float:
    return struct.unpack("<f", struct.pack("<I", bits << 16))[0]


def fixed_score(bits: int) -> int:
    value = bf16_value(bits)
    scaled = abs(value) * (1 << SCORE_FRAC)
    magnitude = int(math.floor(scaled + 0.5))
    return -magnitude if value < 0 else magnitude


def q15_to_bf16(value: int) -> int:
    return bf16_bits(value / float(1 << 15))


def uq30_to_bf16(value: int) -> int:
    return bf16_bits(value / float(1 << 30))


def write_hex(path: Path, values: list[int]) -> None:
    path.write_text("".join(f"{value:04X}\n" for value in values), encoding="ascii")


def main() -> None:
    lut = [int(line, 16) for line in (ROOT / "mem" / "exp_lut_q15.mem")
           .read_text(encoding="ascii").splitlines() if line.strip()]
    assert len(lut) == 513

    # Later key tiles deliberately contain larger maxima for rows 4..7, so
    # the regression exercises Context rescaling rather than only one block.
    scores = [[0.0 for _ in range(SEQ)] for _ in range(SEQ)]
    for row in range(SEQ):
        for col in range(SEQ):
            scores[row][col] = -1.5 + 0.25*row - 0.125*col
    scores[4][4] = 1.75
    scores[5][5] = 2.00
    scores[6][6] = 2.25
    scores[7][7] = 2.50

    values = [[0.0 for _ in range(DIM)] for _ in range(SEQ)]
    for key in range(SEQ):
        for dim in range(DIM):
            sign = -1.0 if ((key + dim) & 1) else 1.0
            values[key][dim] = sign * (0.0625*(key + 1) + 0.03125*dim)

    score_bits = [[bf16_bits(x) for x in row] for row in scores]
    value_bits = [[bf16_bits(x) for x in row] for row in values]

    score_stream: list[int] = []
    output_stream: list[int] = []

    for row_base in range(0, SEQ, TILE):
        running_max = [-(1 << 31)] * TILE
        running_sum = [0] * TILE
        initialized = [False] * TILE
        context = [[f32(0.0) for _ in range(DIM)] for _ in range(TILE)]

        for col_base in range(0, SEQ, TILE):
            tile_fixed = [[0] * TILE for _ in range(TILE)]
            mask = [[False] * TILE for _ in range(TILE)]
            for lr in range(TILE):
                for lc in range(TILE):
                    row = row_base + lr
                    col = col_base + lc
                    score_stream.append(score_bits[row][col])
                    tile_fixed[lr][lc] = fixed_score(score_bits[row][col])
                    mask[lr][lc] = col > row

            next_max = running_max[:]
            alpha = [0] * TILE
            weights = [[0] * TILE for _ in range(TILE)]
            for lr in range(TILE):
                valid = [tile_fixed[lr][lc] for lc in range(TILE)
                         if not mask[lr][lc]]
                if not valid:
                    alpha[lr] = 1 << 15 if initialized[lr] else 0
                    continue
                next_max[lr] = max(running_max[lr], max(valid)) if initialized[lr] else max(valid)
                if initialized[lr]:
                    delta = next_max[lr] - running_max[lr]
                    alpha[lr] = 0 if delta > (8 << SCORE_FRAC) else lut[(delta + (1 << 13)) >> 14]
                for lc in range(TILE):
                    if mask[lr][lc]:
                        continue
                    delta = next_max[lr] - tile_fixed[lr][lc]
                    weights[lr][lc] = 0 if delta > (8 << SCORE_FRAC) else lut[(delta + (1 << 13)) >> 14]

            for lr in range(TILE):
                if initialized[lr]:
                    a = bf16_value(q15_to_bf16(alpha[lr]))
                    for dim in range(DIM):
                        context[lr][dim] = f32(context[lr][dim] * a)
                scaled = (running_sum[lr] * alpha[lr] + (1 << 14)) >> 15
                running_sum[lr] = scaled + sum(weights[lr])
                if any(not x for x in mask[lr]):
                    running_max[lr] = next_max[lr]
                    initialized[lr] = True

            for lc in range(TILE):
                key = col_base + lc
                for lr in range(TILE):
                    w = bf16_value(q15_to_bf16(weights[lr][lc]))
                    for dim in range(DIM):
                        product = f32(w * bf16_value(value_bits[key][dim]))
                        context[lr][dim] = f32(context[lr][dim] + product)

        for feature_base in range(0, DIM, TILE):
            for lr in range(TILE):
                quotient = (1 << 45) // running_sum[lr]
                recip = bf16_value(uq30_to_bf16(quotient))
                for lc in range(TILE):
                    normalized = f32(context[lr][feature_base + lc] * recip)
                    output_stream.append(bf16_bits(normalized))

    OUT.mkdir(parents=True, exist_ok=True)
    write_hex(OUT / "v30_online_scores_s8.hex", score_stream)
    write_hex(OUT / "v30_online_v_s8.hex", [x for row in value_bits for x in row])
    write_hex(OUT / "v30_online_context_s8.hex", output_stream)
    print("V30_GOLDEN_GENERATED")
    print(f"scores={len(score_stream)} v={SEQ*DIM} context={len(output_stream)}")


if __name__ == "__main__":
    main()
