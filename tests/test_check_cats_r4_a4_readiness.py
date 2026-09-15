import hashlib
import tempfile
import unittest
from pathlib import Path

from check_cats_r4_a4_readiness import validate_manifest


EXPECTED = {
    "groups": 8,
    "q_heads": 32,
    "rows": 4096,
    "final_releases": 4096,
    "causal_scores": 264192,
    "valid_exp": 264192,
    "weight_writes": 524288,
    "qk_valid_macs": 33816576,
    "pv_valid_macs": 33816576,
    "context_words": 524288,
    "q_slabs": 256,
    "engine_jobs": 6144,
}


def valid_manifest(clusters=2):
    per_cluster = [
        {key: value // clusters for key, value in EXPECTED.items()}
        for _ in range(clusters)
    ]
    return {
        "schema": "cats-r4-a4-evidence-v1",
        "status": "READY",
        "ready": True,
        "configuration": {
            "clusters": clusters,
            "modes": [0, 1],
            "seeds": [7, 19, 73, 101],
            "clock_period_ns": 6.666,
            "canonical_output": True,
            "queue_rows_per_cluster": 512,
        },
        "git": {
            "source_head": "1" * 40,
            "tree_hash": "2" * 40,
            "dirty": False,
        },
        "functional": {
            "result": "PASS",
            "normal_path_errors": 0,
            "aggregate": EXPECTED.copy(),
            "per_cluster": per_cluster,
        },
        "real_ip": {
            "result": "PASS",
            "evidence_level": "representative_real_ip",
            "configs_passed": 8,
            "configs_expected": 8,
        },
        "ooc": {
            "result": "PASS",
            "evidence_level": "routed_ooc",
            "route_complete": True,
            "drc_errors": 0,
            "wns_ns": 0.1,
            "tns_ns": 0.0,
            "whs_ns": 0.01,
            "ths_ns": 0.0,
        },
        "performance": {
            "comparable": True,
            "speedup_vs_1": 1.7 if clusters == 2 else 3.0,
            "imbalance": 0.0,
        },
        "dependencies": [
            {"id": "A3-INTEGRATION-ACCEPTANCE", "status": "ACCEPTED", "sha": "3" * 40},
            {"id": "A4-CANONICAL-OUTPUT", "status": "ACCEPTED", "sha": "3" * 40},
            {"id": "A4-INTERFACE-ACCEPTANCE", "status": "ACCEPTED", "sha": "3" * 40},
            {"id": "A4-RESOURCE-BUDGET", "status": "ACCEPTED", "sha": "3" * 40},
            {"id": "A4-PERFORMANCE-REVIEW", "status": "ACCEPTED", "sha": "3" * 40},
            {"id": "B4-OWNER-ACCEPTANCE", "status": "ACCEPTED", "sha": "4" * 40},
            {"id": "SIN-BF16-IDENTITY", "status": "ACCEPTED", "sha": "5" * 40},
        ],
        "evidence_files": [{"path": "dummy.log", "sha256": "0" * 64}],
    }


class ReadinessTests(unittest.TestCase):
    def test_valid_two_cluster_manifest_passes(self):
        self.assertEqual(validate_manifest(valid_manifest()), [])

    def test_missing_configuration_fails(self):
        manifest = valid_manifest()
        del manifest["configuration"]["queue_rows_per_cluster"]
        self.assertTrue(any("queue_rows_per_cluster" in e for e in validate_manifest(manifest)))

    def test_negative_hold_fails(self):
        manifest = valid_manifest()
        manifest["ooc"]["whs_ns"] = -0.001
        self.assertTrue(any("whs_ns" in e for e in validate_manifest(manifest)))

    def test_double_counted_aggregate_fails(self):
        manifest = valid_manifest()
        manifest["functional"]["aggregate"]["rows"] = 8192
        self.assertTrue(any("aggregate.rows" in e for e in validate_manifest(manifest)))

    def test_per_cluster_sum_must_close(self):
        manifest = valid_manifest()
        manifest["functional"]["per_cluster"][0]["rows"] -= 1
        self.assertTrue(any("per_cluster sum rows" in e for e in validate_manifest(manifest)))

    def test_fake_clock_or_incomparable_speedup_fails(self):
        manifest = valid_manifest()
        manifest["configuration"]["clock_period_ns"] = 5.0
        manifest["performance"]["comparable"] = False
        errors = validate_manifest(manifest)
        self.assertTrue(any("clock_period_ns" in e for e in errors))
        self.assertTrue(any("comparable" in e for e in errors))

    def test_two_cluster_speedup_gate_is_exact(self):
        manifest = valid_manifest()
        manifest["performance"]["speedup_vs_1"] = 1.5999
        self.assertTrue(any("speedup_vs_1" in e for e in validate_manifest(manifest)))

    def test_open_dependency_fails(self):
        manifest = valid_manifest()
        next(
            item
            for item in manifest["dependencies"]
            if item["id"] == "A4-CANONICAL-OUTPUT"
        )["status"] = "OPEN"
        self.assertTrue(any("A4-CANONICAL-OUTPUT" in e for e in validate_manifest(manifest)))

    def test_missing_and_stale_evidence_files_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            evidence = root / "evidence.log"
            evidence.write_text("PASS\n", encoding="utf-8")
            manifest = valid_manifest()
            manifest["evidence_files"] = [
                {"path": "evidence.log", "sha256": hashlib.sha256(b"wrong").hexdigest()},
                {"path": "missing.log", "sha256": "0" * 64},
            ]
            errors = validate_manifest(manifest, root)
            self.assertTrue(any("hash mismatch" in e for e in errors))
            self.assertTrue(any("missing.log" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
