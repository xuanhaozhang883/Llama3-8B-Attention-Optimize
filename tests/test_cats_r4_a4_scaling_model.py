import importlib.util
import sys
import unittest
from pathlib import Path


MODEL_PATH = (
    Path(__file__).resolve().parents[1] / "python" / "cats_r4_a4_scaling_model.py"
)
SPEC = importlib.util.spec_from_file_location("cats_r4_a4_scaling_model", MODEL_PATH)
assert SPEC is not None and SPEC.loader is not None
MODEL = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODEL
SPEC.loader.exec_module(MODEL)


class AssignmentTests(unittest.TestCase):
    def test_group_ownership_is_static_and_complete(self):
        expected = {
            1: {0: [0, 1, 2, 3, 4, 5, 6, 7]},
            2: {0: [0, 2, 4, 6], 1: [1, 3, 5, 7]},
            4: {0: [0, 4], 1: [1, 5], 2: [2, 6], 3: [3, 7]},
        }
        for clusters, ownership in expected.items():
            with self.subTest(clusters=clusters):
                self.assertEqual(MODEL.group_ownership(clusters), ownership)

    def test_all_jobs_and_rows_are_bijective(self):
        for clusters in (1, 2, 4):
            with self.subTest(clusters=clusters):
                jobs = MODEL.enumerate_jobs(clusters)
                self.assertEqual(len(jobs), 256)
                self.assertEqual(
                    len({(j.global_q_head, j.window) for j in jobs}), 256
                )
                self.assertTrue(
                    all(j.cluster_id == j.group % clusters for j in jobs)
                )
                rows = MODEL.enumerate_rows(clusters)
                self.assertEqual(len(rows), 4096)
                self.assertEqual(len({r.seq for r in rows}), 4096)
                self.assertEqual(sorted(r.seq for r in rows), list(range(4096)))


class WorkloadTests(unittest.TestCase):
    def test_aggregate_work_is_invariant(self):
        expected = {
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
        for clusters in (1, 2, 4):
            with self.subTest(clusters=clusters):
                report = MODEL.workload_report(clusters)
                self.assertEqual(report["aggregate"], expected)
                summed = {
                    key: sum(item[key] for item in report["per_cluster"])
                    for key in expected
                }
                self.assertEqual(summed, expected)

    def test_v3_capacity_includes_three_score_and_weight_slots(self):
        capacity = MODEL.v3_capacity_per_cluster()
        self.assertEqual(capacity["score_slots_bytes"], 3 * 128 * 2)
        self.assertEqual(capacity["weight_slots_bytes"], 3 * 128 * 4)
        self.assertEqual(capacity["v3_delta_bytes"], 1560)
        self.assertEqual(capacity["total_bytes"], 154520)

    def test_resource_risk_is_not_reported_as_measured(self):
        estimate = MODEL.resource_estimate(4)
        self.assertEqual(estimate["evidence_level"], "linear_risk_estimate")
        self.assertEqual(estimate["compute_lut"], 247868)
        self.assertEqual(estimate["compute_ff"], 460100)
        self.assertEqual(estimate["compute_dsp"], 1548)
        self.assertTrue(estimate["exceeds_team_lut_target"])
        self.assertTrue(estimate["exceeds_team_ff_target"])

    def test_service_widths_and_ddr_traffic_do_not_scale_global_work(self):
        for clusters in (1, 2, 4):
            with self.subTest(clusters=clusters):
                service = MODEL.service_requirements(clusters)
                self.assertEqual(service["k_rsp_bits_per_cluster"], 512)
                self.assertEqual(service["v_rsp_bits_per_cluster"], 512)
                self.assertEqual(service["context_bits_per_cluster"], 512)
                self.assertEqual(service["local_kv_peak_bytes_per_core_cycle"], 128)
                self.assertEqual(
                    service["ddr_read_beats_per_cluster"] * clusters, 196608
                )
                self.assertEqual(
                    service["ddr_write_beats_per_cluster"] * clusters, 131072
                )


class CanonicalOutputTests(unittest.TestCase):
    def test_infinite_sink_preserves_ideal_parallel_upper_bound(self):
        one = MODEL.simulate_output_path(1, queue_rows=4096, canonical=False)
        two = MODEL.simulate_output_path(2, queue_rows=4096, canonical=False)
        four = MODEL.simulate_output_path(4, queue_rows=4096, canonical=False)
        self.assertGreaterEqual(one.cycles / two.cycles, 1.99)
        self.assertGreaterEqual(one.cycles / four.cycles, 3.95)

    def test_current_32_row_queue_blocks_2cluster_progress_gate(self):
        one = MODEL.simulate_output_path(1, queue_rows=32, canonical=True)
        two = MODEL.simulate_output_path(2, queue_rows=32, canonical=True)
        self.assertLess(one.cycles / two.cycles, 1.6)
        self.assertGreater(two.total_queue_stall_cycles, 0)
        self.assertEqual(two.rows_committed, 4096)
        self.assertEqual(two.max_queue_depth, 32)

    def test_full_group_queue_is_a_sensitivity_case_not_a_claim(self):
        current = MODEL.simulate_output_path(2, queue_rows=32, canonical=True)
        full_group = MODEL.simulate_output_path(2, queue_rows=512, canonical=True)
        self.assertLess(full_group.cycles, current.cycles)
        self.assertEqual(full_group.evidence_level, "architecture_model")

    def test_invalid_configuration_fails_closed(self):
        for clusters in (0, 3, 8):
            with self.subTest(clusters=clusters):
                with self.assertRaises(ValueError):
                    MODEL.workload_report(clusters)
        with self.assertRaises(ValueError):
            MODEL.simulate_output_path(2, queue_rows=0, canonical=True)


if __name__ == "__main__":
    unittest.main()
