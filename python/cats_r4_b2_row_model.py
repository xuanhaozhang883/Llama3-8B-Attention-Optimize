#!/usr/bin/env python3
"""CATS-R4 B2 whole-row Softmax numerical and counter model.

The model deliberately keeps two references separate:

* ``compatibility`` mirrors the existing project arithmetic boundaries:
  BF16 score -> signed Q10.14, the Q1.15 exp ROM, BF16 weights, an integer
  Q*.15 row sum, and floor(2**45/sum) reciprocal semantics.
* ``accuracy`` keeps BF16 score input but evaluates finite exponentials,
  weights, the key-ordered row sum, and reciprocal at binary32 boundaries.

Neither mode is selected from a filename, vector hash, row identity, or test
case.  This is a numerical candidate model, not RTL, XSim, synthesis, timing,
or board evidence.
"""

from __future__ import annotations

import argparse
import functools
import hashlib
import json
import math
import random
import sys
from dataclasses import asdict, dataclass
from enum import Enum
from pathlib import Path
from typing import Callable, Iterable, Sequence

from flash_attention_tile_model import (
    Metrics,
    baseline_v30,
    bf16_bits_to_f32,
    bf16_ulp_distance,
    bf16_to_fixed,
    bits_to_f32,
    exp_q15,
    f32,
    f32_bits,
    f32_to_bf16_bits,
    fp32_add,
    fp32_mul,
    load_lut,
    make_case,
    mathematical_reference,
    qk_score,
    q15_to_bf16_bits,
    q30_to_fp32_bits,
    read_hex_words,
    rope_vector,
)


SEQ_LEN = 128
Q_HEADS = 32
EXPECTED_ROWS = Q_HEADS * SEQ_LEN
EXPECTED_EXP = Q_HEADS * sum(range(1, SEQ_LEN + 1))
EXPECTED_RECIPROCAL = EXPECTED_ROWS
DEFAULT_SEED = 0xB200C0DE

# Immutable identities published with CATS_R4_INTERFACE_V3_COMMIT. These
# reports are historical software studies; accepting their identity does not
# turn them into current RTL, XSim, OOC, or board evidence.
OFFICIAL_REPORT_SHA256 = {
    "full": "1fe8cc632c0cef75d735ce9cd5f89778e1b5cf11d15f7a030555b04dc8d3dc86",
    "stress": "85bd41563851eb98b743607a0078c639c97c4a708f5ef6ad2354d602e88fc60a",
}
OFFICIAL_INPUT_PATHS = {
    "q": Path("vitis/data/q_before_rope_bf16.hex"),
    "k": Path("vitis/data/k_before_rope_bf16.hex"),
    "v": Path("vitis/data/v_bf16.hex"),
    "golden": Path("vitis/data/attn_out_per_head_bf16.hex"),
    "sine": Path("mem/sin_bf16.hex"),
    "cosine": Path("mem/cos_bf16.hex"),
    "lut": Path("mem/exp_lut_q15.mem"),
    "model": Path("python/flash_attention_tile_model.py"),
}
OFFICIAL_FULL_CANDIDATES = {
    "online_tile4",
    "row_normalized_bf16",
    "row_unnormalized_bf16",
    "row_fp32_software_exp",
}
OFFICIAL_STRESS_FAILURES = {
    "online_q15": 482,
    "row_q15": 459,
    "row_fp32_exp_software": 0,
}
OFFICIAL_CONTRACT = (
    "abs <= 1e-4 OR BF16 ordered distance <= 1; project contract, "
    "not verified official competition rule"
)
RR_LUT_SEGMENT_CANDIDATES = (16, 32, 64, 128)
RR_LUT_SELECTED_SEGMENTS = 32
LOG2_E_FP32 = f32(math.log2(math.e))


class CandidateAuditError(ValueError):
    """The recovered historical candidate artifact failed identity/schema audit."""


class NumericMode(str, Enum):
    COMPATIBILITY = "compatibility"
    ACCURACY = "accuracy"


@dataclass(frozen=True)
class RowResult:
    mode: str
    maximum_bf16: int | None
    weights_bf16: tuple[int, ...]
    weights_fp32: tuple[int, ...]
    probabilities_bf16: tuple[int, ...]
    sum_q15: int | None
    sum_fp32: int | None
    reciprocal_q30: int | None
    reciprocal_fp32: int
    numeric_error: bool


@dataclass
class WorkCounters:
    rows_issue: int = 0
    rows_result: int = 0
    rows_commit: int = 0
    exp_issue: int = 0
    exp_result: int = 0
    exp_commit: int = 0
    weight_issue: int = 0
    weight_result: int = 0
    weight_commit: int = 0
    sum_issue: int = 0
    sum_result: int = 0
    sum_commit: int = 0
    reciprocal_issue: int = 0
    reciprocal_result: int = 0
    reciprocal_commit: int = 0
    numeric_errors: int = 0

    def add_row(self, valid_keys: int, numeric_error: bool) -> None:
        self.rows_issue += 1
        self.rows_result += 1
        self.numeric_errors += int(numeric_error)
        if numeric_error:
            # The v3 Accuracy contract terminates an invalid row before exp,
            # weight, sum, reciprocal, or normal row commit is published.
            return
        self.rows_commit += 1
        self.exp_issue += valid_keys
        self.exp_result += valid_keys
        self.exp_commit += valid_keys
        self.weight_issue += valid_keys
        self.weight_result += valid_keys
        self.weight_commit += valid_keys
        self.sum_issue += valid_keys
        self.sum_result += valid_keys
        self.sum_commit += valid_keys
        self.reciprocal_issue += 1
        self.reciprocal_result += 1
        self.reciprocal_commit += 1


def _validate_row(scores_bf16: Sequence[int], masks: Sequence[bool]) -> None:
    if len(scores_bf16) != len(masks):
        raise ValueError("scores and masks must have the same length")
    if not scores_bf16:
        raise ValueError("a row must contain at least one score position")
    if len(scores_bf16) > SEQ_LEN:
        raise ValueError(f"row length exceeds S={SEQ_LEN}")
    if any(not 0 <= value <= 0xFFFF for value in scores_bf16):
        raise ValueError("scores must be raw 16-bit BF16 words")


def compatibility_row(
    scores_bf16: Sequence[int], masks: Sequence[bool], lut: Sequence[int]
) -> RowResult:
    """Mirror the declared Compatibility whole-row arithmetic."""

    _validate_row(scores_bf16, masks)
    fixed = [bf16_to_fixed(value) for value in scores_bf16]
    valid_indices = [index for index, masked in enumerate(masks) if not masked]
    if not valid_indices:
        return RowResult(
            mode=NumericMode.COMPATIBILITY.value,
            maximum_bf16=None,
            weights_bf16=tuple(0 for _ in scores_bf16),
            weights_fp32=tuple(0 for _ in scores_bf16),
            probabilities_bf16=tuple(0 for _ in scores_bf16),
            sum_q15=0,
            sum_fp32=f32_bits(0.0),
            reciprocal_q30=0,
            reciprocal_fp32=0,
            numeric_error=True,
        )

    maximum_fixed = max(fixed[index] for index in valid_indices)
    maximum_index = next(
        index for index in valid_indices if fixed[index] == maximum_fixed
    )
    weights_q15 = [
        exp_q15(maximum_fixed, score, masked, lut)
        for score, masked in zip(fixed, masks)
    ]
    denominator_q15 = sum(weights_q15)
    reciprocal_q30 = (
        (1 << 45) // denominator_q15 if denominator_q15 != 0 else 0
    )
    probabilities_bf16: list[int] = []
    for weight_q15 in weights_q15:
        probability_q15 = min(
            32768,
            (reciprocal_q30 * weight_q15 + (1 << 29)) >> 30,
        )
        probabilities_bf16.append(q15_to_bf16_bits(probability_q15))
    weights_bf16 = tuple(q15_to_bf16_bits(value) for value in weights_q15)
    return RowResult(
        mode=NumericMode.COMPATIBILITY.value,
        maximum_bf16=scores_bf16[maximum_index],
        weights_bf16=weights_bf16,
        # v3 unifies the slab payload at 32 bits. Compatibility occupies the
        # low 16 bits and requires the high 16 bits to be zero.
        weights_fp32=tuple(weights_bf16),
        probabilities_bf16=tuple(probabilities_bf16),
        sum_q15=denominator_q15,
        # Q*.15 is an integer scaled by 2^-15; the 23-bit causal maximum is
        # exactly representable in binary32 for the v3 row_commit payload.
        sum_fp32=f32_bits(denominator_q15 / 32768.0),
        reciprocal_q30=reciprocal_q30,
        reciprocal_fp32=q30_to_fp32_bits(reciprocal_q30),
        # Compatibility intentionally retains the existing project mapping:
        # an unmasked NaN maps through bf16_to_fixed as zero.  It is observable
        # through external special-value counters in RTL, not a mode switch.
        numeric_error=False,
    )


def write_compatibility_equal_row_metadata(
    path: Path, lut: Sequence[int]
) -> dict[str, object]:
    """Write max/sum/reciprocal vectors for 128 equal-score causal rows."""

    lines: list[str] = []
    for row in range(SEQ_LEN):
        result = compatibility_row(
            [0] * SEQ_LEN,
            [key > row for key in range(SEQ_LEN)],
            lut,
        )
        if result.sum_fp32 is None:
            raise AssertionError("Compatibility equal row produced no FP32 sum")
        lines.append(
            f"{result.maximum_bf16 or 0:04x}"
            f"{result.sum_fp32:08x}{result.reciprocal_fp32:08x}"
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="ascii")
    return {
        "status": "COMPATIBILITY_EQUAL_ROW_METADATA_WRITTEN",
        "path": str(path),
        "rows": SEQ_LEN,
        "sha256": sha256(path),
    }


def _accuracy_weights(
    scores_bf16: Sequence[int],
    masks: Sequence[bool],
    exp_function: Callable[[float], float] = math.exp,
) -> tuple[list[float], int | None, bool]:
    values = [bf16_bits_to_f32(value) for value in scores_bf16]
    valid = [index for index, masked in enumerate(masks) if not masked]
    if not valid:
        return [0.0 for _ in values], None, True
    if any(not math.isfinite(values[index]) for index in valid):
        return [0.0 for _ in values], None, True

    maximum_index = max(valid, key=lambda index: values[index])
    maximum = values[maximum_index]
    weights = []
    for index, (score, masked) in enumerate(zip(values, masks)):
        if masked:
            weights.append(f32(0.0))
        else:
            delta = f32(score - maximum)
            weights.append(f32(exp_function(delta)))
    return weights, maximum_index, False


def accuracy_row(
    scores_bf16: Sequence[int],
    masks: Sequence[bool],
    exp_function: Callable[[float], float] = math.exp,
) -> RowResult:
    """Evaluate the Accuracy candidate at explicit binary32 boundaries."""

    _validate_row(scores_bf16, masks)
    weights, maximum_index, numeric_error = _accuracy_weights(
        scores_bf16, masks, exp_function
    )
    if numeric_error:
        return RowResult(
            mode=NumericMode.ACCURACY.value,
            maximum_bf16=None,
            weights_bf16=tuple(0 for _ in scores_bf16),
            weights_fp32=tuple(0 for _ in scores_bf16),
            probabilities_bf16=tuple(0 for _ in scores_bf16),
            sum_q15=None,
            sum_fp32=0,
            reciprocal_q30=None,
            reciprocal_fp32=0,
            numeric_error=True,
        )

    denominator = f32(0.0)
    for weight in weights:
        denominator = f32(denominator + weight)
    reciprocal = f32(1.0 / denominator) if denominator != 0.0 else f32(0.0)
    probabilities = [f32(weight * reciprocal) for weight in weights]
    weights_bf16 = tuple(f32_to_bf16_bits(value) for value in weights)
    return RowResult(
        mode=NumericMode.ACCURACY.value,
        maximum_bf16=(
            None if maximum_index is None else scores_bf16[maximum_index]
        ),
        weights_bf16=weights_bf16,
        weights_fp32=tuple(f32_bits(value) for value in weights),
        probabilities_bf16=tuple(
            f32_to_bf16_bits(value) for value in probabilities
        ),
        sum_q15=None,
        sum_fp32=f32_bits(denominator),
        reciprocal_q30=None,
        reciprocal_fp32=f32_bits(reciprocal),
        numeric_error=False,
    )


@functools.lru_cache(maxsize=None)
def _exp2_negative_lut(segments: int) -> tuple[float, ...]:
    if segments <= 0 or segments & (segments - 1):
        raise ValueError("range-reduction LUT segments must be a positive power of two")
    return tuple(f32(2.0 ** (-index / segments)) for index in range(segments + 1))


def accuracy_exp_range_reduced_lut(
    delta: float, segments: int = RR_LUT_SELECTED_SEGMENTS
) -> float:
    """Hardware-oriented FP32 exp candidate for finite ``delta <= 0``.

    ``-delta`` is converted to base-2 using a binary32 ``log2(e)`` multiply.
    The integer part becomes an exponent shift and the fractional part uses a
    power-of-two-sized LUT with binary32 linear interpolation. Values at or
    below the binary32 half-minimum-subnormal boundary round to +0.
    """

    delta = f32(delta)
    if not math.isfinite(delta) or delta > 0.0:
        raise ValueError("Accuracy exp candidate requires finite delta <= 0")
    scaled = fp32_mul(f32(-delta), LOG2_E_FP32)
    exponent = int(math.floor(scaled))
    if exponent >= 150:
        return f32(0.0)
    fraction = f32(scaled - float(exponent))
    position = fp32_mul(fraction, f32(float(segments)))
    index = min(int(math.floor(position)), segments - 1)
    local = f32(position - float(index))
    lut = _exp2_negative_lut(segments)
    slope = fp32_add(lut[index + 1], -lut[index])
    interpolated = fp32_add(lut[index], fp32_mul(local, slope))
    return f32(math.ldexp(interpolated, -exponent))


def accuracy_row_range_reduced_lut(
    scores_bf16: Sequence[int],
    masks: Sequence[bool],
    segments: int = RR_LUT_SELECTED_SEGMENTS,
) -> RowResult:
    return accuracy_row(
        scores_bf16,
        masks,
        lambda delta: accuracy_exp_range_reduced_lut(delta, segments),
    )


def accuracy_context_range_reduced_lut(
    scores_bf16: Sequence[int],
    masks: Sequence[bool],
    values_bf16: Sequence[Sequence[int]],
    segments: int = RR_LUT_SELECTED_SEGMENTS,
) -> tuple[int, ...]:
    """Apply the v3 key-ordered FP32 PV/normalize boundary for model scoring."""

    if len(values_bf16) != len(scores_bf16) or not values_bf16:
        raise ValueError("V rows must match the score row")
    dimension = len(values_bf16[0])
    if any(len(row) != dimension for row in values_bf16):
        raise ValueError("all V rows must have the same feature dimension")
    row = accuracy_row_range_reduced_lut(scores_bf16, masks, segments)
    if row.numeric_error:
        return tuple(0 for _ in range(dimension))
    weights = [bits_to_f32(bits) for bits in row.weights_fp32]
    reciprocal = bits_to_f32(row.reciprocal_fp32)
    result: list[int] = []
    for feature in range(dimension):
        numerator = f32(0.0)
        for weight, value_row in zip(weights, values_bf16):
            product = fp32_mul(weight, bf16_bits_to_f32(value_row[feature]))
            numerator = fp32_add(numerator, product)
        normalized = fp32_mul(numerator, reciprocal)
        result.append(f32_to_bf16_bits(normalized))
    return tuple(result)


def run_accuracy_stress_sweep(
    segments: Sequence[int] = RR_LUT_SEGMENT_CANDIDATES,
) -> dict[str, object]:
    """Replay the published deterministic stress generator for LUT sizing."""

    selected = tuple(segments)
    if not selected:
        raise ValueError("at least one LUT segment candidate is required")
    metrics = {value: Metrics() for value in selected}
    counters = {value: WorkCounters() for value in selected}
    rng = random.Random(20260905)
    for case in range(32):
        scores, masks, values = make_case(
            rng,
            SEQ_LEN,
            SEQ_LEN,
            None if case % 2 else (case * 7) % SEQ_LEN,
        )
        reference = mathematical_reference(scores, masks, values)
        valid_keys = sum(not masked for masked in masks)
        for value in selected:
            row = accuracy_row_range_reduced_lut(scores, masks, value)
            actual = accuracy_context_range_reduced_lut(
                scores, masks, values, value
            )
            metrics[value].update(actual, reference)
            counters[value].add_row(valid_keys, row.numeric_error)
    return {
        "status": "SOFTWARE_OPERATOR_CANDIDATE_ONLY",
        "seed": 20260905,
        "cases": 32,
        "elements": 4096,
        "arithmetic": (
            "FP32 log2(e) range reduction, LUT linear interpolation, "
            "key-ordered FP32 sum/PV, reciprocal then multiply"
        ),
        "candidates": {
            str(value): {
                "lut_entries": value + 1,
                "metrics": asdict(metrics[value]),
                "counters": asdict(counters[value]),
            }
            for value in selected
        },
        "limitations": [
            "software emulation of proposed operator boundaries",
            "same deterministic generator as recovered historical stress report",
            "not Accuracy RTL/XSim/OOC/PPA/timing evidence",
        ],
    }


def independent_probabilities(
    scores_bf16: Sequence[int], masks: Sequence[bool]
) -> tuple[int, ...]:
    """Independent mathematical reference, separate from project RTL rules."""

    _validate_row(scores_bf16, masks)
    values = [bf16_bits_to_f32(value) for value in scores_bf16]
    valid = [index for index, masked in enumerate(masks) if not masked]
    if not valid or any(math.isnan(values[index]) for index in valid):
        return tuple(0 for _ in values)
    positive_inf = [index for index in valid if values[index] == math.inf]
    if positive_inf:
        probability = 1.0 / len(positive_inf)
        return tuple(
            f32_to_bf16_bits(probability if index in positive_inf else 0.0)
            for index in range(len(values))
        )
    if all(values[index] == -math.inf for index in valid):
        probability = 1.0 / len(valid)
        return tuple(
            f32_to_bf16_bits(0.0 if masked else probability)
            for masked in masks
        )
    maximum = max(values[index] for index in valid)
    weights = [
        0.0 if masked or score == -math.inf else math.exp(score - maximum)
        for score, masked in zip(values, masks)
    ]
    denominator = math.fsum(weights)
    return tuple(f32_to_bf16_bits(weight / denominator) for weight in weights)


def causal_workload_counters() -> WorkCounters:
    counters = WorkCounters()
    for _head in range(Q_HEADS):
        for row in range(SEQ_LEN):
            counters.add_row(row + 1, False)
    validate_counter_closure(counters)
    return counters


def validate_counter_closure(counters: WorkCounters) -> None:
    if not (
        counters.rows_issue
        == counters.rows_result
        == counters.rows_commit
        == EXPECTED_ROWS
    ):
        raise AssertionError("row issue/result/commit did not close")
    for prefix in ("exp", "weight", "sum"):
        values = tuple(
            getattr(counters, f"{prefix}_{suffix}")
            for suffix in ("issue", "result", "commit")
        )
        if values != (EXPECTED_EXP, EXPECTED_EXP, EXPECTED_EXP):
            raise AssertionError(f"{prefix} counter closure failed: {values}")
    reciprocal = (
        counters.reciprocal_issue,
        counters.reciprocal_result,
        counters.reciprocal_commit,
    )
    if reciprocal != (
        EXPECTED_RECIPROCAL,
        EXPECTED_RECIPROCAL,
        EXPECTED_RECIPROCAL,
    ):
        raise AssertionError(f"reciprocal counter closure failed: {reciprocal}")


def diagnostic_cases(seed: int, count: int) -> Iterable[tuple[list[int], list[bool]]]:
    directed = (
        ([0x3F80], [False]),
        ([0x3F80, 0x3F80, 0x3F80, 0x3F80], [False] * 4),
        ([0x0000, 0xC100, 0xC110], [False] * 3),
        ([0xBF80, 0x0000, 0x3F80, 0x4000], [False] * 4),
        ([0xFF80, 0xFF80], [False, False]),
        ([0x7F80, 0x3F80, 0x7F80], [False] * 3),
    )
    yield from directed
    rng = random.Random(seed)
    for _ in range(count):
        length = rng.randint(1, SEQ_LEN)
        scores = [
            f32_to_bf16_bits(rng.uniform(-20.0, 20.0))
            for _ in range(length)
        ]
        masks = [False] * length
        yield scores, masks


def run_diagnostics(lut: Sequence[int], seed: int, count: int) -> dict[str, object]:
    compatibility_metrics = Metrics()
    accuracy_metrics = Metrics()
    counters = {mode.value: WorkCounters() for mode in NumericMode}
    case_count = 0
    for scores, masks in diagnostic_cases(seed, count):
        reference = independent_probabilities(scores, masks)
        compatibility = compatibility_row(scores, masks, lut)
        accuracy = accuracy_row(scores, masks)
        compatibility_metrics.update(compatibility.probabilities_bf16, reference)
        # Accuracy metrics apply only to legal v3 rows. Non-finite scores are
        # rejection tests, not numerical comparison cases for legal inputs.
        if not accuracy.numeric_error:
            accuracy_metrics.update(accuracy.probabilities_bf16, reference)
        valid_keys = sum(not mask for mask in masks)
        counters[NumericMode.COMPATIBILITY.value].add_row(
            valid_keys, compatibility.numeric_error
        )
        counters[NumericMode.ACCURACY.value].add_row(
            valid_keys, accuracy.numeric_error
        )
        case_count += 1
    return {
        "status": "DIAGNOSTIC_ONLY",
        "configuration": {
            "seed": seed,
            "random_cases": count,
            "total_cases": case_count,
            "mode_selection": "explicit CLI/config only",
            "accuracy_legal_cases": (
                case_count
                - counters[NumericMode.ACCURACY.value].numeric_errors
            ),
            "accuracy_rejected_cases": counters[
                NumericMode.ACCURACY.value
            ].numeric_errors,
        },
        "compatibility_vs_independent_math": asdict(compatibility_metrics),
        "accuracy_vs_independent_math": asdict(accuracy_metrics),
        "counters": {
            mode: asdict(value) for mode, value in counters.items()
        },
        "full_causal_expected_counters": asdict(causal_workload_counters()),
    }


def run_accuracy_full_sweep(
    root: Path, segments: Sequence[int] = (32, 64)
) -> dict[str, object]:
    """Evaluate range-reduced Accuracy candidates on all stored vectors."""

    selected = tuple(segments)
    if not selected:
        raise ValueError("at least one LUT segment candidate is required")
    data = root / "vitis" / "data"
    q_words = read_hex_words(data / "q_before_rope_bf16.hex")
    k_words = read_hex_words(data / "k_before_rope_bf16.hex")
    v_words = read_hex_words(data / "v_bf16.hex")
    golden_words = read_hex_words(data / "attn_out_per_head_bf16.hex")
    sine = read_hex_words(root / "mem" / "sin_bf16.hex")
    cosine = read_hex_words(root / "mem" / "cos_bf16.hex")
    expected_sizes = (
        len(q_words) == 32 * 128 * 128,
        len(k_words) == 8 * 128 * 128,
        len(v_words) == 8 * 128 * 128,
        len(golden_words) == 32 * 128 * 128,
        len(sine) == 128 * 64,
        len(cosine) == 128 * 64,
    )
    if not all(expected_sizes):
        raise ValueError("authoritative board vector dimensions do not match")

    def tensor_row(words: Sequence[int], head: int, row: int) -> list[int]:
        base = (head * 128 + row) * 128
        return list(words[base : base + 128])

    metrics = {value: Metrics() for value in selected}
    counters = {value: WorkCounters() for value in selected}
    worst: dict[int, dict[str, object] | None] = {
        value: None for value in selected
    }
    failure_examples: dict[int, list[dict[str, object]]] = {
        value: [] for value in selected
    }
    k_cache: dict[tuple[int, int], list[int]] = {}
    for head in range(Q_HEADS):
        kv_head = head // 4
        for row in range(SEQ_LEN):
            q_rotated = rope_vector(
                tensor_row(q_words, head, row), row, sine, cosine
            )
            scores: list[int] = []
            values: list[list[int]] = []
            for key in range(row + 1):
                cache_key = (kv_head, key)
                if cache_key not in k_cache:
                    k_cache[cache_key] = rope_vector(
                        tensor_row(k_words, kv_head, key),
                        key,
                        sine,
                        cosine,
                    )
                scores.append(qk_score(q_rotated, k_cache[cache_key]))
                values.append(tensor_row(v_words, kv_head, key))
            masks = [False] * len(scores)
            expected = tensor_row(golden_words, head, row)
            for value in selected:
                actual = accuracy_context_range_reduced_lut(
                    scores, masks, values, value
                )
                metrics[value].update(actual, expected)
                counters[value].add_row(row + 1, False)
                for feature, (got, want) in enumerate(zip(actual, expected)):
                    absolute = abs(
                        bf16_bits_to_f32(got) - bf16_bits_to_f32(want)
                    )
                    distance = bf16_ulp_distance(got, want)
                    previous = worst[value]
                    if previous is None or absolute > float(previous["absolute_error"]):
                        worst[value] = {
                            "head": head,
                            "row": row,
                            "feature": feature,
                            "actual_bf16": f"0x{got:04X}",
                            "expected_bf16": f"0x{want:04X}",
                            "absolute_error": absolute,
                            "bf16_ulp_distance": distance,
                        }
                    if (
                        absolute > 1.0e-4
                        and distance > 1
                        and len(failure_examples[value]) < 5
                    ):
                        failure_examples[value].append(
                            {
                                "head": head,
                                "row": row,
                                "feature": feature,
                                "actual_bf16": f"0x{got:04X}",
                                "expected_bf16": f"0x{want:04X}",
                                "absolute_error": absolute,
                                "bf16_ulp_distance": distance,
                            }
                        )
        print(
            f"Accuracy full sweep completed head {head + 1}/{Q_HEADS}",
            file=sys.stderr,
            flush=True,
        )

    for value in selected:
        validate_counter_closure(counters[value])
    input_paths = tuple(root / relative for relative in OFFICIAL_INPUT_PATHS.values())
    return {
        "status": "SOFTWARE_OPERATOR_CANDIDATE_ONLY",
        "configuration": {
            "heads": Q_HEADS,
            "rows_per_head": SEQ_LEN,
            "elements": EXPECTED_ROWS * SEQ_LEN,
            "segments": list(selected),
            "reference": "stored project golden BF16 Context",
        },
        "arithmetic": (
            "FP32 log2(e) range reduction, LUT linear interpolation, "
            "key-ordered FP32 sum/PV, reciprocal then multiply"
        ),
        "candidates": {
            str(value): {
                "lut_entries": value + 1,
                "metrics": asdict(metrics[value]),
                "counters": asdict(counters[value]),
                "worst_absolute_element": worst[value],
                "combined_failure_examples": failure_examples[value],
            }
            for value in selected
        },
        "input_sha256": {
            str(path.relative_to(root)).replace("\\", "/"): sha256(path)
            for path in input_paths
        },
        "limitations": [
            "software emulation of proposed operator boundaries",
            "uses stored project vectors and golden, not independent hidden tests",
            "not Accuracy RTL/XSim/OOC/PPA/timing evidence",
        ],
    }


def run_authoritative_full_diagnostic(
    root: Path, lut: Sequence[int]
) -> dict[str, object]:
    """Evaluate whole-row Compatibility on repository board vectors.

    This intentionally remains a software diagnostic.  It records the worst
    element and actual software work counters, but it cannot stand in for the
    recovered historical report identity or for RTL/full-system counters.
    """

    data = root / "vitis" / "data"
    q_words = read_hex_words(data / "q_before_rope_bf16.hex")
    k_words = read_hex_words(data / "k_before_rope_bf16.hex")
    v_words = read_hex_words(data / "v_bf16.hex")
    golden_words = read_hex_words(data / "attn_out_per_head_bf16.hex")
    sine = read_hex_words(root / "mem" / "sin_bf16.hex")
    cosine = read_hex_words(root / "mem" / "cos_bf16.hex")
    expected_sizes = (
        len(q_words) == 32 * 128 * 128,
        len(k_words) == 8 * 128 * 128,
        len(v_words) == 8 * 128 * 128,
        len(golden_words) == 32 * 128 * 128,
        len(sine) == 128 * 64,
        len(cosine) == 128 * 64,
    )
    if not all(expected_sizes):
        raise ValueError("authoritative board vector dimensions do not match")

    def tensor_row(words: Sequence[int], head: int, row: int) -> list[int]:
        base = (head * 128 + row) * 128
        return list(words[base : base + 128])

    metrics = Metrics()
    counters = WorkCounters()
    worst: dict[str, object] | None = None
    k_cache: dict[tuple[int, int], list[int]] = {}
    for head in range(32):
        kv_head = head // 4
        for row in range(128):
            q_rotated = rope_vector(
                tensor_row(q_words, head, row), row, sine, cosine
            )
            scores: list[int] = []
            values: list[list[int]] = []
            for key in range(128):
                cache_key = (kv_head, key)
                if cache_key not in k_cache:
                    k_cache[cache_key] = rope_vector(
                        tensor_row(k_words, kv_head, key),
                        key,
                        sine,
                        cosine,
                    )
                scores.append(
                    qk_score(q_rotated, k_cache[cache_key])
                    if key <= row
                    else 0xFF80
                )
                values.append(tensor_row(v_words, kv_head, key))
            masks = [key > row for key in range(128)]
            actual = baseline_v30(scores, masks, values, lut)
            expected = tensor_row(golden_words, head, row)
            metrics.update(actual, expected)
            counters.add_row(row + 1, False)
            for feature, (got, want) in enumerate(zip(actual, expected)):
                absolute = abs(
                    bf16_bits_to_f32(got) - bf16_bits_to_f32(want)
                )
                distance = bf16_ulp_distance(got, want)
                if worst is None or absolute > float(worst["absolute_error"]):
                    worst = {
                        "head": head,
                        "row": row,
                        "feature": feature,
                        "actual_bf16": f"0x{got:04X}",
                        "expected_bf16": f"0x{want:04X}",
                        "actual": bf16_bits_to_f32(got),
                        "expected": bf16_bits_to_f32(want),
                        "absolute_error": absolute,
                        "bf16_ulp_distance": distance,
                    }
    validate_counter_closure(counters)
    input_paths = (
        root / "mem" / "exp_lut_q15.mem",
        root / "mem" / "sin_bf16.hex",
        root / "mem" / "cos_bf16.hex",
        data / "q_before_rope_bf16.hex",
        data / "k_before_rope_bf16.hex",
        data / "v_bf16.hex",
        data / "attn_out_per_head_bf16.hex",
    )
    return {
        "status": "SOFTWARE_DIAGNOSTIC_ONLY",
        "configuration": {
            "mode": NumericMode.COMPATIBILITY.value,
            "rows": EXPECTED_ROWS,
            "elements": EXPECTED_ROWS * 128,
            "source": "repository authoritative board vectors",
        },
        "metrics": asdict(metrics),
        "worst_absolute_element": worst,
        "counters": asdict(counters),
        "input_sha256": {
            str(path.relative_to(root)): sha256(path) for path in input_paths
        },
        "limitations": [
            "software candidate only",
            "separate from the recovered aggregate row_candidates_full.json",
            "not RTL/XSim/OOC/board evidence",
        ],
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _audit_require(condition: bool, message: str) -> None:
    if not condition:
        raise CandidateAuditError(message)


def audit_official_candidate_reports(
    root: Path, full_path: Path, stress_path: Path
) -> dict[str, object]:
    """Audit recovered report identity and scope without rerunning the study.

    The JSON files contain aggregate historical results, not row vectors. This
    adapter verifies immutable bytes, schema, workload/metric scope, and the
    current repository input identities. It deliberately does not claim that
    the current B2 RTL reproduced those results.
    """

    _audit_require(full_path.is_file(), f"missing full report: {full_path}")
    _audit_require(stress_path.is_file(), f"missing stress report: {stress_path}")
    report_hashes = {
        "full": sha256(full_path),
        "stress": sha256(stress_path),
    }
    for name, expected in OFFICIAL_REPORT_SHA256.items():
        _audit_require(
            report_hashes[name] == expected,
            f"{name} report SHA256 mismatch",
        )

    try:
        full = json.loads(full_path.read_text(encoding="utf-8"))
        stress = json.loads(stress_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeError) as error:
        raise CandidateAuditError(f"candidate report JSON is invalid: {error}") from error

    try:
        _audit_require(full["scope"] == "Full stored dataset", "full scope mismatch")
        _audit_require(full["heads"] == list(range(Q_HEADS)), "full head coverage mismatch")
        _audit_require(full["rows"] == list(range(SEQ_LEN)), "full row coverage mismatch")
        _audit_require(
            full["output_elements"] == EXPECTED_ROWS * SEQ_LEN,
            "full output count mismatch",
        )
        _audit_require(full["contract"] == OFFICIAL_CONTRACT, "metric contract changed")
        _audit_require(
            set(full["metrics"]) == OFFICIAL_FULL_CANDIDATES,
            "full candidate set mismatch",
        )
        for name, metrics in full["metrics"].items():
            _audit_require(
                metrics["elements"] == EXPECTED_ROWS * SEQ_LEN,
                f"full element count mismatch: {name}",
            )
            _audit_require(
                metrics["combined_failures"] == 0,
                f"full historical combined failures changed: {name}",
            )

        _audit_require(
            (stress["seed"], stress["cases"], stress["elements"])
            == (20260905, 32, 4096),
            "stress scope mismatch",
        )
        _audit_require(
            set(stress["metrics"]) == set(OFFICIAL_STRESS_FAILURES),
            "stress candidate set mismatch",
        )
        for name, expected_failures in OFFICIAL_STRESS_FAILURES.items():
            _audit_require(
                stress["metrics"][name]["elements"] == 4096,
                f"stress element count mismatch: {name}",
            )
            _audit_require(
                stress["metrics"][name]["combined_failures"]
                == expected_failures,
                f"stress historical combined failures changed: {name}",
            )

        input_hashes: dict[str, str] = {}
        for name, relative_path in OFFICIAL_INPUT_PATHS.items():
            current_path = root / relative_path
            _audit_require(current_path.is_file(), f"missing current input: {relative_path}")
            current_hash = sha256(current_path)
            _audit_require(
                current_hash == full["inputs"][name]["sha256"],
                f"current input differs from historical bytes: {relative_path}",
            )
            input_hashes[str(relative_path).replace("\\", "/")] = current_hash
    except (KeyError, TypeError) as error:
        raise CandidateAuditError(f"candidate report schema mismatch: {error}") from error

    return {
        "status": "HISTORICAL_ARTIFACT_AUDIT_PASS",
        "interface": {
            "tag": "CATS_R4_INTERFACE_V3_COMMIT",
            "version": "0x00030000",
        },
        "report_sha256": report_hashes,
        "input_sha256": input_hashes,
        "full": {
            "rows": EXPECTED_ROWS,
            "elements": EXPECTED_ROWS * SEQ_LEN,
            "combined_failures": {
                name: full["metrics"][name]["combined_failures"]
                for name in sorted(OFFICIAL_FULL_CANDIDATES)
            },
        },
        "stress": {
            "seed": stress["seed"],
            "cases": stress["cases"],
            "elements": stress["elements"],
            "combined_failures": {
                name: stress["metrics"][name]["combined_failures"]
                for name in OFFICIAL_STRESS_FAILURES
            },
        },
        "current_b2_implementation_gate": "NOT_READY",
        "limitations": [
            "recovered historical aggregate software reports only",
            "JSON contains no per-row vectors for replay",
            "Accuracy uses Python math.exp, not a validated hardware approximation",
            "not current RTL/XSim/OOC/board evidence",
        ],
    }


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--lut", type=Path, default=root / "mem" / "exp_lut_q15.mem"
    )
    parser.add_argument(
        "--full-candidates",
        type=Path,
        default=(
            root
            / "docs"
            / "architecture_study_20260905"
            / "row_candidates_full.json"
        ),
    )
    parser.add_argument(
        "--stress-candidates",
        type=Path,
        default=(
            root
            / "docs"
            / "architecture_study_20260905"
            / "row_candidates_stress.json"
        ),
    )
    parser.add_argument("--diagnostic", action="store_true")
    parser.add_argument("--compat-equal-row-metadata-vectors", type=Path)
    study = parser.add_mutually_exclusive_group()
    study.add_argument("--authoritative-full-diagnostic", action="store_true")
    study.add_argument("--accuracy-stress-sweep", action="store_true")
    study.add_argument("--accuracy-full-sweep", action="store_true")
    parser.add_argument("--segments", nargs="+", type=int, default=[32, 64])
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=DEFAULT_SEED)
    parser.add_argument("--cases", type=int, default=256)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()

    if args.compat_equal_row_metadata_vectors is not None:
        result = write_compatibility_equal_row_metadata(
            args.compat_equal_row_metadata_vectors, load_lut(args.lut)
        )
        print(json.dumps(result, sort_keys=True))
        return 0

    missing = [
        str(path)
        for path in (args.full_candidates, args.stress_candidates)
        if not path.is_file()
    ]
    if args.authoritative_full_diagnostic:
        lut = load_lut(args.lut)
        result = run_authoritative_full_diagnostic(root, lut)
        rendered = json.dumps(result, indent=2, sort_keys=True)
        print(rendered)
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(rendered + "\n", encoding="utf-8")
        return 0

    if args.accuracy_stress_sweep or args.accuracy_full_sweep:
        result = (
            run_accuracy_full_sweep(root, args.segments) if args.accuracy_full_sweep
            else run_accuracy_stress_sweep(args.segments)
        )
        rendered = json.dumps(result, indent=2, sort_keys=True)
        print(rendered)
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(rendered + "\n", encoding="utf-8")
        return 0

    if not args.diagnostic:
        if missing:
            result = {
                "status": "BLOCKED",
                "reason": "required B2 candidate input files are missing",
                "missing": missing,
                "input_sha256": {},
                "expected_exp": EXPECTED_EXP,
                "expected_rows": EXPECTED_ROWS,
            }
            return_code = 2
        else:
            try:
                result = audit_official_candidate_reports(
                    root, args.full_candidates, args.stress_candidates
                )
                return_code = 0
            except (CandidateAuditError, OSError) as error:
                result = {
                    "status": "AUDIT_FAILED",
                    "reason": str(error),
                    "missing": [],
                }
                return_code = 1
        rendered = json.dumps(result, indent=2, sort_keys=True)
        print(rendered)
        if args.json:
            args.json.parent.mkdir(parents=True, exist_ok=True)
            args.json.write_text(rendered + "\n", encoding="utf-8")
        return return_code

    lut = load_lut(args.lut)
    result = run_diagnostics(lut, args.seed, args.cases)
    result["inputs"] = {
        "lut": str(args.lut),
        "lut_sha256": sha256(args.lut),
        "official_candidate_files_missing": missing,
    }
    rendered = json.dumps(result, indent=2, sort_keys=True)
    print(rendered)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(rendered + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
