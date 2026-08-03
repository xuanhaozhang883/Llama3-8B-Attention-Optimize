#!/usr/bin/env python3
"""Compare tiled online l accumulation with the full-row LUT denominator."""

from __future__ import annotations

import argparse
import math
import random
from pathlib import Path

from generate_v32_online_row_vectors import (
    TILE_COLS,
    bf16_to_fixed,
    exp_q23,
    float_to_bf16,
    model_update,
    read_lut,
)


def make_row(rng: random.Random, row_index: int, length: int) -> list[int]:
    pattern = row_index % 5
    if pattern == 0:
        values = [rng.uniform(-12.0, 12.0) for _ in range(length)]
    elif pattern == 1:
        values = [max(-16.0, min(16.0, rng.gauss(0.0, 4.0)))
                  for _ in range(length)]
    elif pattern == 2:
        start = rng.uniform(-12.0, -4.0)
        step = rng.uniform(0.05, 0.30)
        values = [min(16.0, start + step * index)
                  for index in range(length)]
    elif pattern == 3:
        start = rng.uniform(4.0, 12.0)
        step = rng.uniform(0.05, 0.30)
        values = [max(-16.0, start - step * index)
                  for index in range(length)]
    else:
        center = rng.uniform(-4.0, 4.0)
        values = [center + rng.uniform(-0.25, 0.25)
                  for _ in range(length)]
    return [float_to_bf16(value) for value in values]


def full_row_denominator(scores: list[int], valid_length: int,
                         lut: list[int]) -> tuple[int, int]:
    fixed_scores = [bf16_to_fixed(value) for value in scores[:valid_length]]
    maximum = max(fixed_scores)
    denominator = sum(exp_q23(maximum - value, lut)
                      for value in fixed_scores)
    return maximum, denominator


def exact_row_denominator(scores: list[int], valid_length: int) -> int:
    fixed_scores = [bf16_to_fixed(value) for value in scores[:valid_length]]
    maximum = max(fixed_scores)
    value = sum(
        math.exp((score - maximum) / float(1 << 14))
        for score in fixed_scores
    )
    return round(value * (1 << 23))


def online_denominator(scores: list[int], valid_length: int,
                       lut: list[int]) -> tuple[int, int]:
    state_valid = 0
    maximum = 0
    denominator = 0
    padded = scores + [float_to_bf16(0.0)] * ((-len(scores)) % TILE_COLS)

    for base in range(0, len(padded), TILE_COLS):
        tile = padded[base:base + TILE_COLS]
        mask = 0
        for lane in range(TILE_COLS):
            if base + lane >= valid_length:
                mask |= 1 << lane
        result = model_update(
            tile, mask, state_valid, maximum, denominator, lut
        )
        state_valid, maximum, denominator = result[0], result[1], result[2]
        if result[7]:
            raise AssertionError("unexpected online accumulator overflow")
    return maximum, denominator


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lut", required=True, type=Path)
    parser.add_argument("--rows", type=int, default=4096)
    parser.add_argument("--max-relative-error", type=float, default=0.00001)
    args = parser.parse_args()

    if args.rows < 1:
        raise ValueError("--rows must be >= 1")

    lut = read_lut(args.lut)
    rng = random.Random(0x32FA128)
    maximum_absolute_error = 0
    maximum_relative_error = 0.0
    maximum_math_relative_error = 0.0
    relative_error_sum = 0.0
    math_relative_error_sum = 0.0
    worst_case = None

    for row_index in range(args.rows):
        valid_length = 1 + rng.randrange(128)
        scores = make_row(rng, row_index, 128)
        full_m, full_l = full_row_denominator(scores, valid_length, lut)
        exact_l = exact_row_denominator(scores, valid_length)
        online_m, online_l = online_denominator(scores, valid_length, lut)

        if online_m != full_m:
            raise AssertionError(
                f"row {row_index}: online m {online_m} != full-row m {full_m}"
            )
        absolute_error = abs(online_l - full_l)
        relative_error = absolute_error / full_l
        relative_error_sum += relative_error
        math_relative_error = abs(online_l - exact_l) / exact_l
        math_relative_error_sum += math_relative_error
        maximum_math_relative_error = max(
            maximum_math_relative_error, math_relative_error
        )
        maximum_absolute_error = max(maximum_absolute_error, absolute_error)
        if relative_error > maximum_relative_error:
            maximum_relative_error = relative_error
            worst_case = (
                row_index,
                valid_length,
                full_l,
                online_l,
                absolute_error,
            )

    mean_relative_error = relative_error_sum / args.rows
    mean_math_relative_error = math_relative_error_sum / args.rows
    print("============================================================")
    print("V3.2 online denominator accuracy")
    print(f"rows                  : {args.rows}")
    print(f"max absolute Q23 error: {maximum_absolute_error}")
    print(f"max tiled/full error  : {maximum_relative_error:.8%}")
    print(f"mean tiled/full error : {mean_relative_error:.8%}")
    print(f"max error vs math     : {maximum_math_relative_error:.8%}")
    print(f"mean error vs math    : {mean_math_relative_error:.8%}")
    print(f"worst case            : {worst_case}")
    print("============================================================")

    checked_error = max(maximum_relative_error, maximum_math_relative_error)
    if checked_error > args.max_relative_error:
        raise SystemExit(
            f"[FAIL] max relative error {checked_error:.8%} exceeds "
            f"{args.max_relative_error:.8%}"
        )
    print("[PASS] V3.2 online denominator accuracy")


if __name__ == "__main__":
    main()
