import copy
import sys
import unittest
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))

from cats_r4_a3_ablation_gate import MATCH_FIELDS, compare


def candidate():
    return {
        "input_sha256": "a" * 64,
        "numeric_mode": 1,
        "qk_lanes": 32,
        "pv_lanes": 32,
        "clock_mhz": 150.0,
        "timing_start": "first_qk_issue",
        "timing_end": "final_context_commit",
        "cycles": 1000,
        "resources": {"lut": 100, "ff": 200, "bram": 3, "dsp": 4, "uram": 0},
        "stalls": {"score": 7, "output": 11},
    }


class AblationGateTests(unittest.TestCase):
    def test_each_match_field_is_mandatory(self):
        replacements = {
            "input_sha256": "b" * 64,
            "numeric_mode": 0,
            "qk_lanes": 4,
            "pv_lanes": 4,
            "clock_mhz": 149.0,
            "timing_start": "transaction_start",
            "timing_end": "final_release",
        }
        for field in MATCH_FIELDS:
            with self.subTest(field=field):
                row = candidate()
                online = copy.deepcopy(row)
                online[field] = replacements[field]
                result = compare(row, online)
                self.assertFalse(result["comparable"])
                self.assertEqual(set(result["mismatches"]), {field})

    def test_missing_field_is_not_comparable(self):
        row = candidate()
        online = copy.deepcopy(row)
        del online["clock_mhz"]
        result = compare(row, online)
        self.assertFalse(result["comparable"])
        self.assertIn("clock_mhz", result["mismatches"])

    def test_matching_metadata_returns_exact_deltas(self):
        row = candidate()
        online = copy.deepcopy(row)
        online["cycles"] = 800
        online["resources"] = {"lut": 90, "ff": 220, "bram": 2, "dsp": 4, "uram": 0}
        online["stalls"] = {"score": 2, "memory": 5}
        result = compare(row, online)
        self.assertTrue(result["comparable"])
        self.assertEqual(result["cycle_delta"], 200)
        self.assertEqual(result["cycle_ratio"], 1.25)
        self.assertEqual(result["resource_delta"], {"lut": 10, "ff": -20, "bram": 1, "dsp": 0, "uram": 0})
        self.assertEqual(result["stall_delta"], {"memory": -5, "output": 11, "score": 5})


if __name__ == "__main__":
    unittest.main()
