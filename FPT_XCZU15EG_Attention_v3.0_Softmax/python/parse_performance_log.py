#!/usr/bin/env python3
"""Parse v2.2 serial output into CSV and a compact summary.

Usage:
  python parse_performance_log.py serial_capture.txt
  python parse_performance_log.py serial_capture.txt --csv performance_runs.csv
"""
from __future__ import annotations

import argparse
import csv
import re
from pathlib import Path

RUN_RE = re.compile(
    r"^PERF_CSV,(?P<run>\d+),(?P<ticks>\d+),(?P<ns>\d+),"
    r"(?P<status>0x[0-9A-Fa-f]+),(?P<exact>\d+),(?P<strict>\d+),(?P<combined>\d+)$"
)
SUMMARY_RE = re.compile(
    r"^PERF_SUMMARY_CSV,(?P<pass_runs>\d+),(?P<deterministic_runs>\d+),"
    r"(?P<min_ns>\d+),(?P<avg_ns>\d+),(?P<max_ns>\d+),(?P<stddev_ns>\d+),"
    r"(?P<elements_per_s>\d+),(?P<groups_per_s_x1000>\d+),"
    r"(?P<gflops_x1000>\d+)$"
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("--csv", type=Path, default=Path("performance_runs.csv"))
    args = parser.parse_args()

    text = args.log.read_text(encoding="utf-8", errors="replace")
    runs: list[dict[str, str]] = []
    summary: dict[str, str] | None = None

    for raw_line in text.splitlines():
        line = raw_line.strip()
        match = RUN_RE.match(line)
        if match:
            row = match.groupdict()
            row["latency_ms"] = f"{int(row['ns']) / 1_000_000:.6f}"
            runs.append(row)
            continue
        match = SUMMARY_RE.match(line)
        if match:
            summary = match.groupdict()

    if not runs:
        raise SystemExit("No PERF_CSV lines were found in the log")

    fieldnames = [
        "run", "ticks", "ns", "latency_ms", "status",
        "exact", "strict", "combined",
    ]
    with args.csv.open("w", newline="", encoding="utf-8-sig") as fp:
        writer = csv.DictWriter(fp, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(runs)

    print(f"Parsed runs: {len(runs)}")
    print(f"CSV written: {args.csv.resolve()}")
    if summary:
        print(f"Correct runs: {summary['pass_runs']}/{len(runs)}")
        print(f"Deterministic runs: {summary['deterministic_runs']}/{len(runs)}")
        print(f"Latency min/avg/max: "
              f"{int(summary['min_ns'])/1e6:.6f} / "
              f"{int(summary['avg_ns'])/1e6:.6f} / "
              f"{int(summary['max_ns'])/1e6:.6f} ms")
        print(f"Latency stddev: {int(summary['stddev_ns'])/1e6:.6f} ms")
        print(f"Context throughput: {summary['elements_per_s']} elements/s")
        print(f"GQA group rate: {int(summary['groups_per_s_x1000'])/1000:.3f} groups/s")
        print(f"Effective QK+PV: {int(summary['gflops_x1000'])/1000:.3f} GFLOP/s")
    else:
        print("Warning: PERF_SUMMARY_CSV line was not found")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
