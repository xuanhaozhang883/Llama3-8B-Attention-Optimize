#!/usr/bin/env python3
"""Unit checks for the v3.1 board-log signoff gate."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from signoff_v31_board_log import SignoffError, signoff  # noqa: E402


def make_log(cycles: int = 50_000_000, bad_v_vectors: bool = False,
             causal_bypass: bool = False) -> str:
    lines = ["[PASS] Warm-up correctness gate passed"]
    for run in range(1, 11):
        lines.append(f"PERF_CSV,{run},1,2,0x1,20,3,0")
        hw_values = [
            cycles, 1, cycles - 1, 0, 0, cycles - 1, 0, 0, 0, 0, 0,
            327680, 196608, 131072, 524288,
            1, 1, 1, 1, 1, 1, 1, 1, 5121, 1024, 0,
        ]
        lines.append("HWPROF_CSV," + str(run) + "," +
                     ",".join(str(value) for value in hw_values))
        processed = 16_896 if causal_bypass else 32_768
        bypassed = 15_872 if causal_bypass else 0
        vectors_expected = 1_081_344 if causal_bypass else 2_097_152
        vectors = (vectors_expected - 1
                   if bad_v_vectors and run == 4 else vectors_expected)
        lines.append(
            f"V26_CAUSAL_CSV,{run},16896,15872,15872,"
            f"{processed},{bypassed},{vectors},0x0")
        lines.append(
            f"V31_FLASH_CSV,{run},{processed},{bypassed},{vectors},0x0")
    lines.append("PERF_SUMMARY_CSV,10,10,1,2,3,0,1,1,1")
    lines.append(
        "[PASS] v3.1 FlashAttention ten-run correctness and profiling passed")
    return "\n".join(lines)


def replace_csv_field(text: str, tag: str, run: int,
                      field: int, value: str) -> str:
    updated: list[str] = []
    found = False
    for line in text.splitlines():
        parts = line.split(",")
        if len(parts) > 1 and parts[0] == tag and int(parts[1]) == run:
            parts[field] = value
            line = ",".join(parts)
            found = True
        updated.append(line)
    if not found:
        raise AssertionError(f"missing {tag} run {run}")
    return "\n".join(updated)


class BoardLogSignoffTest(unittest.TestCase):
    def test_legacy_complete_fast_log_passes_unchanged(self) -> None:
        result = signoff(make_log())
        self.assertTrue(result["performance_gate_passed"])
        self.assertEqual(result["total_pl_cycles"]["average"], 50_000_000)
        self.assertEqual(result["consumer_profile"],
                         "legacy-v313")
        self.assertEqual(result["causal_tiles_bypassed_per_run"], 0)

    def test_v314_complete_fast_log_passes(self) -> None:
        result = signoff(make_log(causal_bypass=True),
                         profile="v314-causal-bypass")
        self.assertEqual(result["consumer_profile"],
                         "v314-causal-bypass")
        self.assertEqual(result["flash_context_tiles_per_run"], 16_896)
        self.assertEqual(result["causal_tiles_bypassed_per_run"], 15_872)
        self.assertEqual(result["v_vectors_read_per_run"], 1_081_344)

    def test_profile_must_match_log(self) -> None:
        with self.assertRaisesRegex(SignoffError,
                                    "Flash Context tiles processed"):
            signoff(make_log(causal_bypass=True))

    def test_slow_log_fails_performance_gate(self) -> None:
        with self.assertRaisesRegex(SignoffError, "speedup gate"):
            signoff(make_log(cycles=60_000_000))

    def test_v314_wrong_counter_fails(self) -> None:
        log = replace_csv_field(make_log(causal_bypass=True),
                                "V26_CAUSAL_CSV", 4, 5, "16895")
        with self.assertRaisesRegex(SignoffError,
                                    "Flash Context tiles processed"):
            signoff(log, profile="v314-causal-bypass")

    def test_missing_run_fails(self) -> None:
        log = "\n".join(
            line for line in make_log().splitlines()
            if not line.startswith("PERF_CSV,7,"))
        with self.assertRaisesRegex(SignoffError, "expected 1..10"):
            signoff(log)

    def test_duplicate_run_fails(self) -> None:
        log = make_log()
        duplicate = next(
            line for line in log.splitlines()
            if line.startswith("V31_FLASH_CSV,4,"))
        with self.assertRaisesRegex(SignoffError,
                                    "duplicate V31_FLASH_CSV run 4"):
            signoff(log + "\n" + duplicate)

    def test_error_detail_flag_fails(self) -> None:
        log = replace_csv_field(make_log(), "HWPROF_CSV", 3, 27, "1")
        with self.assertRaisesRegex(SignoffError, "error detail bitmap"):
            signoff(log)

    def test_causal_error_flag_fails(self) -> None:
        log = replace_csv_field(make_log(causal_bypass=True),
                                "V26_CAUSAL_CSV", 3, 8, "0x1")
        with self.assertRaisesRegex(SignoffError, "causal error flags"):
            signoff(log, profile="v314-causal-bypass")

    def test_combined_failure_flag_fails(self) -> None:
        log = replace_csv_field(make_log(), "PERF_CSV", 6, 7, "1")
        with self.assertRaisesRegex(SignoffError, "Combined failures"):
            signoff(log)

    def test_nondeterministic_mismatch_statistics_fail(self) -> None:
        log = replace_csv_field(make_log(), "PERF_CSV", 8, 5, "21")
        with self.assertRaisesRegex(
                SignoffError, "mismatch counts changed"):
            signoff(log)

    def test_missing_warmup_marker_fails(self) -> None:
        log = make_log().replace(
            "[PASS] Warm-up correctness gate passed\n", "")
        with self.assertRaisesRegex(SignoffError, "warm-up PASS marker"):
            signoff(log)

    def test_missing_final_pass_marker_fails(self) -> None:
        log = make_log().replace(
            "[PASS] v3.1 FlashAttention ten-run correctness and profiling "
            "passed", "")
        with self.assertRaisesRegex(SignoffError, "final ten-run PASS marker"):
            signoff(log)

    def test_planning_range_is_not_a_hard_gate(self) -> None:
        result = signoff(make_log(cycles=50_000_000))
        self.assertEqual(result["performance_baseline"]["profile"],
                         "legacy-v313")
        self.assertEqual(result["performance_baseline"]["average_cycles"],
                         63_669_978)
        self.assertEqual(result["performance_baseline"]["average_latency_ms"],
                         424.471607)
        self.assertEqual(result["performance_baseline"]["clock_mhz"], 150)
        self.assertEqual(result["planning_latency_range_ms"]["minimum"], 240)
        self.assertEqual(result["planning_latency_range_ms"]["maximum"], 280)
        self.assertFalse(result["planning_latency_range_ms"]["hard_gate"])


if __name__ == "__main__":
    unittest.main()
