import copy
import unittest

from check_cats_r4_a3_readiness import validate_manifest


def valid_manifest():
    return {
        "status": "READY",
        "ready": True,
        "full_protocol": {
            "level": "protocol_model",
            "result": "PASS",
            "normal_path_errors": 0,
            "counters": {
                "rows": 4096,
                "causal_scores": 264192,
                "weight_writes": 524288,
                "qk_macs": 33816576,
                "pv_macs": 33816576,
                "context_words": 524288,
                "final_releases": 4096,
                "q_slabs": 256,
                "engine_jobs": 6144,
            },
        },
        "real_ip_xsim": {
            "level": "representative_real_ip",
            "result": "PASS",
            "scope": {
                "configs_passed": 8,
                "configs_expected": 8,
                "rows_per_config": 16,
                "modes": [0, 1],
                "seeds": [7, 19, 73, 101],
            },
        },
        "numeric": {"level": "stored_full_numeric", "result": "PASS", "combined_failures": 0},
        "ooc": {
            "level": "routed_ooc",
            "result": "PASS",
            "clock_period_ns": 6.666,
            "route_complete": True,
            "drc_complete": True,
            "wns_ns": 0.0,
            "tns_ns": 0.0,
        },
    }


class ReadinessTests(unittest.TestCase):
    def test_valid_manifest_passes(self):
        self.assertEqual(validate_manifest(valid_manifest()), [])

    def test_protocol_evidence_cannot_substitute_for_real_ip(self):
        manifest = valid_manifest()
        manifest["real_ip_xsim"]["level"] = "protocol_model"
        self.assertTrue(any("real_ip_xsim.level" in e for e in validate_manifest(manifest)))

    def test_evidence_classes_are_distinct(self):
        manifest = valid_manifest()
        manifest["numeric"]["level"] = "protocol_model"
        manifest["ooc"]["level"] = "representative_real_ip"
        errors = validate_manifest(manifest)
        self.assertTrue(any("numeric.level" in e for e in errors))
        self.assertTrue(any("ooc.level" in e for e in errors))

    def test_negative_wns_fails(self):
        manifest = valid_manifest()
        manifest["ooc"]["wns_ns"] = -0.001
        self.assertTrue(any("ooc.wns_ns" in e for e in validate_manifest(manifest)))

    def test_incomplete_route_fails(self):
        manifest = valid_manifest()
        manifest["ooc"]["route_complete"] = False
        self.assertTrue(any("route_complete" in e for e in validate_manifest(manifest)))

    def test_partial_real_ip_matrix_fails(self):
        manifest = valid_manifest()
        manifest["real_ip_xsim"]["scope"]["configs_passed"] = 7
        self.assertTrue(any("configs_passed" in e for e in validate_manifest(manifest)))

    def test_real_ip_matrix_identity_is_exact(self):
        for field, bad_value in (("rows_per_config", 8), ("modes", [0]), ("seeds", [7])):
            with self.subTest(field=field):
                manifest = valid_manifest()
                manifest["real_ip_xsim"]["scope"][field] = bad_value
                self.assertTrue(any(field in e for e in validate_manifest(manifest)))

    def test_top_level_status_must_be_consistent(self):
        manifest = valid_manifest()
        manifest["status"] = "BLOCKED-WITH-EVIDENCE"
        manifest["ready"] = False
        errors = validate_manifest(manifest)
        self.assertTrue(any("manifest.status" in e for e in errors))
        self.assertTrue(any("manifest.ready" in e for e in errors))


if __name__ == "__main__":
    unittest.main()
