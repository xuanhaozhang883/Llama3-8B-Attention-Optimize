#!/usr/bin/env python3
"""Bit-aware numerical study for the v3.1 FlashAttention consumer.

The model deliberately mirrors the arithmetic boundaries used by the RTL:

* QK scores and V values enter as BF16.
* Scores are converted to signed Q10.14 with the same saturation/rounding as
  ``softmax_bf16.sv``.
* Exponentials use ``mem/exp_lut_q15.mem`` and its 1/64 address grid.
* The v3.0 path forms a Q1.15 probability, converts it to BF16, and performs
  BF16 x BF16 -> FP32 multiply/add in key order.
* The fused path maintains per-row FP32 ``m/l/O`` state.  Every multiply and
  add is rounded to FP32, just like the existing Xilinx Floating-Point IP.

This is an architectural gate, not a replacement for RTL simulation.  It
answers whether a proposed tile recurrence and precision are numerically safe
before committing to a large RTL implementation.
"""

from __future__ import annotations

import argparse
import functools
import json
import math
import random
import struct
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable, Sequence


SCORE_W = 24
SCORE_FRAC = 14
EXP_LIMIT_FIXED = 8 << SCORE_FRAC
EXP_ADDR_SHIFT = SCORE_FRAC - 6
EXP_ROUND_BIAS = 1 << (EXP_ADDR_SHIFT - 1)
BF16_SHIFT_BIAS = 134 - SCORE_FRAC
BF16_SAT_EXP = BF16_SHIFT_BIAS + SCORE_W - 8
BF16_ZERO_EXP = BF16_SHIFT_BIAS - 9


def f32(value: float) -> float:
    """Round one operation result to IEEE-754 binary32."""

    return struct.unpack(">f", struct.pack(">f", float(value)))[0]


def f32_bits(value: float) -> int:
    return struct.unpack(">I", struct.pack(">f", f32(value)))[0]


def bits_to_f32(bits: int) -> float:
    return struct.unpack(">f", struct.pack(">I", bits & 0xFFFFFFFF))[0]


def f32_to_bf16_bits(value: float) -> int:
    """IEEE binary32 to BF16, round-to-nearest-even, matching RTL."""

    bits = f32_bits(value)
    upper = bits >> 16
    lower = bits & 0xFFFF
    if lower > 0x8000 or (lower == 0x8000 and (upper & 1)):
        upper = (upper + 1) & 0xFFFF
    return upper


@functools.lru_cache(maxsize=65536)
def bf16_bits_to_f32(bits: int) -> float:
    return bits_to_f32((bits & 0xFFFF) << 16)


def quantize_bf16(value: float) -> float:
    return bf16_bits_to_f32(f32_to_bf16_bits(value))


def bf16_to_fixed(bits: int) -> int:
    """Port of softmax_bf16.sv::bf16_to_fixed (signed Q10.14)."""

    sign = (bits >> 15) & 1
    exponent = (bits >> 7) & 0xFF
    fraction = bits & 0x7F
    significand = 0x80 | fraction
    min_value = -(1 << (SCORE_W - 1))
    max_value = (1 << (SCORE_W - 1)) - 1

    if exponent == 0:
        return 0
    if exponent == 0xFF:
        if fraction:
            return 0
        return min_value if sign else max_value
    if exponent >= BF16_SAT_EXP:
        return min_value if sign else max_value
    if exponent <= BF16_ZERO_EXP:
        return 0

    if exponent >= BF16_SHIFT_BIAS:
        magnitude = significand << (exponent - BF16_SHIFT_BIAS)
    else:
        right_shift = BF16_SHIFT_BIAS - exponent
        magnitude = (significand + (1 << (right_shift - 1))) >> right_shift
    return -magnitude if sign else magnitude


def q15_to_bf16_bits(q15: int) -> int:
    """Port of softmax_bf16.sv::q15_to_bf16."""

    if q15 == 0:
        return 0
    msb = q15.bit_length() - 1
    exponent = msb + 112
    normalized = q15 << (15 - msb)
    fraction = (normalized >> 8) & 0x7F
    round_bit = (normalized >> 7) & 1
    sticky = bool(normalized & 0x7F)
    if round_bit and (sticky or (fraction & 1)):
        fraction += 1
    if fraction & 0x80:
        exponent += 1
        fraction = 0
    return ((exponent & 0xFF) << 7) | (fraction & 0x7F)


def q30_to_bf16_bits(q30: int) -> int:
    """Port of flash_context_fusion_backend.sv::q30_to_bf16."""

    q30 &= 0x7FFFFFFF
    if q30 == 0:
        return 0
    msb = q30.bit_length() - 1
    exponent = msb + 97
    if msb <= 7:
        significand = q30 << (7 - msb)
    else:
        shift = msb - 7
        significand = q30 >> shift
        round_bit = (q30 >> (shift - 1)) & 1
        sticky = bool(q30 & ((1 << (shift - 1)) - 1))
        if round_bit and (sticky or (significand & 1)):
            significand += 1
    if significand & 0x100:
        exponent += 1
        significand = 0
    return ((exponent & 0xFF) << 7) | (significand & 0x7F)


def q30_to_fp32_bits(q30: int) -> int:
    """Port of flash_context_fusion_backend.sv::q30_to_fp32."""

    q30 &= 0x7FFFFFFF
    if q30 == 0:
        return 0
    msb = q30.bit_length() - 1
    exponent = msb + 97
    if msb <= 23:
        significand = q30 << (23 - msb)
    else:
        shift = msb - 23
        significand = q30 >> shift
        round_bit = (q30 >> (shift - 1)) & 1
        sticky = bool(q30 & ((1 << (shift - 1)) - 1))
        if round_bit and (sticky or (significand & 1)):
            significand += 1
    if significand & 0x1000000:
        exponent += 1
        significand = 0
    return ((exponent & 0xFF) << 23) | (significand & 0x7FFFFF)


def exp_q15(max_fixed: int, score_fixed: int, masked: bool,
            lut: Sequence[int]) -> int:
    if masked:
        return 0
    magnitude = max_fixed - score_fixed
    if magnitude <= 0:
        address = 0
    elif magnitude > EXP_LIMIT_FIXED:
        return 0
    else:
        address = (magnitude + EXP_ROUND_BIAS) >> EXP_ADDR_SHIFT
    return lut[address]


def fp32_mul(a: float, b: float) -> float:
    # All callers provide BF16-exact or already rounded binary32 operands.
    # Their exact product fits in binary64 before the explicit binary32 round.
    return f32(a * b)


def fp32_add(a: float, b: float) -> float:
    return f32(a + b)


def bf16_ordered(bits: int) -> int:
    """Map BF16 bit patterns to monotonically ordered integers."""

    return (0xFFFF - bits) if (bits & 0x8000) else (bits + 0x8000)


def bf16_ulp_distance(a: int, b: int) -> int:
    return abs(bf16_ordered(a) - bf16_ordered(b))


def baseline_v30(scores_bf16: Sequence[int], masks: Sequence[bool],
                 values_bf16: Sequence[Sequence[int]], lut: Sequence[int]) -> list[int]:
    """Current v3.0 exact-denominator Softmax followed by current PV."""

    fixed = [bf16_to_fixed(x) for x in scores_bf16]
    valid = [x for x, mask in zip(fixed, masks) if not mask]
    if not valid:
        return [0] * len(values_bf16[0])
    maximum = max(valid)
    weights = [exp_q15(maximum, x, mask, lut)
               for x, mask in zip(fixed, masks)]
    denominator = sum(weights)
    reciprocal_q30 = (1 << 45) // denominator
    probabilities_bf16 = []
    for weight in weights:
        q15 = min(32768, (reciprocal_q30 * weight + (1 << 29)) >> 30)
        probabilities_bf16.append(q15_to_bf16_bits(q15))

    result = []
    for feature in range(len(values_bf16[0])):
        accumulator = f32(0.0)
        for probability, row in zip(probabilities_bf16, values_bf16):
            product = fp32_mul(bf16_bits_to_f32(probability),
                               bf16_bits_to_f32(row[feature]))
            accumulator = fp32_add(accumulator, product)
        result.append(f32_to_bf16_bits(accumulator))
    return result


def flash_fused(scores_bf16: Sequence[int], masks: Sequence[bool],
                values_bf16: Sequence[Sequence[int]], lut: Sequence[int],
                tile: int) -> list[int]:
    """Tile-wise FP32 m/l/O recurrence proposed for the fused RTL."""

    fixed = [bf16_to_fixed(x) for x in scores_bf16]
    dimension = len(values_bf16[0])
    maximum: int | None = None
    denominator = f32(0.0)
    output = [f32(0.0) for _ in range(dimension)]

    for base in range(0, len(fixed), tile):
        stop = min(base + tile, len(fixed))
        valid = [fixed[index] for index in range(base, stop)
                 if not masks[index]]
        if not valid:
            continue
        tile_max = max(valid)
        new_max = tile_max if maximum is None else max(maximum, tile_max)
        alpha_q15 = 0 if maximum is None else exp_q15(new_max, maximum, False, lut)
        alpha = f32(alpha_q15 / 32768.0)
        denominator = fp32_mul(denominator, alpha)
        for feature in range(dimension):
            output[feature] = fp32_mul(output[feature], alpha)

        for index in range(base, stop):
            weight_q15 = exp_q15(new_max, fixed[index], masks[index], lut)
            weight = f32(weight_q15 / 32768.0)
            denominator = fp32_add(denominator, weight)
            for feature in range(dimension):
                product = fp32_mul(weight, bf16_bits_to_f32(values_bf16[index][feature]))
                output[feature] = fp32_add(output[feature], product)
        maximum = new_max

    if maximum is None or denominator == 0.0:
        return [0] * dimension
    return [f32_to_bf16_bits(f32(value / denominator)) for value in output]


def flash_fused_fixed_l(scores_bf16: Sequence[int], masks: Sequence[bool],
                        values_bf16: Sequence[Sequence[int]],
                        lut: Sequence[int], tile: int) -> list[int]:
    """Hardware-oriented variant with a Q*.15 denominator state."""

    fixed = [bf16_to_fixed(x) for x in scores_bf16]
    dimension = len(values_bf16[0])
    maximum: int | None = None
    denominator_q15 = 0
    output = [f32(0.0) for _ in range(dimension)]
    for base in range(0, len(fixed), tile):
        stop = min(base + tile, len(fixed))
        valid = [fixed[index] for index in range(base, stop)
                 if not masks[index]]
        if not valid:
            continue
        tile_max = max(valid)
        new_max = tile_max if maximum is None else max(maximum, tile_max)
        alpha_q15 = 0 if maximum is None else exp_q15(new_max, maximum, False, lut)
        alpha = f32(alpha_q15 / 32768.0)
        denominator_q15 = ((denominator_q15 * alpha_q15 + (1 << 14)) >> 15)
        for feature in range(dimension):
            output[feature] = fp32_mul(output[feature], alpha)
        for index in range(base, stop):
            weight_q15 = exp_q15(new_max, fixed[index], masks[index], lut)
            denominator_q15 += weight_q15
            weight = f32(weight_q15 / 32768.0)
            for feature in range(dimension):
                product = fp32_mul(weight, bf16_bits_to_f32(values_bf16[index][feature]))
                output[feature] = fp32_add(output[feature], product)
        maximum = new_max
    if maximum is None or denominator_q15 == 0:
        return [0] * dimension
    denominator = f32(denominator_q15 / 32768.0)
    return [f32_to_bf16_bits(f32(value / denominator)) for value in output]


def flash_fused_bf16_weights(scores_bf16: Sequence[int], masks: Sequence[bool],
                             values_bf16: Sequence[Sequence[int]],
                             lut: Sequence[int], tile: int) -> list[int]:
    """Resource-sharing study: BF16 alpha/weights feeding existing PV PEs."""

    fixed = [bf16_to_fixed(x) for x in scores_bf16]
    dimension = len(values_bf16[0])
    maximum: int | None = None
    denominator_q15 = 0
    output = [f32(0.0) for _ in range(dimension)]
    for base in range(0, len(fixed), tile):
        stop = min(base + tile, len(fixed))
        valid = [fixed[index] for index in range(base, stop)
                 if not masks[index]]
        if not valid:
            continue
        tile_max = max(valid)
        new_max = tile_max if maximum is None else max(maximum, tile_max)
        alpha_q15 = 0 if maximum is None else exp_q15(new_max, maximum, False, lut)
        alpha = bf16_bits_to_f32(q15_to_bf16_bits(alpha_q15))
        denominator_q15 = ((denominator_q15 * alpha_q15 + (1 << 14)) >> 15)
        for feature in range(dimension):
            output[feature] = fp32_mul(output[feature], alpha)
        for index in range(base, stop):
            weight_q15 = exp_q15(new_max, fixed[index], masks[index], lut)
            denominator_q15 += weight_q15
            weight = bf16_bits_to_f32(q15_to_bf16_bits(weight_q15))
            for feature in range(dimension):
                product = fp32_mul(weight, bf16_bits_to_f32(values_bf16[index][feature]))
                output[feature] = fp32_add(output[feature], product)
        maximum = new_max
    if maximum is None or denominator_q15 == 0:
        return [0] * dimension
    denominator = f32(denominator_q15 / 32768.0)
    return [f32_to_bf16_bits(f32(value / denominator)) for value in output]


def flash_rtl_exact(scores_bf16: Sequence[int], masks: Sequence[bool],
                    values_bf16: Sequence[Sequence[int]],
                    lut: Sequence[int], tile: int) -> list[int]:
    """Mirror the implemented Online front end and Context backend exactly.

    The running denominator is integer Q*.15.  Alpha and weights cross into
    the PE array as BF16, every PE multiply/add is rounded to binary32, and
    final normalization uses floor(2^45/l) followed by the RTL Q30-to-FP32
    conversion and one binary32 multiply.
    """

    fixed = [bf16_to_fixed(x) for x in scores_bf16]
    dimension = len(values_bf16[0])
    maximum: int | None = None
    denominator_q15 = 0
    output = [f32(0.0) for _ in range(dimension)]
    for base in range(0, len(fixed), tile):
        stop = min(base + tile, len(fixed))
        valid = [fixed[index] for index in range(base, stop)
                 if not masks[index]]
        if not valid:
            continue
        tile_max = max(valid)
        new_max = tile_max if maximum is None else max(maximum, tile_max)
        alpha_q15 = 0 if maximum is None else exp_q15(
            new_max, maximum, False, lut)
        alpha = bf16_bits_to_f32(q15_to_bf16_bits(alpha_q15))
        denominator_q15 = (
            (denominator_q15 * alpha_q15 + (1 << 14)) >> 15)
        weights_q15 = [
            exp_q15(new_max, fixed[index], masks[index], lut)
            for index in range(base, stop)
        ]
        denominator_q15 += sum(weights_q15)
        weights = [
            bf16_bits_to_f32(q15_to_bf16_bits(weight))
            for weight in weights_q15
        ]
        for feature in range(dimension):
            accumulator = fp32_mul(output[feature], alpha)
            for offset, index in enumerate(range(base, stop)):
                product = fp32_mul(
                    weights[offset],
                    bf16_bits_to_f32(values_bf16[index][feature]))
                accumulator = fp32_add(accumulator, product)
            output[feature] = accumulator
        maximum = new_max

    if maximum is None or denominator_q15 == 0:
        return [0] * dimension
    reciprocal_q30 = (1 << 45) // denominator_q15
    reciprocal = bits_to_f32(q30_to_fp32_bits(reciprocal_q30))
    return [
        f32_to_bf16_bits(fp32_mul(value, reciprocal)) for value in output
    ]


def mathematical_reference(scores_bf16: Sequence[int], masks: Sequence[bool],
                           values_bf16: Sequence[Sequence[int]]) -> list[int]:
    scores = [bf16_bits_to_f32(x) for x in scores_bf16]
    valid = [x for x, mask in zip(scores, masks) if not mask]
    if not valid:
        return [0] * len(values_bf16[0])
    maximum = max(valid)
    weights = [0.0 if mask else math.exp(score - maximum)
               for score, mask in zip(scores, masks)]
    denominator = math.fsum(weights)
    result = []
    for feature in range(len(values_bf16[0])):
        terms = [weight * bf16_bits_to_f32(row[feature])
                 for weight, row in zip(weights, values_bf16)]
        result.append(f32_to_bf16_bits(math.fsum(terms) / denominator))
    return result


@dataclass
class Metrics:
    elements: int = 0
    different: int = 0
    strict_abs_failures: int = 0
    combined_failures: int = 0
    over_one_ulp: int = 0
    max_ulp: int = 0
    max_abs_error: float = 0.0

    def update(self, actual: Iterable[int], expected: Iterable[int]) -> None:
        for got, want in zip(actual, expected):
            distance = bf16_ulp_distance(got, want)
            absolute = abs(bf16_bits_to_f32(got) - bf16_bits_to_f32(want))
            self.elements += 1
            self.different += int(distance != 0)
            self.strict_abs_failures += int(absolute > 1.0e-4)
            self.combined_failures += int(absolute > 1.0e-4 and distance > 1)
            self.over_one_ulp += int(distance > 1)
            self.max_ulp = max(self.max_ulp, distance)
            self.max_abs_error = max(self.max_abs_error, absolute)


def make_case(rng: random.Random, length: int, dimension: int,
              causal_row: int | None) -> tuple[list[int], list[bool], list[list[int]]]:
    # Values resemble post-projection BF16 data while scores cover both normal
    # attention distributions and cases that force several running-max updates.
    scores = [f32_to_bf16_bits(rng.uniform(-5.0, 5.0)) for _ in range(length)]
    if rng.random() < 0.5:
        drift = rng.choice((-1.0, 1.0))
        scores = [f32_to_bf16_bits(bf16_bits_to_f32(value) +
                                   drift * index / max(1, length - 1) * 4.0)
                  for index, value in enumerate(scores)]
    masks = [False] * length
    if causal_row is not None:
        masks = [column > causal_row for column in range(length)]
    values = [[f32_to_bf16_bits(rng.uniform(-2.0, 2.0))
               for _ in range(dimension)] for _ in range(length)]
    return scores, masks, values


def load_lut(path: Path) -> list[int]:
    values = [int(line.strip(), 16) for line in path.read_text().splitlines()
              if line.strip()]
    # Address = round((max-score) * 64), with a hard limit of 8.0, hence
    # inclusive addresses 0..512.
    if len(values) != 513 or values[0] != 0x8000:
        raise ValueError(f"unexpected EXP LUT at {path}: {len(values)} entries")
    return values


def read_hex_words(path: Path) -> list[int]:
    return [int(line.strip(), 16) for line in path.read_text().splitlines()
            if line.strip()]


def rope_vector(raw: Sequence[int], token: int, sine: Sequence[int],
                cosine: Sequence[int]) -> list[int]:
    """Mirror the staged-BF16 split-half RoPE datapath."""

    dimension = len(raw)
    half = dimension // 2
    result = [0] * dimension
    for pair in range(half):
        x0 = bf16_bits_to_f32(raw[pair])
        x1 = bf16_bits_to_f32(raw[pair + half])
        sin_value = bf16_bits_to_f32(sine[token * half + pair])
        cos_value = bf16_bits_to_f32(cosine[token * half + pair])
        products = [
            quantize_bf16(fp32_mul(x0, cos_value)),
            quantize_bf16(fp32_mul(x1, sin_value)),
            quantize_bf16(fp32_mul(x0, sin_value)),
            quantize_bf16(fp32_mul(x1, cos_value)),
        ]
        result[pair] = f32_to_bf16_bits(
            fp32_add(products[0], -products[1]))
        result[pair + half] = f32_to_bf16_bits(
            fp32_add(products[2], products[3]))
    return result


def qk_score(q: Sequence[int], k: Sequence[int]) -> int:
    accumulator = f32(0.0)
    for q_word, k_word in zip(q, k):
        product = fp32_mul(bf16_bits_to_f32(q_word),
                           bf16_bits_to_f32(k_word))
        accumulator = fp32_add(accumulator, product)
    scale = bits_to_f32(0x3DB504F3)
    return f32_to_bf16_bits(fp32_mul(accumulator, scale))


def run_board_vector_study(root: Path, lut: Sequence[int], tile: int,
                           heads: Sequence[int], rows: Sequence[int],
                           rtl_exact_only: bool = False) -> dict[str, object]:
    """Run the proposed recurrence on selected authoritative board vectors."""

    data = root / "vitis/data"
    sequence_length = 128
    dimension = 128
    q_heads = 32
    kv_heads = 8
    q_words = read_hex_words(data / "q_before_rope_bf16.hex")
    k_words = read_hex_words(data / "k_before_rope_bf16.hex")
    v_words = read_hex_words(data / "v_bf16.hex")
    golden_words = read_hex_words(data / "attn_out_per_head_bf16.hex")
    sine = read_hex_words(root / "mem/sin_bf16.hex")
    cosine = read_hex_words(root / "mem/cos_bf16.hex")
    expected_sizes = (
        len(q_words) == q_heads * sequence_length * dimension,
        len(k_words) == kv_heads * sequence_length * dimension,
        len(v_words) == kv_heads * sequence_length * dimension,
        len(golden_words) == q_heads * sequence_length * dimension,
        len(sine) == sequence_length * dimension // 2,
        len(cosine) == sequence_length * dimension // 2,
    )
    if not all(expected_sizes):
        raise ValueError("authoritative board vector dimensions do not match v3.0")

    fused_metrics = Metrics()
    fixed_l_metrics = Metrics()
    bf16_weight_metrics = Metrics()
    rtl_exact_metrics = Metrics()
    baseline_metrics = Metrics()
    fused_vs_baseline = Metrics()
    k_cache: dict[tuple[int, int], list[int]] = {}
    rtl_combined_failure_examples: list[dict[str, object]] = []
    evaluated_rows = 0

    def tensor_row(words: Sequence[int], head: int, row: int) -> list[int]:
        base = (head * sequence_length + row) * dimension
        return list(words[base:base + dimension])

    for head in heads:
        if not 0 <= head < q_heads:
            raise ValueError(f"invalid Q head {head}")
        kv_head = head // (q_heads // kv_heads)
        for row in rows:
            if not 0 <= row < sequence_length:
                raise ValueError(f"invalid row {row}")
            q_rotated = rope_vector(tensor_row(q_words, head, row), row,
                                    sine, cosine)
            scores = []
            values = []
            for column in range(sequence_length):
                cache_key = (kv_head, column)
                if cache_key not in k_cache:
                    k_cache[cache_key] = rope_vector(
                        tensor_row(k_words, kv_head, column), column,
                        sine, cosine)
                if column <= row:
                    scores.append(qk_score(q_rotated, k_cache[cache_key]))
                else:
                    scores.append(0xFF80)
                values.append(tensor_row(v_words, kv_head, column))
            masks = [column > row for column in range(sequence_length)]
            golden = tensor_row(golden_words, head, row)
            rtl_exact = flash_rtl_exact(scores, masks, values, lut, tile)
            rtl_exact_metrics.update(rtl_exact, golden)
            for feature, (got, want) in enumerate(zip(rtl_exact, golden)):
                distance = bf16_ulp_distance(got, want)
                absolute = abs(bf16_bits_to_f32(got) -
                               bf16_bits_to_f32(want))
                if (absolute > 1.0e-4 and distance > 1 and
                        len(rtl_combined_failure_examples) < 32):
                    rtl_combined_failure_examples.append({
                        "head": head,
                        "row": row,
                        "feature": feature,
                        "actual_bf16": f"0x{got:04X}",
                        "expected_bf16": f"0x{want:04X}",
                        "actual": bf16_bits_to_f32(got),
                        "expected": bf16_bits_to_f32(want),
                        "absolute_error": absolute,
                        "bf16_ulp_distance": distance,
                    })
            if not rtl_exact_only:
                baseline = baseline_v30(scores, masks, values, lut)
                fused = flash_fused(scores, masks, values, lut, tile)
                fixed_l = flash_fused_fixed_l(scores, masks, values, lut, tile)
                bf16_weight = flash_fused_bf16_weights(scores, masks, values,
                                                        lut, tile)
                baseline_metrics.update(baseline, golden)
                fused_metrics.update(fused, golden)
                fixed_l_metrics.update(fixed_l, golden)
                bf16_weight_metrics.update(bf16_weight, golden)
                fused_vs_baseline.update(fused, baseline)
            evaluated_rows += 1

    result = {
        "configuration": {
            "source": "authoritative v3.0 vitis/data board vectors",
            "heads": list(heads),
            "rows": list(rows),
            "evaluated_rows": evaluated_rows,
            "elements": evaluated_rows * dimension,
            "tile": tile,
            "rtl_exact_only": rtl_exact_only,
        },
        "rtl_exact_vs_board_golden": asdict(rtl_exact_metrics),
        "rtl_combined_failure_examples": rtl_combined_failure_examples,
    }
    if not rtl_exact_only:
        result.update({
        "fused_vs_board_golden": asdict(fused_metrics),
        "fixed_l_fused_vs_board_golden": asdict(fixed_l_metrics),
        "bf16_weight_fused_vs_board_golden": asdict(bf16_weight_metrics),
        "v30_model_vs_board_golden": asdict(baseline_metrics),
        "fused_vs_v30_model": asdict(fused_vs_baseline),
        })
    return result


def run_study(lut: Sequence[int], seed: int, cases: int, length: int,
              dimension: int, tile: int) -> dict[str, object]:
    rng = random.Random(seed)
    fused_vs_reference = Metrics()
    baseline_vs_reference = Metrics()
    fused_vs_baseline = Metrics()
    tile_invariance = Metrics()

    for case in range(cases):
        causal_row = rng.randrange(length) if (case & 1) else None
        scores, masks, values = make_case(rng, length, dimension, causal_row)
        reference = mathematical_reference(scores, masks, values)
        baseline = baseline_v30(scores, masks, values, lut)
        fused = flash_fused(scores, masks, values, lut, tile)
        scalar_fused = flash_fused(scores, masks, values, lut, 1)
        fused_vs_reference.update(fused, reference)
        baseline_vs_reference.update(baseline, reference)
        fused_vs_baseline.update(fused, baseline)
        tile_invariance.update(fused, scalar_fused)

    return {
        "configuration": {
            "seed": seed,
            "cases": cases,
            "sequence_length": length,
            "head_dimension": dimension,
            "tile": tile,
            "score_format": "BF16 -> signed Q10.14",
            "exp_format": "Q1.15 LUT",
            "state_format": "FP32 m/l/O, FP32 rounding after each mul/add",
        },
        "fused_vs_mathematical_reference": asdict(fused_vs_reference),
        "v30_vs_mathematical_reference": asdict(baseline_vs_reference),
        "fused_vs_v30": asdict(fused_vs_baseline),
        "fused_tile_vs_scalar_tile": asdict(tile_invariance),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    root = Path(__file__).resolve().parents[1]
    parser.add_argument("--lut", type=Path, default=root / "mem/exp_lut_q15.mem")
    parser.add_argument("--seed", type=int, default=0x31FA)
    parser.add_argument("--cases", type=int, default=64)
    parser.add_argument("--length", type=int, default=128)
    parser.add_argument("--dimension", type=int, default=128)
    parser.add_argument("--tile", type=int, default=4)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--synthetic", action="store_true",
                        help="run randomized diagnostic instead of board vectors")
    parser.add_argument("--require-reference-max-ulp", type=int, default=1,
                        help="retained for CLI compatibility; board gate uses "
                             "abs<=1e-4 OR BF16 distance<=this value")
    parser.add_argument("--full-board", action="store_true",
                        help="evaluate all 32 Q heads and all 128 rows")
    parser.add_argument("--rtl-exact-only", action="store_true",
                        help="skip diagnostic arithmetic variants")
    args = parser.parse_args()
    lut = load_lut(args.lut)
    if args.synthetic:
        result = run_study(lut, args.seed, args.cases,
                           args.length, args.dimension, args.tile)
        gate_name = "fused_vs_mathematical_reference"
    else:
        heads = tuple(range(32)) if args.full_board else \
            (0, 3, 4, 7, 8, 15, 16, 23, 24, 31)
        rows = tuple(range(128)) if args.full_board else \
            (0, 1, 3, 7, 15, 31, 63, 95, 127)
        result = run_board_vector_study(
            root, lut, args.tile, heads=heads, rows=rows,
            rtl_exact_only=args.rtl_exact_only)
        gate_name = "rtl_exact_vs_board_golden"
    rendered = json.dumps(result, indent=2, sort_keys=True)
    print(rendered)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(rendered + "\n")

    fused_metrics = result[gate_name]
    # MAX_ALLOWED_ULP is currently one in the board application.  Metrics are
    # computed with that same value; reject attempts to silently relax it.
    if args.require_reference_max_ulp != 1:
        print("[FAIL] the v3.0 board contract fixes MAX_ALLOWED_ULP at 1")
        return 1
    if fused_metrics["combined_failures"] != 0:
        print(f"[FAIL] fused combined failures "
              f"{fused_metrics['combined_failures']} exceed 0")
        return 1
    print("[PASS] fused numerical gate passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
