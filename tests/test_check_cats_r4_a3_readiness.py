import copy
import unittest

from check_cats_r4_a3_readiness import validate_manifest


def valid_manifest():
    return {
        "full_protocol": {
            "level": "protocol_model",
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
        "real_ip_xsim": {"level": "representative_real_ip"},
        "numeric": {"combined_failures": 0},
        "ooc": {"clock_period_ns": 6.666, "wns_ns": 0.0},
    }


class ReadinessTests(unittest.TestCase):
    def test_valid_manifest_passes(self):
        self.assertEqual(validate_manifest(valid_manifest()), [])

    def test_protocol_evidence_cannot_substitute_for_real_ip(self):
        manifest = valid_manifest()
        manifest["real_ip_xsim"]["level"] = "protocol_model"
        self.assertTrue(any("real_ip_xsim.level" in e for e in validate_manifest(manifest)))

    def test_negative_wns_fails(self):
        manifest = valid_manifest()
        manifest["ooc"]["wns_ns"] = -0.001
        self.assertTrue(any("ooc.wns_ns" in e for e in validate_manifest(manifest)))


if __name__ == "__main__":
    unittest.main()
