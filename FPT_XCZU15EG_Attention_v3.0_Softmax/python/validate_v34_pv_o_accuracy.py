#!/usr/bin/env python3
"""Measure full-row Stage 3A fixed-point error against float attention."""

from __future__ import annotations

import argparse
import math
import random

from generate_v34_pv_o_vectors import (
    EXP_FRAC,
    O_FRAC,
    TILE,
    V_LANES,
    bf16_to_fixed,
    bf16_to_float,
    float_to_bf16,
    quantize_q23,
    round_shift_rne,
    saturate_o,
)


def run_row(
    scores: list[float], v_values: list[list[float]]
) -> tuple[list[float], list[float], int]:
    reference_max = max(scores)
    reference_weights = [math.exp(value - reference_max) for value in scores]
    reference_sum = sum(reference_weights)
    reference = [
        sum(
            reference_weights[key] * v_values[key][feature]
            for key in range(len(scores))
        )
        / reference_sum
        for feature in range(V_LANES)
    ]

    running_max: float | None = None
    running_l = 0
    running_o = [0] * V_LANES
    numeric_errors = 0

    for tile_base in range(0, len(scores), TILE):
        tile_scores = scores[tile_base : tile_base + TILE]
        tile_max = max(tile_scores)
        new_max = tile_max if running_max is None else max(running_max, tile_max)
        alpha_float = 0.0 if running_max is None else math.exp(running_max - new_max)
        alpha = quantize_q23(alpha_float)
        weights = [quantize_q23(math.exp(value - new_max)) for value in tile_scores]

        running_l = round_shift_rne(alpha * running_l, EXP_FRAC) + sum(weights)
        for feature in range(V_LANES):
            accumulator, error = saturate_o(
                round_shift_rne(alpha * running_o[feature], EXP_FRAC)
            )
            numeric_errors += error
            for key, weight in enumerate(weights):
                fixed_v, conversion_error = bf16_to_fixed(
                    float_to_bf16(v_values[tile_base + key][feature])
                )
                product = round_shift_rne(weight * fixed_v, 15)
                product, product_error = saturate_o(product)
                accumulator, add_error = saturate_o(accumulator + product)
                numeric_errors += conversion_error + product_error + add_error
            running_o[feature] = accumulator
        running_max = new_max

    denominator = running_l / float(1 << EXP_FRAC)
    result = [
        (value / float(1 << O_FRAC)) / denominator for value in running_o
    ]
    return reference, result, numeric_errors


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", type=int, default=4096)
    parser.add_argument("--max-seq", type=int, default=128)
    parser.add_argument("--max-abs-limit", type=float, default=7.5e-4)
    parser.add_argument("--mean-abs-limit", type=float, default=2.0e-5)
    args = parser.parse_args()

    if args.rows <= 0 or args.max_seq < TILE:
        raise SystemExit("rows must be positive and max-seq must be at least 4")

    rng = random.Random(0x34ACC026)
    absolute_errors: list[float] = []
    guarded_relative_errors: list[float] = []
    numeric_errors = 0

    for row in range(args.rows):
        visible = rng.randint(1, args.max_seq)
        visible = min(args.max_seq, ((visible + TILE - 1) // TILE) * TILE)
        scores = [
            bf16_to_float(float_to_bf16(rng.uniform(-12.0, 12.0)))
            for _ in range(visible)
        ]
        v_values = [
            [
                bf16_to_float(float_to_bf16(rng.uniform(-8.0, 8.0)))
                for _ in range(V_LANES)
            ]
            for _ in range(visible)
        ]
        reference, fixed_result, row_errors = run_row(scores, v_values)
        numeric_errors += row_errors
        for expected, actual in zip(reference, fixed_result):
            absolute = abs(expected - actual)
            absolute_errors.append(absolute)
            if abs(expected) >= 1.0e-2:
                guarded_relative_errors.append(absolute / abs(expected))

    mean_absolute = sum(absolute_errors) / len(absolute_errors)
    max_absolute = max(absolute_errors)
    max_relative = max(guarded_relative_errors, default=0.0)

    print("============================================================")
    print("V3.4 Stage 3A full-row numerical qualification")
    print(f"Rows                 : {args.rows}")
    print(f"Context components   : {len(absolute_errors)}")
    print(f"Mean absolute error  : {mean_absolute:.9e}")
    print(f"Max absolute error   : {max_absolute:.9e}")
    print(f"Max relative (>=.01): {max_relative:.9e}")
    print(f"Numeric saturations  : {numeric_errors}")
    print("============================================================")

    if numeric_errors != 0:
        raise SystemExit("[FAIL] unexpected saturation in nominal accuracy test")
    if mean_absolute > args.mean_abs_limit:
        raise SystemExit(
            f"[FAIL] mean absolute error exceeds {args.mean_abs_limit:.3e}"
        )
    if max_absolute > args.max_abs_limit:
        raise SystemExit(
            f"[FAIL] max absolute error exceeds {args.max_abs_limit:.3e}"
        )
    print("[PASS] V3.4 Stage 3A numerical accuracy is within budget")


if __name__ == "__main__":
    main()
