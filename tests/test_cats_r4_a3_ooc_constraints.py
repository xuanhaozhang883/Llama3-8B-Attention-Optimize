import pathlib
import unittest


class A3OocConstraintTest(unittest.TestCase):
    def test_package_less_contract_io_is_excluded_from_timing(self):
        runner = pathlib.Path(__file__).with_name(
            "run_cats_r4_a3_realip_vivado.ps1"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "set_false_path -from [get_ports -filter {DIRECTION == IN && NAME != clk}]",
            runner,
        )
        self.assertIn(
            "set_false_path -to [get_ports -filter {DIRECTION == OUT}]",
            runner,
        )
        self.assertNotIn("set_input_delay -min 0.000", runner)
        self.assertNotIn("set_output_delay -min 0.000", runner)

    def test_internal_timing_checks_allow_explicit_boundary_false_paths(self):
        flow = (
            pathlib.Path(__file__).parents[1]
            / "scripts"
            / "cats_r4_a3_compute_cluster_ooc.tcl"
        ).read_text(encoding="utf-8")

        self.assertNotIn("all_registers -no_clock", flow)
        self.assertIn("unconstrained_internal_endpoints", flow)
        self.assertIn("partial_output_delay", flow)
        self.assertNotIn(
            r"checking\s+\S+\s+\([1-9][0-9]*\)",
            flow,
        )


if __name__ == "__main__":
    unittest.main()
