import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class A4EvidenceScriptTests(unittest.TestCase):
    def test_full_protocol_runner_retains_raw_evidence(self):
        runner = (ROOT / "tests" / "run_cats_r4_a3_full_protocol_iverilog.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("[string]$OutputRoot", runner)
        self.assertIn("EVIDENCE_DIR=$OutputRoot", runner)
        self.assertNotIn(
            "Remove-Item -LiteralPath $OutputRoot -Recurse -Force", runner
        )

    def test_routed_validator_covers_both_delay_types(self):
        validator = (
            ROOT / "scripts" / "cats_r4_a3_validate_routed_ooc.tcl"
        ).read_text(encoding="utf-8")
        self.assertIn("report_timing_summary -delay_type min_max", validator)
        self.assertIn("get_timing_paths -delay_type max", validator)
        self.assertIn("get_timing_paths -delay_type min", validator)

    def test_a4_suite_runner_is_parameterized_and_preserves_evidence(self):
        runner = (ROOT / "tests" / "run_cats_r4_a4_suite.ps1").read_text(
            encoding="utf-8"
        )
        for token in (
            "[int]$Clusters",
            "[int]$Mode",
            "[uint32]$Seed",
            "[string]$Suite",
            "[string]$OutputRoot",
            "[int]$TimeoutSeconds",
            "source_manifest.json",
            "run_status.json",
            "process.json",
            "stdout.log",
            "stderr.log",
        ):
            self.assertIn(token, runner)
        self.assertNotIn(
            "Remove-Item -LiteralPath $OutputRoot -Recurse -Force", runner
        )


if __name__ == "__main__":
    unittest.main()
