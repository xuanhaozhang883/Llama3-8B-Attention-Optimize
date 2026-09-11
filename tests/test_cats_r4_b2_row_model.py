import importlib.util
import math
import sys
import tempfile
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PYTHON_DIR = ROOT / "python"
if str(PYTHON_DIR) not in sys.path:
    sys.path.insert(0, str(PYTHON_DIR))
MODEL_PATH = PYTHON_DIR / "cats_r4_b2_row_model.py"
SPEC = importlib.util.spec_from_file_location("cats_r4_b2_row_model", MODEL_PATH)
assert SPEC is not None and SPEC.loader is not None
MODEL = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODEL
SPEC.loader.exec_module(MODEL)
LUT = MODEL.load_lut(ROOT / "mem" / "exp_lut_q15.mem")


def test_full_causal_counter_closure() -> None:
    counters = MODEL.causal_workload_counters()
    assert counters.rows_commit == 4_096
    assert counters.exp_issue == 264_192
    assert counters.exp_issue == counters.exp_result == counters.exp_commit
    assert counters.weight_issue == counters.weight_result == counters.weight_commit
    assert counters.sum_issue == counters.sum_result == counters.sum_commit
    assert counters.reciprocal_commit == 4_096


def test_compatibility_preserves_q15_lut_bf16_weight_and_floor_reciprocal() -> None:
    row = MODEL.compatibility_row([0x3F80, 0x0000], [False, False], LUT)
    assert row.maximum_bf16 == 0x3F80
    assert row.weights_bf16 == (
        MODEL.q15_to_bf16_bits(LUT[0]),
        MODEL.q15_to_bf16_bits(LUT[64]),
    )
    assert row.sum_q15 == LUT[0] + LUT[64]
    assert row.sum_fp32 == MODEL.f32_bits(row.sum_q15 / 32768.0)
    assert row.reciprocal_q30 == (1 << 45) // row.sum_q15
    assert row.reciprocal_fp32 == MODEL.q30_to_fp32_bits(row.reciprocal_q30)
    assert row.weights_fp32 == row.weights_bf16
    assert all(payload >> 16 == 0 for payload in row.weights_fp32)


def test_compatibility_cutoff_is_not_inherited_by_accuracy() -> None:
    # max-score=9: legacy Compatibility truncates, Accuracy stays non-zero.
    scores = [MODEL.f32_to_bf16_bits(0.0), MODEL.f32_to_bf16_bits(-9.0)]
    compatibility = MODEL.compatibility_row(scores, [False, False], LUT)
    accuracy = MODEL.accuracy_row(scores, [False, False])
    assert compatibility.weights_bf16[1] == 0
    assert accuracy.weights_fp32[1] != 0
    assert MODEL.bf16_bits_to_f32(accuracy.weights_bf16[1]) > 0.0


def test_accuracy_uses_global_max_and_key_ordered_fp32_sum() -> None:
    scores = [
        MODEL.f32_to_bf16_bits(-4.0),
        MODEL.f32_to_bf16_bits(-3.0),
        MODEL.f32_to_bf16_bits(6.0),
        MODEL.f32_to_bf16_bits(-2.0),
    ]
    row = MODEL.accuracy_row(scores, [False] * len(scores))
    assert row.maximum_bf16 == scores[2]
    expected = MODEL.f32(0.0)
    for score in scores:
        expected = MODEL.f32(
            expected
            + MODEL.f32(
                math.exp(MODEL.bf16_bits_to_f32(score) - 6.0)
            )
        )
    assert row.sum_fp32 == MODEL.f32_bits(expected)


def test_accuracy_special_values_are_explicit_and_deterministic() -> None:
    positive_inf = MODEL.accuracy_row(
        [0x7F80, 0x3F80, 0x7F80], [False, False, False]
    )
    assert positive_inf.numeric_error is True
    assert positive_inf.probabilities_bf16 == (0, 0, 0)

    nan_row = MODEL.accuracy_row([0x7FC1, 0x3F80], [False, False])
    assert nan_row.numeric_error is True
    assert nan_row.probabilities_bf16 == (0, 0)

    negative_inf = MODEL.accuracy_row([0xFF80, 0xFF80], [False, False])
    assert negative_inf.numeric_error is True
    assert negative_inf.probabilities_bf16 == (0, 0)

    finite_underflow = MODEL.accuracy_row([0x0000, 0xC77F], [False, False])
    assert finite_underflow.numeric_error is False
    assert finite_underflow.weights_fp32[0] == MODEL.f32_bits(1.0)
    assert finite_underflow.weights_fp32[1] == MODEL.f32_bits(0.0)

    compatibility_masked = MODEL.compatibility_row(
        [0x3F80, 0x4000], [True, True], LUT
    )
    accuracy_masked = MODEL.accuracy_row(
        [0x3F80, 0x4000], [True, True]
    )
    assert compatibility_masked.numeric_error is True
    assert accuracy_masked.numeric_error is True
    assert compatibility_masked.reciprocal_fp32 == 0
    assert accuracy_masked.reciprocal_fp32 == 0


def test_diagnostics_are_mode_explicit_and_accuracy_has_no_combined_failures() -> None:
    report = MODEL.run_diagnostics(LUT, MODEL.DEFAULT_SEED, 128)
    assert report["configuration"]["mode_selection"] == "explicit CLI/config only"
    assert report["configuration"]["accuracy_rejected_cases"] == 2
    assert report["accuracy_vs_independent_math"]["combined_failures"] == 0


def test_range_reduced_exp_has_no_legacy_cutoff_and_bounded_grid_error() -> None:
    relative_errors = []
    previous = 0.0
    for index in range(26_625):
        delta = -104.0 + index / 256.0
        expected = MODEL.f32(math.exp(delta))
        actual = MODEL.accuracy_exp_range_reduced_lut(delta)
        if expected >= 2.0 ** -126:
            relative_errors.append(abs(actual - expected) / expected)
        assert actual >= previous
        previous = actual
    assert MODEL.RR_LUT_SELECTED_SEGMENTS == 32
    assert max(relative_errors) < 6.3e-5
    assert MODEL.accuracy_exp_range_reduced_lut(-9.0) > 0.0
    assert MODEL.accuracy_exp_range_reduced_lut(-104.0) == 0.0


def test_stress_sweep_selects_at_least_32_lut_segments() -> None:
    report = MODEL.run_accuracy_stress_sweep((16, 32, 64))
    assert report["status"] == "SOFTWARE_OPERATOR_CANDIDATE_ONLY"
    assert report["candidates"]["16"]["metrics"]["combined_failures"] == 3
    assert report["candidates"]["32"]["metrics"]["combined_failures"] == 0
    assert report["candidates"]["64"]["metrics"]["combined_failures"] == 0


def test_recovered_candidate_reports_are_audited_without_relabeling() -> None:
    archive = ROOT / "docs" / "architecture_study_20260905"
    report = MODEL.audit_official_candidate_reports(
        ROOT,
        archive / "row_candidates_full.json",
        archive / "row_candidates_stress.json",
    )
    assert report["status"] == "HISTORICAL_ARTIFACT_AUDIT_PASS"
    assert report["interface"]["tag"] == "CATS_R4_INTERFACE_V3_COMMIT"
    assert report["full"]["rows"] == 4_096
    assert report["full"]["elements"] == 524_288
    assert all(value == 0 for value in report["full"]["combined_failures"].values())
    assert report["stress"]["combined_failures"]["row_q15"] == 459
    assert report["stress"]["combined_failures"]["row_fp32_exp_software"] == 0
    assert report["current_b2_implementation_gate"] == "NOT_READY"
    assert "JSON contains no per-row vectors for replay" in report["limitations"]


def test_recovered_candidate_report_identity_is_immutable() -> None:
    archive = ROOT / "docs" / "architecture_study_20260905"
    with tempfile.TemporaryDirectory() as directory:
        temporary = Path(directory)
        full_path = temporary / "row_candidates_full.json"
        stress_path = temporary / "row_candidates_stress.json"
        full_path.write_bytes(
            (archive / "row_candidates_full.json").read_bytes() + b"\n"
        )
        stress_path.write_bytes(
            (archive / "row_candidates_stress.json").read_bytes()
        )
        try:
            MODEL.audit_official_candidate_reports(
                ROOT, full_path, stress_path
            )
        except MODEL.CandidateAuditError as error:
            assert "full report SHA256 mismatch" in str(error)
        else:
            raise AssertionError("modified recovered report was accepted")


if __name__ == "__main__":
    test_full_causal_counter_closure()
    test_compatibility_preserves_q15_lut_bf16_weight_and_floor_reciprocal()
    test_compatibility_cutoff_is_not_inherited_by_accuracy()
    test_accuracy_uses_global_max_and_key_ordered_fp32_sum()
    test_accuracy_special_values_are_explicit_and_deterministic()
    test_diagnostics_are_mode_explicit_and_accuracy_has_no_combined_failures()
    test_range_reduced_exp_has_no_legacy_cutoff_and_bounded_grid_error()
    test_stress_sweep_selects_at_least_32_lut_segments()
    test_recovered_candidate_reports_are_audited_without_relabeling()
    test_recovered_candidate_report_identity_is_immutable()
    print("CATS-R4 B2 row model tests: PASS")
