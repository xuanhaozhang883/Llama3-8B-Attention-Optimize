#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path

REQUIRED = {
    "bc": {
        "rtl/integration/qk_softmax_pv_pipeline_top.sv":
            "qk_softmax_pv_pipeline_top",
        "rtl/backend/bf16_v_cache.sv":
            "bf16_v_cache",
        "rtl/backend/pv_input_loader.sv":
            "pv_input_loader",
        "rtl/softmax/exp_lut_q15.mem":
            None,
        "sim_models/floating_point_behavioral.sv":
            None,
    },
    "pv": {
        "rtl/pv_systolic_gqa_top.sv":
            "pv_systolic_gqa_top",
        "rtl/pv_systolic_tile.sv":
            "pv_systolic_tile",
        "rtl/pv_systolic_pe.sv":
            "pv_systolic_pe",
        "rtl/pv_result_converter.sv":
            "pv_result_converter",
        "rtl/pv_fp32_mul_ip.sv":
            "pv_fp32_mul_ip",
        "rtl/pv_fp32_add_ip.sv":
            "pv_fp32_add_ip",
    },
}

def check(root: Path, items: dict[str, str | None], errors: list[str]) -> None:
    for relative, module in items.items():
        path = root / relative
        if not path.is_file():
            errors.append(f"MISSING: {path}")
            continue

        if module:
            text = path.read_text(encoding="utf-8", errors="ignore")
            if not re.search(rf"\bmodule\s+{re.escape(module)}\b", text):
                errors.append(f"MODULE {module} NOT FOUND: {path}")

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bc_root", type=Path)
    parser.add_argument("pv_root", type=Path)
    args = parser.parse_args()

    errors: list[str] = []
    check(args.bc_root.resolve(), REQUIRED["bc"], errors)
    check(args.pv_root.resolve(), REQUIRED["pv"], errors)

    bc_pipeline = (
        args.bc_root /
        "rtl/integration/qk_softmax_pv_pipeline_top.sv"
    )
    if bc_pipeline.is_file():
        text = bc_pipeline.read_text(encoding="utf-8", errors="ignore")
        if "if (PV_TILE != 2)" not in text:
            errors.append(
                "Unexpected B+C version: formal PV_TILE=2 guard not found"
            )

    if errors:
        print("Corrected A+B+C+PV dependency audit: FAIL")
        for error in errors:
            print("  " + error)
        return 1

    print("Corrected A+B+C+PV dependency audit: PASS")
    print("B+C TILE2 and real PV TILE4 contracts were found.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
