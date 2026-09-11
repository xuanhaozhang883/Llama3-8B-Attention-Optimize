"""Bit-oriented Accuracy exp candidate for CATS-R4 B2.

The arithmetic mirrors a synthesizable Q16 range reducer and a 33-entry Q31
LUT.  Results remain software-candidate evidence until the matching RTL and
hardware regressions pass.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
from collections.abc import Sequence
from pathlib import Path

import cats_r4_b2_row_model as base


FRACTION_BITS = 16
LOG2_E_Q16 = 94_548
MAX_GAP_Q16 = 104 << FRACTION_BITS
LUT_SEGMENTS = 32
EXP2_NEGATIVE_Q31 = tuple(
    round(base.f32(2.0 ** (-index / LUT_SEGMENTS)) * (1 << 31))
    for index in range(LUT_SEGMENTS + 1)
)


def rshift_rne_unsigned(value: int, shift: int) -> int:
    """Round a non-negative integer right shift to nearest, ties to even."""

    if value < 0:
        raise ValueError("unsigned RNE input must be non-negative")
    if shift <= 0:
        return value << (-shift)
    quotient = value >> shift
    remainder = value & ((1 << shift) - 1)
    halfway = 1 << (shift - 1)
    return quotient + int(
        remainder > halfway or (remainder == halfway and quotient & 1)
    )


def bf16_to_q16(value_bf16: int) -> int:
    """Convert finite BF16 to signed Q16 with RNE for the exp gap path."""

    sign = -1 if value_bf16 & 0x8000 else 1
    exponent = (value_bf16 >> 7) & 0xFF
    fraction = value_bf16 & 0x7F
    if exponent == 0xFF:
        raise ValueError("Accuracy exp rejects non-finite BF16")
    if exponent == 0:
        return 0
    significand = 0x80 | fraction
    shift = exponent - 118
    magnitude = (
        significand << shift
        if shift >= 0
        else rshift_rne_unsigned(significand, -shift)
    )
    return sign * magnitude


def bf16_gap_q16(row_max_bf16: int, score_bf16: int) -> int:
    """Return saturated max-score in Q16 for finite ordered BF16 inputs."""

    row_max_exponent = (row_max_bf16 >> 7) & 0xFF
    score_exponent = (score_bf16 >> 7) & 0xFF
    if row_max_exponent == 0xFF or score_exponent == 0xFF:
        raise ValueError("Accuracy exp rejects non-finite score/max")
    maximum = base.bf16_bits_to_f32(row_max_bf16)
    score = base.bf16_bits_to_f32(score_bf16)
    if score > maximum:
        raise ValueError("score exceeds supplied row maximum")
    if row_max_bf16 == score_bf16 or (
        row_max_bf16 & 0x7FFF == 0 and score_bf16 & 0x7FFF == 0
    ):
        return 0
    # Above this exponent one BF16 ULP already exceeds the useful exp range;
    # unequal finite values can be saturated without losing a non-zero result.
    if row_max_exponent >= 141 or score_exponent >= 141:
        return MAX_GAP_Q16
    gap = bf16_to_q16(row_max_bf16) - bf16_to_q16(score_bf16)
    return min(max(gap, 0), MAX_GAP_Q16)


def q31_scaled_to_fp32_bits(interpolated_q31: int, exponent: int) -> int:
    """Encode ``interpolated_q31 * 2**(-31-exponent)`` as FP32 RNE."""

    if interpolated_q31 < 0 or exponent < 0:
        raise ValueError("scaled exp components must be non-negative")
    if interpolated_q31 == 0:
        return 0

    most_significant_bit = interpolated_q31.bit_length() - 1
    unbiased_exponent = most_significant_bit - 31 - exponent
    if unbiased_exponent >= -126:
        significand = rshift_rne_unsigned(
            interpolated_q31, most_significant_bit - 23
        )
        if significand == 1 << 24:
            significand >>= 1
            unbiased_exponent += 1
        if unbiased_exponent > 0:
            raise OverflowError("exp(-gap) cannot exceed one")
        return ((unbiased_exponent + 127) << 23) | (significand & 0x7FFFFF)

    # A binary32 subnormal represents an integer multiple of 2**-149.
    subnormal_shift = exponent - 118
    fraction = rshift_rne_unsigned(interpolated_q31, subnormal_shift)
    return min(fraction, 0x800000)


def accuracy_exp_fixed_bits(row_max_bf16: int, score_bf16: int) -> int:
    """Return the proposed fixed-range-reduced exp weight as FP32 bits."""

    gap_q16 = bf16_gap_q16(row_max_bf16, score_bf16)
    scaled_q16 = rshift_rne_unsigned(gap_q16 * LOG2_E_Q16, FRACTION_BITS)
    exponent = scaled_q16 >> FRACTION_BITS
    if exponent >= 150:
        return 0

    fraction = scaled_q16 & ((1 << FRACTION_BITS) - 1)
    index = min(fraction >> 11, LUT_SEGMENTS - 1)
    local_q11 = fraction & 0x7FF
    lower = EXP2_NEGATIVE_Q31[index]
    upper = EXP2_NEGATIVE_Q31[index + 1]
    decrement = rshift_rne_unsigned((lower - upper) * local_q11, 11)
    interpolated_q31 = lower - decrement
    return q31_scaled_to_fp32_bits(interpolated_q31, exponent)


def _numeric_error_result(length: int) -> base.RowResult:
    return base.RowResult(
        mode=base.NumericMode.ACCURACY.value,
        maximum_bf16=None,
        weights_bf16=tuple(0 for _ in range(length)),
        weights_fp32=tuple(0 for _ in range(length)),
        probabilities_bf16=tuple(0 for _ in range(length)),
        sum_q15=None,
        sum_fp32=0,
        reciprocal_q30=None,
        reciprocal_fp32=0,
        numeric_error=True,
    )


def accuracy_row_fixed(
    scores_bf16: Sequence[int],
    masks: Sequence[bool],
    row_max_bf16: int | None = None,
) -> base.RowResult:
    """Evaluate one row with the bit-oriented exp and FP32 row boundaries."""

    base._validate_row(scores_bf16, masks)
    valid = [index for index, masked in enumerate(masks) if not masked]
    if not valid:
        return _numeric_error_result(len(scores_bf16))
    scores = [base.bf16_bits_to_f32(value) for value in scores_bf16]
    if any(not math.isfinite(scores[index]) for index in valid):
        return _numeric_error_result(len(scores_bf16))

    maximum_index = max(valid, key=lambda index: scores[index])
    computed_maximum = scores_bf16[maximum_index]
    if row_max_bf16 is None:
        row_max_bf16 = computed_maximum
    else:
        supplied_maximum = base.bf16_bits_to_f32(row_max_bf16)
        if not math.isfinite(supplied_maximum) or supplied_maximum != scores[maximum_index]:
            return _numeric_error_result(len(scores_bf16))

    weight_bits: list[int] = []
    try:
        for score_bf16, masked in zip(scores_bf16, masks):
            weight_bits.append(
                0 if masked else accuracy_exp_fixed_bits(row_max_bf16, score_bf16)
            )
    except ValueError:
        return _numeric_error_result(len(scores_bf16))

    denominator = base.f32(0.0)
    for bits in weight_bits:
        denominator = base.fp32_add(denominator, base.bits_to_f32(bits))
    if not math.isfinite(denominator) or denominator <= 0.0:
        return _numeric_error_result(len(scores_bf16))
    reciprocal = base.f32(1.0 / denominator)
    probabilities = [
        base.fp32_mul(base.bits_to_f32(bits), reciprocal) for bits in weight_bits
    ]
    return base.RowResult(
        mode=base.NumericMode.ACCURACY.value,
        maximum_bf16=row_max_bf16,
        weights_bf16=tuple(
            base.f32_to_bf16_bits(base.bits_to_f32(bits)) for bits in weight_bits
        ),
        weights_fp32=tuple(weight_bits),
        probabilities_bf16=tuple(
            base.f32_to_bf16_bits(value) for value in probabilities
        ),
        sum_q15=None,
        sum_fp32=base.f32_bits(denominator),
        reciprocal_q30=None,
        reciprocal_fp32=base.f32_bits(reciprocal),
        numeric_error=False,
    )


def accuracy_context_fixed(
    scores_bf16: Sequence[int],
    masks: Sequence[bool],
    values_bf16: Sequence[Sequence[int]],
    row_max_bf16: int | None = None,
) -> tuple[int, ...]:
    """Apply key-ordered FP32 PV/normalize around the fixed exp candidate."""

    if len(values_bf16) != len(scores_bf16) or not values_bf16:
        raise ValueError("V rows must match the score row")
    dimension = len(values_bf16[0])
    if any(len(row) != dimension for row in values_bf16):
        raise ValueError("all V rows must have the same feature dimension")
    row = accuracy_row_fixed(scores_bf16, masks, row_max_bf16)
    if row.numeric_error:
        return tuple(0 for _ in range(dimension))

    weights = [base.bits_to_f32(bits) for bits in row.weights_fp32]
    reciprocal = base.bits_to_f32(row.reciprocal_fp32)
    result: list[int] = []
    for feature in range(dimension):
        numerator = base.f32(0.0)
        for weight, value_row in zip(weights, values_bf16):
            product = base.fp32_mul(
                weight, base.bf16_bits_to_f32(value_row[feature])
            )
            numerator = base.fp32_add(numerator, product)
        result.append(
            base.f32_to_bf16_bits(base.fp32_mul(numerator, reciprocal))
        )
    return tuple(result)


def write_exp_vectors(path: Path, count: int = 8_192) -> None:
    """Write deterministic packed max/score/weight/error RTL vectors."""

    if count < 16:
        raise ValueError("exp vector count must cover at least 16 directed cases")
    directed = [
        (0x0000, 0x0000),
        (0x0000, 0xBF80),
        (0x0000, 0xC110),
        (0x0000, 0xC2CE),
        (0x0000, 0xC2D0),
        (0x8000, 0x0000),
        (0x0000, 0x8000),
        (0x3F80, 0x3F80),
        (0x3F80, 0x3F00),
        (0x7F7F, 0xFF7F),
        (0x0001, 0x8001),
        (0x0000, 0x3F80),
        (0x7F80, 0x0000),
        (0x0000, 0xFF80),
        (0x7FC1, 0x0000),
        (0x0000, 0xFFC1),
    ]
    pairs = list(directed)
    rng = random.Random(0xB2E32026)
    while len(pairs) < count:
        first = rng.randrange(0x10000)
        second = rng.randrange(0x10000)
        if (first >> 7) & 0xFF == 0xFF or (second >> 7) & 0xFF == 0xFF:
            continue
        first_value = base.bf16_bits_to_f32(first)
        second_value = base.bf16_bits_to_f32(second)
        if first_value >= second_value:
            pairs.append((first, second))
        else:
            pairs.append((second, first))

    lines: list[str] = []
    for maximum, score in pairs:
        try:
            weight = accuracy_exp_fixed_bits(maximum, score)
            error = 0
        except ValueError:
            weight = 0
            error = 1
        packed = (error << 64) | (maximum << 48) | (score << 32) | weight
        lines.append(f"{packed:017X}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def write_positive_add_vectors(path: Path, count: int = 8_192) -> None:
    """Write deterministic packed positive-FP32-adder RTL vectors."""

    if count < 16:
        raise ValueError("add vector count must cover at least 16 directed cases")
    pairs = [
        (0x00000000, 0x00000000),
        (0x00000001, 0x00000001),
        (0x007FFFFF, 0x00000001),
        (0x007FFFFF, 0x007FFFFF),
        (0x00800000, 0x00000001),
        (0x3F800000, 0x33800000),
        (0x3F800000, 0x34000000),
        (0x3F800000, 0x3F800000),
        (0x42FE0000, 0x3F800000),
        (0x00000000, 0x00000001),
        (0x80000000, 0x00000000),
        (0xBF800000, 0x3F800000),
        (0x7F800000, 0x3F800000),
        (0x7FC00001, 0x00000000),
        (0x00000000, 0xFF800000),
        (0x00000000, 0xFFC00001),
    ]
    rng = random.Random(0xB2ADD2026)
    while len(pairs) < count:
        exponent_a = rng.randrange(0, 134)
        exponent_b = rng.randrange(0, 128)
        operand_a = (exponent_a << 23) | rng.randrange(1 << 23)
        operand_b = (exponent_b << 23) | rng.randrange(1 << 23)
        pairs.append((operand_a, operand_b))

    lines: list[str] = []
    for operand_a, operand_b in pairs:
        invalid = (
            bool(operand_a >> 31)
            or bool(operand_b >> 31)
            or ((operand_a >> 23) & 0xFF) == 0xFF
            or ((operand_b >> 23) & 0xFF) == 0xFF
        )
        if invalid:
            result = 0
            error = 1
        else:
            result = base.f32_bits(
                base.fp32_add(
                    base.bits_to_f32(operand_a), base.bits_to_f32(operand_b)
                )
            )
            error = int(((result >> 23) & 0xFF) == 0xFF)
            if error:
                result = 0
        packed = (
            (error << 96) | (operand_a << 64) | (operand_b << 32) | result
        )
        lines.append(f"{packed:025X}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def write_reciprocal_vectors(path: Path, count: int = 8_192) -> None:
    """Write deterministic packed row-sum reciprocal RTL vectors."""

    if count < 16:
        raise ValueError("reciprocal vectors must cover 16 directed cases")
    sums = [
        0x3F800000,
        0x3FC00000,
        0x40000000,
        0x40400000,
        0x40A00000,
        0x42FE0000,
        0x42FFFFFF,
        0x43000000,
        0x3F800001,
        0x427FFFFF,
        0x00000000,
        0x3F7FFFFF,
        0x43000001,
        0xBF800000,
        0x7F800000,
        0x7FC00001,
    ]
    rng = random.Random(0xB2DEC2026)
    while len(sums) < count:
        exponent = rng.randrange(127, 134)
        sums.append((exponent << 23) | rng.randrange(1 << 23))

    lines: list[str] = []
    for sum_bits in sums:
        legal = 0x3F800000 <= sum_bits <= 0x43000000
        if legal:
            result = base.f32_bits(
                base.f32(1.0 / base.bits_to_f32(sum_bits))
            )
            error = 0
        else:
            result = 0
            error = 1
        packed = (error << 64) | (sum_bits << 32) | result
        lines.append(f"{packed:017X}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def write_equal_row_metadata_vectors(path: Path) -> None:
    """Write sum/inverse pairs for 128 causal rows of equal scores.

    A row with index ``r`` contains ``r + 1`` legal scores.  When every score
    equals the row maximum, every unnormalized weight is exactly FP32 1.0, so
    these vectors isolate whole-row control, accumulation, reciprocal, and
    scheme-A publication counts from exp approximation error.
    """

    lines: list[str] = []
    for row in range(128):
        row_sum = base.f32(float(row + 1))
        sum_bits = base.f32_bits(row_sum)
        inverse_bits = base.f32_bits(base.f32(1.0 / row_sum))
        lines.append(f"{sum_bits:08X}{inverse_bits:08X}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def write_full_row_rtl_vectors(
    root: Path, row_path: Path, score_path: Path
) -> None:
    """Generate stored-input row/score vectors for whole-row RTL checking."""

    data = root / "vitis" / "data"
    q_words = base.read_hex_words(data / "q_before_rope_bf16.hex")
    k_words = base.read_hex_words(data / "k_before_rope_bf16.hex")
    sine = base.read_hex_words(root / "mem" / "sin_bf16.hex")
    cosine = base.read_hex_words(root / "mem" / "cos_bf16.hex")
    if (
        len(q_words) != 32 * 128 * 128
        or len(k_words) != 8 * 128 * 128
        or len(sine) != 128 * 64
        or len(cosine) != 128 * 64
    ):
        raise ValueError("authoritative stored Q/K/RoPE dimensions do not match")

    def tensor_row(words: Sequence[int], head: int, row: int) -> list[int]:
        offset = (head * 128 + row) * 128
        return list(words[offset : offset + 128])

    row_path.parent.mkdir(parents=True, exist_ok=True)
    score_path.parent.mkdir(parents=True, exist_ok=True)
    k_cache: dict[tuple[int, int], list[int]] = {}
    with row_path.open("w", encoding="ascii", newline="\n") as row_file:
        with score_path.open("w", encoding="ascii", newline="\n") as score_file:
            for head in range(32):
                kv_head = head // 4
                for row in range(128):
                    q_rotated = base.rope_vector(
                        tensor_row(q_words, head, row), row, sine, cosine
                    )
                    scores: list[int] = []
                    for key in range(row + 1):
                        cache_key = (kv_head, key)
                        if cache_key not in k_cache:
                            k_cache[cache_key] = base.rope_vector(
                                tensor_row(k_words, kv_head, key),
                                key,
                                sine,
                                cosine,
                            )
                        scores.append(
                            base.qk_score(q_rotated, k_cache[cache_key])
                        )
                    result = accuracy_row_fixed(scores, [False] * len(scores))
                    if result.numeric_error or result.maximum_bf16 is None:
                        raise ValueError(
                            f"unexpected numeric error at head={head}, row={row}"
                        )
                    row_file.write(
                        f"{result.maximum_bf16:04X}"
                        f"{result.sum_fp32:08X}{result.reciprocal_fp32:08X}\n"
                    )
                    for score, weight in zip(scores, result.weights_fp32):
                        score_file.write(f"{score:04X}{weight:08X}\n")
                print(
                    f"Accuracy RTL vectors completed head {head + 1}/32",
                    file=sys.stderr,
                    flush=True,
                )


def _row_adapter(
    scores_bf16: Sequence[int], masks: Sequence[bool], segments: int = 32
) -> base.RowResult:
    if segments != LUT_SEGMENTS:
        raise ValueError("fixed candidate implements exactly 32 LUT segments")
    return accuracy_row_fixed(scores_bf16, masks)


def _context_adapter(
    scores_bf16: Sequence[int],
    masks: Sequence[bool],
    values_bf16: Sequence[Sequence[int]],
    segments: int = 32,
) -> tuple[int, ...]:
    if segments != LUT_SEGMENTS:
        raise ValueError("fixed candidate implements exactly 32 LUT segments")
    return accuracy_context_fixed(scores_bf16, masks, values_bf16)


def _describe_fixed_candidate(result: dict[str, object]) -> dict[str, object]:
    result["arithmetic"] = (
        "BF16-to-Q16 max-score gap, Q16 log2(e) range reduction, "
        "33-entry Q31 linear interpolation, FP32 key-ordered sum/PV, "
        "FP32 RNE reciprocal then multiply"
    )
    limitations = list(result.get("limitations", []))
    limitations.append(
        "whole-row RTL exists as a directed Icarus checkpoint; full XSim/OOC "
        "and stored-vector RTL closure are not yet complete"
    )
    result["limitations"] = limitations
    return result


def run_fixed_stress_sweep() -> dict[str, object]:
    """Run the existing deterministic stress workload with fixed operators."""

    original_row = base.accuracy_row_range_reduced_lut
    original_context = base.accuracy_context_range_reduced_lut
    base.accuracy_row_range_reduced_lut = _row_adapter
    base.accuracy_context_range_reduced_lut = _context_adapter
    try:
        return _describe_fixed_candidate(
            base.run_accuracy_stress_sweep((LUT_SEGMENTS,))
        )
    finally:
        base.accuracy_row_range_reduced_lut = original_row
        base.accuracy_context_range_reduced_lut = original_context


def run_fixed_full_sweep(root: Path) -> dict[str, object]:
    """Run all stored project vectors with fixed operators."""

    original_row = base.accuracy_row_range_reduced_lut
    original_context = base.accuracy_context_range_reduced_lut
    base.accuracy_row_range_reduced_lut = _row_adapter
    base.accuracy_context_range_reduced_lut = _context_adapter
    try:
        return _describe_fixed_candidate(
            base.run_accuracy_full_sweep(root, (LUT_SEGMENTS,))
        )
    finally:
        base.accuracy_row_range_reduced_lut = original_row
        base.accuracy_context_range_reduced_lut = original_context


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    sweep = parser.add_mutually_exclusive_group(required=True)
    sweep.add_argument("--stress", action="store_true")
    sweep.add_argument("--full", action="store_true")
    sweep.add_argument("--exp-vectors", type=Path)
    sweep.add_argument("--add-vectors", type=Path)
    sweep.add_argument("--reciprocal-vectors", type=Path)
    sweep.add_argument("--equal-row-metadata-vectors", type=Path)
    sweep.add_argument("--full-row-rtl-vectors", type=Path)
    parser.add_argument("--vector-count", type=int, default=8_192)
    parser.add_argument("--json", type=Path)
    arguments = parser.parse_args()

    if arguments.exp_vectors:
        write_exp_vectors(arguments.exp_vectors, arguments.vector_count)
        print(
            json.dumps(
                {
                    "status": "EXP_VECTORS_WRITTEN",
                    "path": str(arguments.exp_vectors),
                    "vectors": arguments.vector_count,
                    "seed": "0xB2E32026",
                },
                sort_keys=True,
            )
        )
        return 0

    if arguments.add_vectors:
        write_positive_add_vectors(arguments.add_vectors, arguments.vector_count)
        print(
            json.dumps(
                {
                    "status": "ADD_VECTORS_WRITTEN",
                    "path": str(arguments.add_vectors),
                    "vectors": arguments.vector_count,
                    "seed": "0xB2ADD2026",
                },
                sort_keys=True,
            )
        )
        return 0

    if arguments.reciprocal_vectors:
        write_reciprocal_vectors(
            arguments.reciprocal_vectors, arguments.vector_count
        )
        print(
            json.dumps(
                {
                    "status": "RECIPROCAL_VECTORS_WRITTEN",
                    "path": str(arguments.reciprocal_vectors),
                    "vectors": arguments.vector_count,
                    "seed": "0xB2DEC2026",
                },
                sort_keys=True,
            )
        )
        return 0

    if arguments.equal_row_metadata_vectors:
        write_equal_row_metadata_vectors(arguments.equal_row_metadata_vectors)
        print(
            json.dumps(
                {
                    "status": "EQUAL_ROW_METADATA_VECTORS_WRITTEN",
                    "path": str(arguments.equal_row_metadata_vectors),
                    "rows": 128,
                },
                sort_keys=True,
            )
        )
        return 0

    if arguments.full_row_rtl_vectors:
        output_root = arguments.full_row_rtl_vectors
        row_path = output_root / "rows.hex"
        score_path = output_root / "scores.hex"
        write_full_row_rtl_vectors(root, row_path, score_path)
        print(
            json.dumps(
                {
                    "status": "FULL_ROW_RTL_VECTORS_WRITTEN",
                    "rows_path": str(row_path),
                    "scores_path": str(score_path),
                    "rows": 4_096,
                    "scores": 264_192,
                },
                sort_keys=True,
            )
        )
        return 0

    result = (
        run_fixed_full_sweep(root)
        if arguments.full
        else run_fixed_stress_sweep()
    )
    rendered = json.dumps(result, indent=2, sort_keys=True)
    print(rendered)
    if arguments.json:
        arguments.json.parent.mkdir(parents=True, exist_ok=True)
        arguments.json.write_text(rendered + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
