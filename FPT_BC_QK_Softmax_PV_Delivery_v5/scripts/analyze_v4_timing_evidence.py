#!/usr/bin/env python3
"""Reproduce the v5 root-cause classification from the bundled v4 reports."""
from collections import Counter
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "reports/bc_pipeline_artix7/v4_user_evidence"


def main() -> None:
    summary = (EVIDENCE / "post_synth_timing.rpt").read_text(
        encoding="utf-8", errors="replace"
    )
    match = re.search(
        r"Setup\s*:\s*(\d+)\s+Failing Endpoints,\s+Worst Slack\s+"
        r"(-?\d+\.\d+)ns,\s+Total Violation\s+(-?\d+\.\d+)ns",
        summary,
    )
    if not match:
        raise SystemExit("Cannot parse v4 setup timing summary")
    failing, wns, tns = int(match.group(1)), float(match.group(2)), float(match.group(3))
    if (failing, wns, tns) != (58, -5.643, -239.439):
        raise SystemExit(f"Unexpected v4 timing tuple: {(failing, wns, tns)}")

    critical = (EVIDENCE / "post_synth_critical_paths.rpt").read_text(
        encoding="utf-8", errors="replace"
    )
    starts = [match.start() for match in re.finditer(r"^Slack \(VIOLATED\)", critical, re.M)]
    blocks = [
        critical[start : starts[index + 1] if index + 1 < len(starts) else len(critical)]
        for index, start in enumerate(starts)
    ]
    if len(blocks) != 50:
        raise SystemExit(f"Expected 50 reported critical paths, found {len(blocks)}")

    destinations: Counter[int] = Counter()
    slacks: Counter[float] = Counter()
    for block in blocks:
        source = re.search(r"^\s*Source:\s+(\S+)", block, re.M)
        destination = re.search(r"^\s*Destination:\s+(\S+)", block, re.M)
        slack = re.search(r"^Slack \(VIOLATED\)\s*:\s*(-?\d+\.\d+)ns", block, re.M)
        if not (source and destination and slack):
            raise SystemExit("Malformed critical-path block")
        if "/proc_idx_reg[0]/C" not in source.group(1):
            raise SystemExit(f"Unexpected critical source: {source.group(1)}")
        bit = re.search(r"/sum_exp_reg\[(\d+)\]/D", destination.group(1))
        if not bit:
            raise SystemExit(f"Unexpected critical destination: {destination.group(1)}")
        destinations[int(bit.group(1))] += 1
        slacks[float(slack.group(1))] += 1

    expected_destinations = Counter({23: 10, 19: 10, 15: 10, 22: 10, 21: 10})
    expected_slacks = Counter({-5.643: 10, -5.529: 10, -5.415: 10, -5.398: 10, -5.355: 10})
    if destinations != expected_destinations or slacks != expected_slacks:
        raise SystemExit(
            f"Unexpected path clustering: destinations={destinations}, slacks={slacks}"
        )

    print(f"PASS: v4 timing tuple WNS={wns:.3f} TNS={tns:.3f} failing={failing}")
    print("PASS: all 50 critical paths share proc_idx -> sum_exp EXP cone")
    print(f"destination_bits={dict(sorted(destinations.items()))}")


if __name__ == "__main__":
    main()
