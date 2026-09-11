import math
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PYTHON_DIR = ROOT / "python"
if str(PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(PYTHON_DIR))

import cats_r4_b2_accuracy_fixed_model as fixed
import cats_r4_b2_row_model as base


def test_fixed_exp_directed_boundaries() -> None:
    maximum = base.f32_to_bf16_bits(0.0)
    assert fixed.accuracy_exp_fixed_bits(maximum, maximum) == 0x3F800000
    assert fixed.accuracy_exp_fixed_bits(
        maximum, base.f32_to_bf16_bits(-9.0)
    ) != 0
    assert fixed.accuracy_exp_fixed_bits(
        maximum, base.f32_to_bf16_bits(-103.0)
    ) == 0x00000001
    assert fixed.accuracy_exp_fixed_bits(
        maximum, base.f32_to_bf16_bits(-104.0)
    ) == 0


def test_fixed_exp_grid_is_monotonic_and_bounded() -> None:
    maximum = base.f32_to_bf16_bits(0.0)
    previous = 0.0
    relative_errors: list[float] = []
    for index in range(26_625):
        requested = -104.0 + index / 256.0
        score_bf16 = base.f32_to_bf16_bits(requested)
        score = base.bf16_bits_to_f32(score_bf16)
        actual = base.bits_to_f32(
            fixed.accuracy_exp_fixed_bits(maximum, score_bf16)
        )
        expected = base.f32(math.exp(score))
        if expected >= 2.0**-126:
            relative_errors.append(abs(actual - expected) / expected)
        assert actual >= previous
        previous = actual
    assert max(relative_errors) < 5.0e-4


def test_row_rejects_nonfinite_or_incorrect_maximum() -> None:
    assert fixed.accuracy_row_fixed([0x7F80], [False]).numeric_error
    assert fixed.accuracy_row_fixed(
        [0x3F80], [False], row_max_bf16=0x4000
    ).numeric_error
    assert fixed.accuracy_row_fixed([0x3F80], [True]).numeric_error


def test_row_sum_is_key_ordered_fp32() -> None:
    scores = [
        base.f32_to_bf16_bits(value) for value in (-4.0, -3.0, 6.0, -2.0)
    ]
    row = fixed.accuracy_row_fixed(scores, [False] * len(scores))
    assert row.maximum_bf16 == scores[2]
    expected_sum = base.f32(0.0)
    for weight_bits in row.weights_fp32:
        expected_sum = base.fp32_add(
            expected_sum, base.bits_to_f32(weight_bits)
        )
    assert row.sum_fp32 == base.f32_bits(expected_sum)


def test_fixed_stress_closes_without_combined_failures() -> None:
    report = fixed.run_fixed_stress_sweep()
    candidate = report["candidates"]["32"]
    assert candidate["metrics"]["combined_failures"] == 0
    assert candidate["metrics"]["elements"] == 4_096
    counters = candidate["counters"]
    assert counters["rows_commit"] == 32
    assert counters["exp_issue"] == counters["exp_result"]
    assert counters["exp_result"] == counters["exp_commit"] == 2_976
    assert "whole-row RTL exists" in report["limitations"][-1]


def test_equal_row_metadata_vectors() -> None:
    with tempfile.TemporaryDirectory() as directory:
        vector_path = Path(directory) / "equal_rows.hex"
        fixed.write_equal_row_metadata_vectors(vector_path)
        lines = vector_path.read_text(encoding="ascii").splitlines()
        assert len(lines) == 128
        assert lines[0] == "3F8000003F800000"
        assert lines[1] == "400000003F000000"
        assert lines[-1] == "430000003C000000"


if __name__ == "__main__":
    test_fixed_exp_directed_boundaries()
    test_fixed_exp_grid_is_monotonic_and_bounded()
    test_row_rejects_nonfinite_or_incorrect_maximum()
    test_row_sum_is_key_ordered_fp32()
    test_fixed_stress_closes_without_combined_failures()
    test_equal_row_metadata_vectors()
    print("CATS-R4 B2 Accuracy fixed model tests: PASS")
