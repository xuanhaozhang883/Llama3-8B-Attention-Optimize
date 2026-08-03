#!/usr/bin/env python3
"""Static installation check for the v3.1 Score Tile FIFO stage."""

from __future__ import annotations

import sys
from pathlib import Path


REQUIRED_MARKERS = {
    "rtl/core/flash/flash_score_tile_fifo.sv": (
        "module flash_score_tile_fifo",
        "Consequently a partial",
        "score tile can never enter Softmax",
        "status_clear",
        "protocol_error",
    ),
    "rtl/core/bc/integration/qk_softmax_pipeline_top.sv": (
        "parameter int SCORE_FIFO_DEPTH = 8",
        "u_score_fifo",
        ".in_valid(qk_score_valid)",
        ".out_valid(score_valid)",
        "score_fifo_group_boundary_error",
    ),
    "tb/tb_v31_flash_score_tile_fifo.sv": (
        "module tb_v31_flash_score_tile_fifo",
        "V31_FLASH_SCORE_TILE_FIFO_TEST: PASS",
    ),
    "tb/tb_v31_qk_softmax_fifo_integration.sv": (
        "module tb_v31_qk_softmax_fifo_integration",
        "V31_QK_SOFTMAX_FIFO_INTEGRATION_TEST: PASS",
    ),
    "tests/run_v31_flash_stage1_checks.ps1": (
        "run_online_softmax_checks.ps1",
        "tb_v31_qk_softmax_fifo_integration",
    ),
    "tests/run_v31_flash_stage1_vivado.tcl": (
        "V31_FLASH_STAGE1_XSIM_PASS.txt",
        "scripts/check_rtl_elaboration.tcl",
    ),
}


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    failures: list[str] = []

    for relative_name, markers in REQUIRED_MARKERS.items():
        path = root / relative_name
        if not path.is_file():
            failures.append(f"missing: {relative_name}")
            continue

        text = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                failures.append(
                    f"marker missing in {relative_name}: {marker}"
                )

    top_path = root / "rtl/core/bc/integration/qk_softmax_pipeline_top.sv"
    if top_path.is_file():
        top_text = top_path.read_text(encoding="utf-8")
        if ".score_valid(score_valid), .score_ready(score_ready)" in top_text:
            failures.append(
                "QK still drives the old score stream directly; FIFO wiring missing"
            )
        if ".adapter_protocol_error(frontend_adapter_protocol_error)" not in top_text:
            failures.append("Frontend error was not separated from FIFO errors")

    source_manifest = root / "scripts/source_manifest.tcl"
    if not source_manifest.is_file():
        failures.append("missing existing recursive scripts/source_manifest.tcl")
    elif "collect_hdl_files" not in source_manifest.read_text(encoding="utf-8"):
        failures.append("source_manifest.tcl is not recursive; add FIFO manually")

    if failures:
        print("[FAIL] V3.1 Stage 1 installation check")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("[PASS] V3.1 Stage 1 overlay is installed correctly")
    print(f"Project root: {root}")
    print("Boundary: real QK -> complete 4x4 Score Tile FIFO -> current frontend")
    print("QK arithmetic: unchanged")
    print("Softmax/PV arithmetic: unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
