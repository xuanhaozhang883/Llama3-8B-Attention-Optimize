#!/usr/bin/env python3
"""Print high-value utilization and timing lines from Vivado reports."""
from __future__ import annotations
import argparse
from pathlib import Path
import re

PATTERNS = [
    re.compile(r'^\|\s*(Slice LUTs|Slice Registers|Block RAM Tile|DSPs|LUT as Memory)\s*\|'),
    re.compile(r'^\s*(WNS\(ns\)|TNS\(ns\)|WHS\(ns\)|THS\(ns\))'),
    re.compile(r'^\s*Slack\s*\('),
    re.compile(r'^\s*Requirement:'),
    re.compile(r'^\s*Data Path Delay:'),
    re.compile(r'^\s*Design Timing Summary'),
    re.compile(r'^\s*Timing constraints are not met'),
    re.compile(r'^\s*All user specified timing constraints are met'),
]


def interesting(line: str) -> bool:
    return any(p.search(line) for p in PATTERNS)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('report_dir', nargs='?', type=Path, default=Path(__file__).resolve().parents[1] / 'reports')
    args = parser.parse_args()
    report_dir = args.report_dir.resolve()
    reports = sorted(report_dir.rglob('*.rpt'))
    if not reports:
        raise SystemExit(f'No .rpt files found under {report_dir}')
    for path in reports:
        matches = [line.rstrip() for line in path.read_text(errors='replace').splitlines() if interesting(line)]
        if matches:
            print(f'\n=== {path.relative_to(report_dir)} ===')
            for line in matches[:80]:
                print(line)


if __name__ == '__main__':
    main()
