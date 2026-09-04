#!/usr/bin/env python3
"""Machine-check a v3.1 FlashAttention warm-up + ten-run UART log."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Iterable


MEASURED_RUNS = 10
RUN_GQA_GROUPS = 8
QK_TILES_COMPUTED_PER_RUN = 2112 * RUN_GQA_GROUPS
QK_TILES_SKIPPED_PER_RUN = 1984 * RUN_GQA_GROUPS
MASKED_TILES_EMITTED_PER_RUN = 1984 * RUN_GQA_GROUPS
V30_BASELINE_CYCLES = 64_408_268
V31_MAX_AVG_CYCLES = math.floor(V30_BASELINE_CYCLES * 0.90)

CONSUMER_PROFILES = {
    "v3.1.4-causal-bypass": {
        "flash_context_tiles": 16_896,
        "causal_tiles_bypassed": 15_872,
        "v_vectors_read": 1_081_344,
    },
    "v3.1.3-legacy-dense": {
        "flash_context_tiles": 32_768,
        "causal_tiles_bypassed": 0,
        "v_vectors_read": 2_097_152,
    },
}


class SignoffError(RuntimeError):
    pass


def _number(value: str) -> int:
    return int(value, 0)


def _collect(lines: Iterable[str], tag: str, fields: int) -> dict[int, list[str]]:
    rows: dict[int, list[str]] = {}
    for line in lines:
        parts = [item.strip() for item in line.strip().split(",")]
        if not parts or parts[0] != tag:
            continue
        if len(parts) != fields:
            raise SignoffError(
                f"{tag} has {len(parts)} fields; expected {fields}: {line}")
        run = _number(parts[1])
        if run in rows:
            raise SignoffError(f"duplicate {tag} run {run}")
        rows[run] = parts
    expected = set(range(1, MEASURED_RUNS + 1))
    if set(rows) != expected:
        raise SignoffError(
            f"{tag} runs are {sorted(rows)}; expected 1..{MEASURED_RUNS}")
    return rows


def _require_equal(actual: int, expected: int, label: str, run: int) -> None:
    if actual != expected:
        raise SignoffError(
            f"run {run} {label}={actual}; expected {expected}")


def signoff(text: str, require_performance: bool = True) -> dict[str, object]:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    if "[PASS] Warm-up correctness gate passed" not in text:
        raise SignoffError("warm-up PASS marker is missing")
    if ("[PASS] v3.1 FlashAttention ten-run correctness and profiling passed"
            not in text):
        raise SignoffError("v3.1 final ten-run PASS marker is missing")

    perf = _collect(lines, "PERF_CSV", 8)
    hw = _collect(lines, "HWPROF_CSV", 28)
    causal = _collect(lines, "V26_CAUSAL_CSV", 9)
    flash = _collect(lines, "V31_FLASH_CSV", 6)

    summaries = [line.split(",") for line in lines
                 if line.startswith("PERF_SUMMARY_CSV,")]
    if len(summaries) != 1 or len(summaries[0]) != 10:
        raise SignoffError("exactly one valid PERF_SUMMARY_CSV line is required")
    summary = summaries[0]
    _require_equal(_number(summary[1]), MEASURED_RUNS,
                   "correct measured runs", 0)
    _require_equal(_number(summary[2]), MEASURED_RUNS,
                   "deterministic measured runs", 0)

    totals: list[int] = []
    exact_counts: set[int] = set()
    strict_counts: set[int] = set()
    first_causal = causal[1]
    observed_consumer = tuple(_number(value) for value in first_causal[5:8])
    consumer_profile_name = ""
    consumer_profile: dict[str, int] = {}
    for name, candidate in CONSUMER_PROFILES.items():
        expected_consumer = (
            candidate["flash_context_tiles"],
            candidate["causal_tiles_bypassed"],
            candidate["v_vectors_read"],
        )
        if observed_consumer == expected_consumer:
            consumer_profile_name = name
            consumer_profile = candidate
            break
    if not consumer_profile:
        raise SignoffError(
            "unsupported Flash consumer counters on run 1: "
            f"processed/bypassed/v_vectors={observed_consumer}")

    for run in range(1, MEASURED_RUNS + 1):
        perf_row = perf[run]
        exact_counts.add(_number(perf_row[5]))
        strict_counts.add(_number(perf_row[6]))
        _require_equal(_number(perf_row[7]), 0, "Combined failures", run)

        hw_row = hw[run]
        totals.append(_number(hw_row[2]))
        _require_equal(_number(hw_row[16]), 524_288,
                       "Context words", run)
        _require_equal(_number(hw_row[27]), 0, "error detail bitmap", run)

        causal_row = causal[run]
        for value, expected, label in zip(
                causal_row[2:],
                (QK_TILES_COMPUTED_PER_RUN,
                 QK_TILES_SKIPPED_PER_RUN,
                 MASKED_TILES_EMITTED_PER_RUN,
                 consumer_profile["flash_context_tiles"],
                 consumer_profile["causal_tiles_bypassed"],
                 consumer_profile["v_vectors_read"], 0),
                ("QK tiles computed", "QK tiles skipped",
                 "masked tiles emitted", "Flash Context tiles processed",
                 "causal consumer tiles bypassed", "V vectors read",
                 "causal error flags")):
            _require_equal(_number(value), expected, label, run)

        flash_row = flash[run]
        for value, expected, label in zip(
                flash_row[2:],
                (consumer_profile["flash_context_tiles"],
                 consumer_profile["causal_tiles_bypassed"],
                 consumer_profile["v_vectors_read"], 0),
                ("Flash Context tiles processed",
                 "causal consumer tiles bypassed",
                 "V vectors read", "causal error flags")):
            _require_equal(_number(value), expected, label, run)

    if len(exact_counts) != 1 or len(strict_counts) != 1:
        raise SignoffError(
            "numerical mismatch counts changed between measured runs")

    average_cycles = sum(totals) // len(totals)
    speedup = 1.0 - average_cycles / V30_BASELINE_CYCLES
    performance_pass = average_cycles <= V31_MAX_AVG_CYCLES
    if require_performance and not performance_pass:
        raise SignoffError(
            f"average Total PL cycles {average_cycles} exceed "
            f"the >=10% speedup gate {V31_MAX_AVG_CYCLES}")

    return {
        "passed": True,
        "scope": "v3.1 FlashAttention warm-up + 10 measured GQA runs",
        "runs": MEASURED_RUNS,
        "correct_runs": _number(summary[1]),
        "deterministic_runs": _number(summary[2]),
        "combined_failures_per_run": 0,
        "context_words_per_run": 524_288,
        "consumer_profile": consumer_profile_name,
        "qk_tiles_computed_per_run": QK_TILES_COMPUTED_PER_RUN,
        "qk_tiles_skipped_per_run": QK_TILES_SKIPPED_PER_RUN,
        "masked_tiles_emitted_per_run": MASKED_TILES_EMITTED_PER_RUN,
        "flash_context_tiles_per_run":
            consumer_profile["flash_context_tiles"],
        "causal_tiles_bypassed_per_run":
            consumer_profile["causal_tiles_bypassed"],
        "v_vectors_read_per_run": consumer_profile["v_vectors_read"],
        "total_pl_cycles": {
            "min": min(totals),
            "average": average_cycles,
            "max": max(totals),
        },
        "v30_baseline_average_cycles": V30_BASELINE_CYCLES,
        "required_max_average_cycles": V31_MAX_AVG_CYCLES,
        "speedup_percent": round(speedup * 100.0, 6),
        "performance_gate_passed": performance_pass,
    }


def render_markdown(result: dict[str, object], log_path: Path) -> str:
    cycles = result["total_pl_cycles"]
    assert isinstance(cycles, dict)
    performance_gate = "PASS" if result["performance_gate_passed"] else "FAIL"
    return f"""# v3.1 FlashAttention 实体板签核

- 原始串口日志：`{log_path}`
- warm-up：PASS
- 正确运行：{result['correct_runs']} / {result['runs']}
- 确定性运行：{result['deterministic_runs']} / {result['runs']}
- Combined failures：0（每次）
- Total PL cycles（min/avg/max）：{cycles['min']} / {cycles['average']} / {cycles['max']}
- v3.0 平均周期基线：{result['v30_baseline_average_cycles']}
- 整机周期提升：{result['speedup_percent']:.6f}%
- 至少 10% 性能门禁：{performance_gate}

使用 consumer profile：{result['consumer_profile']}。固定硬件计数均逐次通过：QK {result['qk_tiles_computed_per_run']}/{result['qk_tiles_skipped_per_run']}、masked tile {result['masked_tiles_emitted_per_run']}、Flash Context processed/bypassed {result['flash_context_tiles_per_run']}/{result['causal_tiles_bypassed_per_run']}、V vector {result['v_vectors_read_per_run']}、Context word {result['context_words_per_run']}，全部错误标志为 0。
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("--json", type=Path)
    parser.add_argument("--markdown", type=Path)
    parser.add_argument("--correctness-only", action="store_true",
                        help="diagnostic mode; do not enforce >=10% speedup")
    args = parser.parse_args()
    text = args.log.read_text(encoding="utf-8", errors="replace")
    try:
        result = signoff(text, require_performance=not args.correctness_only)
    except SignoffError as error:
        print(f"[FAIL] {error}")
        return 1
    rendered = json.dumps(result, indent=2, sort_keys=True)
    print(rendered)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(rendered + "\n", encoding="utf-8")
    if args.markdown:
        args.markdown.parent.mkdir(parents=True, exist_ok=True)
        args.markdown.write_text(render_markdown(result, args.log),
                                 encoding="utf-8")
    if args.correctness_only:
        print("[PASS] v3.1 board log satisfies correctness gates; "
              "performance gate was not enforced")
    else:
        print("[PASS] v3.1 board log satisfies correctness and performance gates")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
