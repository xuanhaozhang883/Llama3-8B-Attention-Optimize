#!/usr/bin/env python3
"""Validate closure and safety invariants in parsed v2.4 profiling CSV."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path


FINE_FIELDS = {
    "rope_busy_cycles",
    "qk_busy_cycles",
    "mask_busy_cycles",
    "softmax_busy_cycles",
    "bc_backend_busy_cycles",
    "capture_busy_cycles",
    "context_transfer_cycles",
    "bc_pv_overlap_cycles",
    "core_idle_cycles",
    "repack_stall_cycles",
    "pv_feed_stall_cycles",
    "softmax_stall_cycles",
    "interstage_wait_cycles",
}


def fail(message: str) -> None:
    raise SystemExit(f"[FAIL] {message}")


def parse_int(row: dict[str, str], field: str, run: int) -> int:
    try:
        return int(row[field], 0)
    except (KeyError, TypeError, ValueError):
        fail(f"run {run}: invalid or missing field {field}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("csv_file", type=Path)
    parser.add_argument("--expected-runs", type=int, default=10)
    parser.add_argument("--closure-tolerance", type=int, default=1024)
    args = parser.parse_args()

    with args.csv_file.open(newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream))

    if len(rows) != args.expected_runs:
        fail(f"expected {args.expected_runs} runs, found {len(rows)}")
    if not rows:
        fail("no profiling rows")

    missing_fine = sorted(FINE_FIELDS - set(rows[0]))
    if missing_fine:
        fail(f"fine-grained fields missing: {', '.join(missing_fine)}")

    stage_fields = sorted(
        FINE_FIELDS
        - {"context_transfer_cycles", "bc_pv_overlap_cycles"}
    )

    for index, row in enumerate(rows, start=1):
        total = parse_int(row, "total_cycles", index)
        v_load = parse_int(row, "v_load_cycles", index)
        core = parse_int(row, "core_run_cycles", index)
        bc = parse_int(row, "bc_busy_cycles", index)
        pv = parse_int(row, "pv_busy_cycles", index)
        overlap = parse_int(row, "bc_pv_overlap_cycles", index)
        context_words = parse_int(row, "context_word_count", index)
        context_transfer = parse_int(
            row, "context_transfer_cycles", index
        )
        error_detail = parse_int(row, "error_detail", index)
        group_sum = sum(
            parse_int(row, f"group{group}_cycles", index)
            for group in range(8)
        )

        if error_detail != 0:
            fail(f"run {index}: error_detail=0x{error_detail:08x}")
        if context_words != 524288:
            fail(
                f"run {index}: context_word_count={context_words}, "
                "expected 524288"
            )
        if context_transfer != context_words:
            fail(
                f"run {index}: context transfer {context_transfer} "
                f"!= context words {context_words}"
            )
        if overlap > min(bc, pv):
            fail(
                f"run {index}: overlap {overlap} exceeds "
                f"min(B+C={bc}, PV={pv})"
            )
        if abs(total - (v_load + core)) > args.closure_tolerance:
            fail(
                f"run {index}: total closure error "
                f"{total - (v_load + core)} cycles"
            )
        if abs(group_sum - core) > args.closure_tolerance:
            fail(
                f"run {index}: group/core closure error "
                f"{group_sum - core} cycles"
            )
        for field in stage_fields:
            value = parse_int(row, field, index)
            if value > core:
                fail(
                    f"run {index}: {field}={value} exceeds "
                    f"core_run_cycles={core}"
                )

    print("================================================")
    print("[PASS] v2.4 profiling result invariants")
    print(f"Runs              : {len(rows)}")
    print(f"Closure tolerance : {args.closure_tolerance} cycles")
    print("Context words     : 524288 per run")
    print("Error bitmap      : zero for every run")
    print("================================================")


if __name__ == "__main__":
    main()
