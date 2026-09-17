"""Extract a fail-closed A4 simulation timeout diagnostic from retained logs."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


PAIR = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)")
INTEGER_FIELDS = {
    "heartbeat",
    "jobs_counter",
    "rows",
    "scores",
    "releases",
    "final",
    "outputs",
    "client",
    "qk",
    "ctx",
}


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _parse_fields(line: str) -> dict[str, object]:
    parsed: dict[str, object] = {}
    for name, value in PAIR.findall(line):
        if name in INTEGER_FIELDS and value.isdecimal():
            parsed[name] = int(value)
        else:
            parsed[name] = value
    return parsed


def _last_matching(lines: list[str], prefix: str) -> str | None:
    for line in reversed(lines):
        if line.startswith(prefix):
            return line
    return None


def build_diagnostic(
    stdout_path: Path,
    stderr_path: Path,
    *,
    mode: int,
    seed: int,
    clusters: int,
    cluster_id: int,
    job_count: int,
    timeout_seconds: int,
) -> dict[str, object]:
    stdout_text = stdout_path.read_text(encoding="utf-8", errors="replace")
    stderr_text = stderr_path.read_text(encoding="utf-8", errors="replace")
    stdout_lines = stdout_text.splitlines()
    stderr_lines = stderr_text.splitlines()
    progress_line = _last_matching(stdout_lines, "PROGRESS heartbeat=")
    detail_line = _last_matching(stdout_lines, "PROGRESS a2 ")
    return {
        "schema": "cats-r4-a4-timeout-diagnostic-v1",
        "status": (
            "timeout_with_progress" if progress_line else "timeout_without_progress"
        ),
        "configuration": {
            "mode": mode,
            "seed": seed,
            "clusters": clusters,
            "cluster_id": cluster_id,
            "job_count": job_count,
            "timeout_seconds": timeout_seconds,
        },
        "last_progress": _parse_fields(progress_line) if progress_line else None,
        "last_progress_line": progress_line,
        "last_detail": _parse_fields(detail_line) if detail_line else None,
        "last_detail_line": detail_line,
        "stdout_tail": stdout_lines[-20:],
        "stderr_tail": stderr_lines[-20:],
        "stdout_sha256": _sha256(stdout_path),
        "stderr_sha256": _sha256(stderr_path),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stdout", type=Path, required=True)
    parser.add_argument("--stderr", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", type=int, required=True)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--clusters", type=int, required=True)
    parser.add_argument("--cluster-id", type=int, required=True)
    parser.add_argument("--job-count", type=int, required=True)
    parser.add_argument("--timeout-seconds", type=int, required=True)
    args = parser.parse_args()

    diagnostic = build_diagnostic(
        args.stdout,
        args.stderr,
        mode=args.mode,
        seed=args.seed,
        clusters=args.clusters,
        cluster_id=args.cluster_id,
        job_count=args.job_count,
        timeout_seconds=args.timeout_seconds,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(diagnostic, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(f"A4_TIMEOUT_DIAGNOSTIC={args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
