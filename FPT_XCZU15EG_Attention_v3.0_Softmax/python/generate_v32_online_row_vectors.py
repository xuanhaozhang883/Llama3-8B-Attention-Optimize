#!/usr/bin/env python3
"""Generate deterministic Stage 2A online-softmax RTL test vectors."""

from __future__ import annotations

import argparse
import math
import random
import struct
from pathlib import Path


TILE_COLS = 4
MAX_LEN = 128
SCORE_W = 24
SCORE_FRAC = 14
EXP_W = 24
EXP_FRAC = 23
L_SUM_W = EXP_W + math.ceil(math.log2(MAX_LEN + 1))
EXP_COARSE_SHIFT = SCORE_FRAC - 6
EXP_LIMIT_FIXED = 16 << SCORE_FRAC
EXP_ONE = 1 << EXP_FRAC


def float_to_bf16(value: float) -> int:
    bits = struct.unpack(">I", struct.pack(">f", float(value)))[0]
    rounding_bias = 0x7FFF + ((bits >> 16) & 1)
    return ((bits + rounding_bias) >> 16) & 0xFFFF


def bf16_to_fixed(value_bf16: int) -> int:
    sign_bit = (value_bf16 >> 15) & 1
    exponent = (value_bf16 >> 7) & 0xFF
    fraction = value_bf16 & 0x7F
    significand = 0x80 | fraction
    shift_bias = 134 - SCORE_FRAC
    sat_exp = shift_bias + SCORE_W - 8
    zero_exp = shift_bias - 9
    minimum = -(1 << (SCORE_W - 1))
    maximum = (1 << (SCORE_W - 1)) - 1

    if exponent == 0:
        return 0
    if exponent == 0xFF:
        if fraction != 0:
            return 0
        return minimum if sign_bit else maximum
    if exponent >= sat_exp:
        return minimum if sign_bit else maximum
    if exponent <= zero_exp:
        return 0

    if exponent >= shift_bias:
        magnitude = significand << (exponent - shift_bias)
    else:
        right_shift = shift_bias - exponent
        magnitude = (significand + (1 << (right_shift - 1))) >> right_shift
    return -magnitude if sign_bit else magnitude


def q15_to_bf16(q15_value: int) -> int:
    if q15_value == 0:
        return 0
    msb_index = q15_value.bit_length() - 1
    exponent_biased = msb_index + 112
    normalized = (q15_value << (15 - msb_index)) & 0xFFFFFFFF
    fraction7 = (normalized >> 8) & 0x7F
    round_bit = (normalized >> 7) & 1
    sticky_bit = 1 if (normalized & 0x7F) else 0
    rounded_fraction = fraction7
    if round_bit and (sticky_bit or (fraction7 & 1)):
        rounded_fraction += 1
    if rounded_fraction & 0x80:
        exponent_biased += 1
        return (exponent_biased & 0xFF) << 7
    return ((exponent_biased & 0xFF) << 7) | rounded_fraction


def q23_to_q15(q23_value: int) -> int:
    return min((q23_value + (1 << 7)) >> 8, 1 << 15)


def read_lut(path: Path) -> list[int]:
    words = []
    for raw_line in path.read_text(encoding="ascii").splitlines():
        line = raw_line.split("//", 1)[0].strip()
        if line:
            words.append(int(line, 16))
    if len(words) != 513:
        raise ValueError(f"expected 513 LUT entries, found {len(words)} in {path}")
    if words[0] != 0x800000 or words[512] != 0x000AFE:
        raise ValueError("Q23 LUT endpoints do not match the RTL constants")
    return words


def exp_q23(magnitude: int, lut: list[int]) -> int:
    if magnitude <= 0:
        return lut[0]
    if magnitude > EXP_LIMIT_FIXED:
        return 0
    address = magnitude >> EXP_COARSE_SHIFT
    remainder = magnitude & ((1 << EXP_COARSE_SHIFT) - 1)
    if address <= 512:
        base_value = lut[address]
    else:
        base_value = ((lut[address - 512] * 0x000AFE) + (1 << 22)) >> 23
    correction = ((base_value * remainder) + (1 << (SCORE_FRAC - 1))) >> SCORE_FRAC
    second_order = (
        (base_value * remainder * remainder) + (1 << (2 * SCORE_FRAC))
    ) >> (2 * SCORE_FRAC + 1)
    return max(0, base_value - correction + second_order)


def pack_lanes(values: list[int], lane_width: int) -> int:
    packed = 0
    mask = (1 << lane_width) - 1
    for lane, value in enumerate(values):
        packed |= (value & mask) << (lane * lane_width)
    return packed


def signed_hex(value: int, width: int) -> int:
    return value & ((1 << width) - 1)


def model_update(
    scores_bf16: list[int],
    mask: int,
    state_valid: int,
    old_m: int,
    old_l: int,
    lut: list[int],
) -> tuple[int, int, int, int, list[int], int, int, int]:
    scores_fixed = [bf16_to_fixed(value) for value in scores_bf16]
    active = [lane for lane in range(TILE_COLS) if ((mask >> lane) & 1) == 0]

    if not active:
        return (
            state_valid,
            old_m,
            old_l if state_valid else 0,
            EXP_ONE if state_valid else 0,
            [0] * TILE_COLS,
            0,
            1,
            0 if state_valid or old_l == 0 else 1,
        )

    tile_max = max(scores_fixed[lane] for lane in active)
    new_m = max(old_m, tile_max) if state_valid else tile_max
    alpha = exp_q23(new_m - old_m, lut) if state_valid else 0
    weights = [
        0 if ((mask >> lane) & 1) else exp_q23(new_m - scores_fixed[lane], lut)
        for lane in range(TILE_COLS)
    ]
    row_sum = sum(weights)
    l_rescaled = ((old_l * alpha) + (1 << (EXP_FRAC - 1))) >> EXP_FRAC
    l_candidate = l_rescaled + row_sum
    l_max = (1 << L_SUM_W) - 1
    numeric_error = int((not state_valid and old_l != 0) or l_candidate > l_max)
    new_l = min(l_candidate, l_max)
    return 1, new_m, new_l, alpha, weights, row_sum, 0, numeric_error


def build_score_pool() -> list[int]:
    values = [
        -16.0,
        -12.0,
        -8.0,
        -7.5,
        -4.0,
        -2.0,
        -1.0,
        -0.5,
        0.0,
        0.125,
        0.5,
        1.0,
        2.0,
        3.0,
        4.0,
        7.5,
        8.0,
        12.0,
        16.0,
    ]
    return [float_to_bf16(value) for value in values]


def generate_cases(lut: list[int], random_count: int) -> list[tuple[int, ...]]:
    rng = random.Random(0xF1A52A)
    score_pool = build_score_pool()
    directed = [
        ([0.0, 1.0, 2.0, 3.0], 0b0000),
        ([4.0, 3.0, 2.0, 1.0], 0b0000),
        ([-8.0, -7.0, -6.0, -5.0], 0b0000),
        ([12.0, 12.0, 12.0, 12.0], 0b1111),
        ([4.0, 16.0, 2.0, -4.0], 0b0010),
        ([-16.0, -12.0, 8.0, 7.5], 0b1001),
    ]

    cases = []
    state_valid = 0
    old_m = 0
    old_l = 0

    def append_case(scores_bf16: list[int], mask: int) -> None:
        nonlocal state_valid, old_m, old_l
        expected = model_update(
            scores_bf16, mask, state_valid, old_m, old_l, lut
        )
        cases.append(
            (
                pack_lanes(scores_bf16, 16),
                mask,
                state_valid,
                signed_hex(old_m, SCORE_W),
                old_l,
                expected[0],
                signed_hex(expected[1], SCORE_W),
                expected[2],
                expected[3],
                q23_to_q15(expected[3]),
                q15_to_bf16(q23_to_q15(expected[3])),
                pack_lanes(expected[4], EXP_W),
                pack_lanes([q23_to_q15(value) for value in expected[4]], 16),
                pack_lanes(
                    [q15_to_bf16(q23_to_q15(value)) for value in expected[4]],
                    16,
                ),
                expected[5],
                expected[6],
                expected[7],
            )
        )
        state_valid, old_m, old_l = expected[0], expected[1], expected[2]

    for values, mask in directed:
        append_case([float_to_bf16(value) for value in values], mask)

    sequence_position = 0
    for _ in range(random_count):
        if sequence_position == 32:
            state_valid, old_m, old_l = 0, 0, 0
            sequence_position = 0

        scores = [rng.choice(score_pool) for _ in range(TILE_COLS)]
        selector = rng.randrange(16)
        if selector == 0:
            mask = 0b1111
        elif selector < 5:
            first_masked = rng.randrange(TILE_COLS + 1)
            mask = ((1 << TILE_COLS) - 1) ^ ((1 << first_masked) - 1)
        else:
            mask = rng.randrange(16)
        append_case(scores, mask)
        sequence_position += 1

    return cases


def write_cases(path: Path, cases: list[tuple[int, ...]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii", newline="\n") as output:
        for case_id, case in enumerate(cases):
            (
                scores,
                mask,
                in_state,
                in_m,
                in_l,
                out_state,
                out_m,
                out_l,
                alpha_q23,
                alpha_q15,
                alpha_bf16,
                weights_q23,
                weights_q15,
                weights_bf16,
                row_sum,
                all_masked,
                error,
            ) = case
            output.write(
                f"{case_id:d} {scores:016x} {mask:01x} {in_state:01x} "
                f"{in_m:06x} {in_l:08x} {out_state:01x} {out_m:06x} "
                f"{out_l:08x} {alpha_q23:06x} {alpha_q15:04x} "
                f"{alpha_bf16:04x} {weights_q23:024x} {weights_q15:016x} "
                f"{weights_bf16:016x} {row_sum:08x} {all_masked:01x} "
                f"{error:01x}\n"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lut", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--random-count", type=int, default=506)
    args = parser.parse_args()

    lut = read_lut(args.lut)
    cases = generate_cases(lut, args.random_count)
    write_cases(args.output, cases)
    print(f"[PASS] generated {len(cases)} Stage 2A vectors: {args.output}")


if __name__ == "__main__":
    main()
