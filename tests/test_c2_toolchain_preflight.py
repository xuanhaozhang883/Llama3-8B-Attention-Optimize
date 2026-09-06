#!/usr/bin/env python3
"""Focused tests for C2 source-manifest classification."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import c2_toolchain_preflight as preflight


class ManifestClassificationTests(unittest.TestCase):
    def make_source_tree(self, root: Path) -> None:
        cluster = root / "rtl" / "core" / "cluster"
        cluster.mkdir(parents=True)
        (cluster / "cats_r4_cluster_shell.sv").write_text(
            "module cats_r4_cluster_shell; endmodule\n", encoding="utf-8"
        )
        (cluster / "production.sv").write_text(
            "module production; endmodule\n", encoding="utf-8"
        )
        ignored = root / "rtl" / "tb"
        ignored.mkdir(parents=True)
        (ignored / "ignored_tb.sv").write_text(
            "module ignored_tb; endmodule\n", encoding="utf-8"
        )
        scripts = root / "scripts"
        scripts.mkdir()
        (scripts / "source_manifest.tcl").write_text(
            "set sources [list [file join $board_root rtl core cluster production.sv]]\n",
            encoding="utf-8",
        )

    def test_contract_shell_and_tb_are_not_production(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_source_tree(root)
            relative = {
                path.relative_to(preflight.normalized(root)).as_posix()
                for path in preflight.production_rtl(root)
            }
            self.assertEqual(relative, {"rtl/core/cluster/production.sv"})

    def test_manifest_reports_every_unlisted_production_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_source_tree(root)
            checks = {check.name: check for check in preflight.check_manifest(root)}
            self.assertEqual(checks["manifest_covers_rtl"].status, "PASS")

            cluster = root / "rtl" / "core" / "cluster"
            (cluster / "missing_a.sv").write_text("module a; endmodule\n", encoding="utf-8")
            (cluster / "missing_b.sv").write_text("module b; endmodule\n", encoding="utf-8")
            checks = {check.name: check for check in preflight.check_manifest(root)}
            manifest_check = checks["manifest_covers_rtl"]
            self.assertEqual(manifest_check.status, "BLOCKED")
            self.assertIn("unlisted production RTL (2)", manifest_check.detail)
            self.assertIn("missing_a.sv", manifest_check.detail)
            self.assertIn("missing_b.sv", manifest_check.detail)
            self.assertNotIn("cats_r4_cluster_shell.sv", manifest_check.detail)


if __name__ == "__main__":
    unittest.main()
