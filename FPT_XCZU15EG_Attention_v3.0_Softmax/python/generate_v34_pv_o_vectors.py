#!/usr/bin/env python3
"""Generate deterministic, bit-exact vectors for FlashAttention Stage 3A."""

from __future__ import annotations

import argparse
import math
import random
import struct
from dataclasses import dataclass
from pathlib import Path


TILE = 4
V_LANES = 8
EXP_W = 24
EXP_FRAC = 23
V_FIXED_W = 18
V_FRAC = 11
O_ACC_W = 40
O_FRAC = 19

V_MIN = -(1 << (V_FIXED_W - 1))
V_MAX = (1 << (V_FIXED_W - 1)) - 1
O_MIN = -(1 << (O_ACC_W - 1))
O_MAX = (1 << (O_ACC_W - 1)) - 1


@dataclass(frozen=True)
class Case:
    case_id: int
    new_valid: int
    old_valid: int
    alpha: int
    weights: int
    v_bf16: int
    old_o: int
    expected_valid: int
    expected_o: int
    expected_error: int


def pack_lanes(values: list[int], width: int) -> int:
    packed = 0
    mask = (1 << width) - 1
    for lane, value in enumerate(values):
        packed |= (value & mask) << (lane * width)
    return packed


def signed_to_bits(value: int, width: int) -> int:
    return value & ((1 << width) - 1)


def float_to_bf16(value: float) -> int:
    bits = struct.unpack(">I", struct.pack(">f", float(value)))[0]
    exponent = (bits >> 23) & 0xFF
    fraction = bits & 0x7FFFFF
    if exponent == 0xFF and fraction != 0:
        result = bits >> 16
        return result | int((result & 0x7F) == 0)
    rounding_bias = 0x7FFF + ((bits >> 16) & 1)
    return ((bits + rounding_bias) >> 16) & 0xFFFF


def bf16_to_float(value: int) -> float:
    bits = (value & 0xFFFF) << 16
    return struct.unpack(">f", struct.pack(">I", bits))[0]


def bf16_to_fixed(value: int) -> tuple[int, int]:
    sign = (value >> 15) & 1
    exponent = (value >> 7) & 0xFF
    fraction = value & 0x7F

    if exponent == 0:
        return 0, 0
    if exponent == 0xFF:
        return (V_MIN if sign else V_MAX), 1

    significand = 0x80 | fraction
    shift = exponent - (134 - V_FRAC)
    if shift >= 0:
        magnitude = ((1 << (V_FIXED_W + 1)) - 1) if shift >= V_FIXED_W else significand << shift
    else:
        right_shift = -shift
        if right_shift > 8:
            magnitude = 0
        else:
            quotient = significand >> right_shift
            remainder = significand & ((1 << right_shift) - 1)
            half = 1 << (right_shift - 1)
            magnitude = quotient + int(
                remainder > half or (remainder == half and (quotient & 1))
            )

    if not sign and magnitude > V_MAX:
        return V_MAX, 1
    if sign and magnitude > -V_MIN:
        return V_MIN, 1
    return (-magnitude if sign else magnitude), 0


def round_shift_rne(value: int, shift: int) -> int:
    if shift <= 0:
        return value << (-shift)
    negative = value < 0
    magnitude = -value if negative else value
    quotient = magnitude >> shift
    remainder = magnitude & ((1 << shift) - 1)
    half = 1 << (shift - 1)
    quotient += int(
        remainder > half or (remainder == half and (quotient & 1))
    )
    return -quotient if negative else quotient


def saturate_o(value: int) -> tuple[int, int]:
    if value > O_MAX:
        return O_MAX, 1
    if value < O_MIN:
        return O_MIN, 1
    return value, 0


def quantize_q23(value: float) -> int:
    scaled = round(value * (1 << EXP_FRAC))
    return max(0, min((1 << EXP_W) - 1, scaled))


def quantize_o(value: float) -> int:
    return max(O_MIN, min(O_MAX, round(value * (1 << O_FRAC))))


def model_update(
    new_valid: list[int],
    old_valid: list[int],
    alpha: list[int],
    weights: list[int],
    v_bf16: list[int],
    old_o: list[int],
) -> tuple[list[int], list[int]]:
    v_fixed: list[int] = []
    v_error: list[int] = []
    for value in v_bf16:
        converted, error = bf16_to_fixed(value)
        v_fixed.append(converted)
        v_error.append(error)

    output = [0] * (TILE * V_LANES)
    errors = [0] * TILE
    for row in range(TILE):
        if old_valid[row] and not new_valid[row]:
            errors[row] = 1
        for feature in range(V_LANES):
            index = row * V_LANES + feature
            if not old_valid[row] and old_o[index] != 0:
                errors[row] = 1

            if not new_valid[row]:
                output[index] = 0
                continue

            old_value = old_o[index] if old_valid[row] else 0
            alpha_product = round_shift_rne(
                alpha[row] * old_value, EXP_FRAC
            )
            accumulator, saturated = saturate_o(alpha_product)
            errors[row] |= saturated

            for key in range(TILE):
                v_index = key * V_LANES + feature
                product = weights[row * TILE + key] * v_fixed[v_index]
                product = round_shift_rne(
                    product, EXP_FRAC + V_FRAC - O_FRAC
                )
                product, product_saturated = saturate_o(product)
                accumulator, add_saturated = saturate_o(
                    accumulator + product
                )
                errors[row] |= (
                    v_error[v_index] | product_saturated | add_saturated
                )
            output[index] = accumulator
    return output, errors


def make_case(
    case_id: int,
    new_valid: list[int],
    old_valid: list[int],
    alpha: list[int],
    weights: list[int],
    v_bf16: list[int],
    old_o: list[int],
) -> tuple[Case, list[int]]:
    expected_o, expected_error = model_update(
        new_valid, old_valid, alpha, weights, v_bf16, old_o
    )
    case = Case(
        case_id=case_id,
        new_valid=pack_lanes(new_valid, 1),
        old_valid=pack_lanes(old_valid, 1),
        alpha=pack_lanes(alpha, EXP_W),
        weights=pack_lanes(weights, EXP_W),
        v_bf16=pack_lanes(v_bf16, 16),
        old_o=pack_lanes(
            [signed_to_bits(value, O_ACC_W) for value in old_o], O_ACC_W
        ),
        expected_valid=pack_lanes(new_valid, 1),
        expected_o=pack_lanes(
            [signed_to_bits(value, O_ACC_W) for value in expected_o],
            O_ACC_W,
        ),
        expected_error=pack_lanes(expected_error, 1),
    )
    return case, expected_o


def random_v_tile(rng: random.Random) -> list[int]:
    pool = [
        -63.5,
        -16.0,
        -8.0,
        -2.0,
        -1.0,
        -0.125,
        0.0,
        0.125,
        0.5,
        1.0,
        2.0,
        8.0,
        16.0,
        63.5,
    ]
    values = []
    for _ in range(TILE * V_LANES):
        value = rng.choice(pool) if rng.random() < 0.35 else rng.uniform(-12, 12)
        values.append(float_to_bf16(value))
    return values


def random_weight(rng: random.Random) -> int:
    delta = rng.uniform(0.0, 16.0)
    return quantize_q23(math.exp(-delta))


def generate_cases() -> list[Case]:
    rng = random.Random(0x34FA2026)
    cases: list[Case] = []

    # Stateful groups exercise first-tile initialization and repeated online
    # rescaling. Each result is fed back as the next tile's old O numerator.
    for group in range(16):
        old_valid = [0] * TILE
        old_o = [0] * (TILE * V_LANES)
        for step in range(8):
            new_valid = old_valid.copy()
            alpha = [0] * TILE
            weights = [0] * (TILE * TILE)

            for row in range(TILE):
                row_becomes_valid = not old_valid[row] and (
                    (group + step + row) % 3 != 0 or step >= 3
                )
                if row_becomes_valid:
                    new_valid[row] = 1

                fully_masked = ((group * 7 + step * 3 + row) % 11 == 0)
                if not new_valid[row]:
                    continue
                if old_valid[row]:
                    alpha[row] = (1 << EXP_FRAC) if fully_masked else random_weight(rng)
                if not fully_masked:
                    for key in range(TILE):
                        weights[row * TILE + key] = random_weight(rng)

            v_bf16 = random_v_tile(rng)
            case, expected_o = make_case(
                len(cases), new_valid, old_valid, alpha, weights, v_bf16, old_o
            )
            cases.append(case)
            old_valid = new_valid
            old_o = expected_o

    # Directed protocol and numerical corner cases.
    directed: list[tuple[list[int], list[int], list[int], list[int], list[int], list[int]]] = []
    zero_w = [0] * (TILE * TILE)
    zero_o = [0] * (TILE * V_LANES)
    one = 1 << EXP_FRAC

    invalid_old_o = zero_o.copy()
    invalid_old_o[0] = quantize_o(1.0)
    directed.append(
        ([1, 0, 0, 0], [0, 0, 0, 0], [0] * TILE, zero_w.copy(),
         [float_to_bf16(0.0)] * (TILE * V_LANES), invalid_old_o)
    )

    directed.append(
        ([0, 1, 0, 0], [1, 1, 0, 0], [one] * TILE, zero_w.copy(),
         [float_to_bf16(0.0)] * (TILE * V_LANES),
         [quantize_o(0.5)] * (TILE * V_LANES))
    )

    exceptional_v = [float_to_bf16(0.0)] * (TILE * V_LANES)
    exceptional_v[0] = 0x7F80
    exceptional_v[V_LANES + 1] = 0xFF80
    exceptional_v[2 * V_LANES + 2] = 0x7FC1
    all_one_w = [one] * (TILE * TILE)
    directed.append(
        ([1] * TILE, [0] * TILE, [0] * TILE, all_one_w,
         exceptional_v, zero_o.copy())
    )

    saturated_old = [O_MAX] * (TILE * V_LANES)
    max_v = [float_to_bf16(63.5)] * (TILE * V_LANES)
    directed.append(
        ([1] * TILE, [1] * TILE, [(1 << EXP_W) - 1] * TILE,
         [(1 << EXP_W) - 1] * (TILE * TILE), max_v, saturated_old)
    )

    min_old = [O_MIN] * (TILE * V_LANES)
    min_v = [float_to_bf16(-63.5)] * (TILE * V_LANES)
    directed.append(
        ([1] * TILE, [1] * TILE, [(1 << EXP_W) - 1] * TILE,
         [(1 << EXP_W) - 1] * (TILE * TILE), min_v, min_old)
    )

    for values in directed:
        case, _ = make_case(len(cases), *values)
        cases.append(case)

    return cases


def write_cases(path: Path, cases: list[Case]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii", newline="\n") as output:
        for case in cases:
            output.write(
                f"{case.case_id:d} {case.new_valid:01x} {case.old_valid:01x} "
                f"{case.alpha:024x} {case.weights:096x} "
                f"{case.v_bf16:0128x} {case.old_o:0320x} "
                f"{case.expected_valid:01x} {case.expected_o:0320x} "
                f"{case.expected_error:01x}\n"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    cases = generate_cases()
    write_cases(args.output, cases)
    print(f"[PASS] generated {len(cases)} Stage 3A P/V/O vectors: {args.output}")


if __name__ == "__main__":
    main()
