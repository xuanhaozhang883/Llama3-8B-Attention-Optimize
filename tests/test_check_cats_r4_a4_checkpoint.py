import copy
import importlib.util
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INDEX_PATH = ROOT / "artifacts" / "a4_p6_control_20260915" / "evidence_index.json"
SPEC = importlib.util.spec_from_file_location(
    "check_cats_r4_a4_checkpoint",
    ROOT / "tests" / "check_cats_r4_a4_checkpoint.py",
)
CHECKPOINT = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(CHECKPOINT)


class A4CheckpointTests(unittest.TestCase):
    def setUp(self):
        self.index = json.loads(INDEX_PATH.read_text(encoding="utf-8"))

    def test_tracked_checkpoint_passes(self):
        self.assertEqual(CHECKPOINT.validate_checkpoint(self.index, ROOT), [])

    def test_source_hash_tamper_fails(self):
        broken = copy.deepcopy(self.index)
        first_path = next(iter(broken["sha256"]))
        broken["sha256"][first_path] = "0" * 64
        errors = CHECKPOINT.validate_checkpoint(broken, ROOT)
        self.assertTrue(any("hash mismatch" in error for error in errors))

    def test_unit_checkpoint_cannot_claim_ready(self):
        broken = copy.deepcopy(self.index)
        broken["status"] = "READY"
        broken["open_blocker"] = "CLOSED"
        errors = CHECKPOINT.validate_checkpoint(broken, ROOT)
        self.assertTrue(any("unit_ready_p6_integration_not_ready" in e for e in errors))
        self.assertTrue(any("A4-CANONICAL-OUTPUT" in e for e in errors))

    def test_dirty_or_failed_exact_suite_fails(self):
        broken = copy.deepcopy(self.index)
        broken["exact_unit_suite"]["dirty"] = True
        broken["exact_unit_suite"]["status"] = "FAILED"
        errors = CHECKPOINT.validate_checkpoint(broken, ROOT)
        self.assertTrue(any(".dirty" in error for error in errors))
        self.assertTrue(any(".status" in error for error in errors))

    def test_cluster_mapping_cannot_claim_production_ready(self):
        broken = copy.deepcopy(self.index)
        broken["real_cluster_instance_mapping"]["status"] = "n2_ready"
        broken["real_cluster_instance_mapping"]["cluster_1"]["heads"] = [1, 3, 5, 7]
        errors = CHECKPOINT.validate_checkpoint(broken, ROOT)
        self.assertTrue(any("n2_composition_unit_ready_production_not_ready" in e for e in errors))
        self.assertTrue(any("cluster_1.heads" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
