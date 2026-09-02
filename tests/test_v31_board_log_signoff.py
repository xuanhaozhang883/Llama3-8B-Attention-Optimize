#!/usr/bin/env python3
"""Unit checks for the v3.1 board-log signoff gate."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))

from signoff_v31_board_log import SignoffError, signoff  # noqa: E402


def make_log(cycles: int = 50_000_000, bad_v_vectors: bool = False) -> str:
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
        vectors = 2_097_151 if bad_v_vectors and run == 4 else 2_097_152
        lines.append(
            f"V26_CAUSAL_CSV,{run},16896,15872,15872,32768,0,{vectors},0x0")
        lines.append(f"V31_FLASH_CSV,{run},32768,0,{vectors},0x0")
    lines.append("PERF_SUMMARY_CSV,10,10,1,2,3,0,1,1,1")
    lines.append(
        "[PASS] v3.1 FlashAttention ten-run correctness and profiling passed")
    return "\n".join(lines)


class BoardLogSignoffTest(unittest.TestCase):
    def test_complete_fast_log_passes(self) -> None:
        result = signoff(make_log())
        self.assertTrue(result["performance_gate_passed"])
        self.assertEqual(result["total_pl_cycles"]["average"], 50_000_000)

    def test_slow_log_fails_performance_gate(self) -> None:
        with self.assertRaisesRegex(SignoffError, "speedup gate"):
            signoff(make_log(cycles=60_000_000))

    def test_wrong_v_counter_fails(self) -> None:
        with self.assertRaisesRegex(SignoffError, "V vectors read"):
            signoff(make_log(bad_v_vectors=True))


if __name__ == "__main__":
    unittest.main()
