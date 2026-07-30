#!/usr/bin/env python3
"""
Analyze CSV output produced by tb_softmax_golden.sv.

Usage:
  python scripts/analyze_softmax_results.py results/softmax_results.csv

It prints an easy-to-read summary and, if matplotlib is installed, creates plots under results/plots/.
"""
from __future__ import annotations

import argparse
import csv
from pathlib import Path
from typing import List, Dict, Any


def to_float(x: str) -> float:
    try:
        return float(x)
    except Exception:
        return float("nan")


def main() -> None:
    default_csv = Path(__file__).resolve().parent.parent / "results" / "softmax_results.csv"
    parser = argparse.ArgumentParser(description="Analyze softmax simulation result CSV.")
    parser.add_argument("csv", nargs="?", default=str(default_csv), help="Path to softmax_results.csv")
    parser.add_argument("--top", type=int, default=20, help="Number of largest-error cases to print")
    args = parser.parse_args()

    csv_path = Path(args.csv)
    if not csv_path.exists():
        raise FileNotFoundError(f"Result CSV not found: {csv_path}\nRun Vivado simulation first.")

    rows: List[Dict[str, Any]] = []
    with csv_path.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            r["linear_idx"] = int(r["linear_idx"])
            r["head"] = int(r["head"])
            r["row"] = int(r["row"])
            r["col"] = int(r["col"])
            r["actual_float"] = to_float(r["actual_float"])
            r["expected_float"] = to_float(r["expected_float"])
            r["abs_err"] = to_float(r["abs_err"])
            r["row_error"] = int(r["row_error"])
            r["out_last"] = int(r["out_last"])
            r["pass"] = int(r["pass"])
            rows.append(r)

    if not rows:
        raise RuntimeError("CSV is empty.")

    total = len(rows)
    fail_count = sum(1 for r in rows if r["pass"] == 0)
    pass_count = total - fail_count
    max_err = max(r["abs_err"] for r in rows)
    mean_err = sum(r["abs_err"] for r in rows) / total
    outlast_fail = sum(1 for r in rows if r["out_last"] != (1 if r["col"] == 127 else 0))
    row_error_count = sum(1 for r in rows if r["row_error"] != 0)

    print("=" * 72)
    print("Softmax Golden Test Result")
    print("=" * 72)
    print(f"CSV file          : {csv_path}")
    print(f"Total outputs     : {total}")
    print(f"Pass count        : {pass_count}")
    print(f"Fail count        : {fail_count}")
    print(f"out_last failures : {outlast_fail}")
    print(f"row_error count   : {row_error_count}")
    print(f"Max abs error     : {max_err:.10e}")
    print(f"Mean abs error    : {mean_err:.10e}")
    print(f"Overall           : {'PASS' if fail_count == 0 and outlast_fail == 0 and row_error_count == 0 else 'FAIL'}")

    sorted_rows = sorted(rows, key=lambda r: r["abs_err"], reverse=True)
    print("\nLargest-error cases:")
    print("head row col | actual_hex actual_float | expected_hex expected_float | abs_err | pass")
    for r in sorted_rows[: args.top]:
        print(
            f"{r['head']:>4} {r['row']:>3} {r['col']:>3} | "
            f"{r['actual_bf16_hex']:>10} {r['actual_float']:.10e} | "
            f"{r['expected_bf16_hex']:>12} {r['expected_float']:.10e} | "
            f"{r['abs_err']:.10e} | {r['pass']}"
        )

    out_dir = csv_path.parent / "plots"
    top_csv = csv_path.parent / "top_error_cases.csv"
    with top_csv.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        for r in sorted_rows[: max(args.top, 100)]:
            writer.writerow(r)
    print(f"\nTop-error CSV      : {top_csv}")

    try:
        import numpy as np
        import matplotlib.pyplot as plt
    except Exception as e:
        print("\nPlot generation skipped because numpy/matplotlib is not available.")
        print("Install with: pip install numpy matplotlib")
        return

    heads = max(r["head"] for r in rows) + 1
    num_rows = max(r["row"] for r in rows) + 1
    max_len = max(r["col"] for r in rows) + 1

    err = np.zeros((heads, num_rows, max_len), dtype=float)
    actual = np.zeros_like(err)
    expected = np.zeros_like(err)
    for r in rows:
        err[r["head"], r["row"], r["col"]] = r["abs_err"]
        actual[r["head"], r["row"], r["col"]] = r["actual_float"]
        expected[r["head"], r["row"], r["col"]] = r["expected_float"]

    out_dir.mkdir(parents=True, exist_ok=True)

    # Plot 1: maximum absolute error per row for all heads.
    plt.figure(figsize=(10, 5))
    for h in range(heads):
        plt.plot(np.arange(num_rows), err[h].max(axis=1), label=f"head {h}")
    plt.xlabel("row index")
    plt.ylabel("max absolute error in this row")
    plt.title("Softmax output error by row")
    plt.legend()
    plt.grid(True, alpha=0.3)
    p1 = out_dir / "row_max_abs_error.png"
    plt.tight_layout()
    plt.savefig(p1, dpi=160)
    plt.close()

    # Plot 2: row-sum comparison. A correct softmax row should sum close to 1.
    plt.figure(figsize=(10, 5))
    for h in range(heads):
        plt.plot(np.arange(num_rows), actual[h].sum(axis=1), label=f"actual head {h}")
    plt.xlabel("row index")
    plt.ylabel("sum of actual softmax row")
    plt.title("Actual softmax row sums")
    plt.legend()
    plt.grid(True, alpha=0.3)
    p2 = out_dir / "actual_row_sums.png"
    plt.tight_layout()
    plt.savefig(p2, dpi=160)
    plt.close()

    # Plot 3: heatmap of absolute error for each head.
    heatmap_paths = []
    for h in range(heads):
        plt.figure(figsize=(8, 6))
        plt.imshow(err[h], aspect="auto")
        plt.colorbar(label="absolute error")
        plt.xlabel("col index")
        plt.ylabel("row index")
        plt.title(f"Absolute error heatmap, head {h}")
        ph = out_dir / f"error_heatmap_head{h}.png"
        plt.tight_layout()
        plt.savefig(ph, dpi=160)
        plt.close()
        heatmap_paths.append(ph)

    # Plot 4: first several rows: actual vs expected for intuitive waveform-like comparison.
    # Choose representative rows: row 0, 1, 2, 7, 31, 63, 127 from head 0 when present.
    for row_id in [0, 1, 2, 7, 31, 63, 127]:
        if row_id >= num_rows:
            continue
        plt.figure(figsize=(10, 5))
        x = np.arange(max_len)
        plt.plot(x, expected[0, row_id], label="expected")
        plt.plot(x, actual[0, row_id], label="actual", linestyle="--")
        plt.xlabel("col index")
        plt.ylabel("softmax probability")
        plt.title(f"Head 0 row {row_id}: actual vs expected")
        plt.legend()
        plt.grid(True, alpha=0.3)
        pr = out_dir / f"head0_row{row_id}_actual_vs_expected.png"
        plt.tight_layout()
        plt.savefig(pr, dpi=160)
        plt.close()

    print("\nGenerated plots:")
    print(f"  - {p1}")
    print(f"  - {p2}")
    for ph in heatmap_paths:
        print(f"  - {ph}")
    print(f"  - {out_dir / 'head0_row0_actual_vs_expected.png'}")
    print(f"  - {out_dir / 'head0_row127_actual_vs_expected.png'}")


if __name__ == "__main__":
    main()
