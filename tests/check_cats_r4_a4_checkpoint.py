"""Fail-closed validator for the tracked A4 P6 unit checkpoint."""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path


HEX40 = re.compile(r"^[0-9a-fA-F]{40}$")
HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")


def validate_checkpoint(index: object, repo_root: Path) -> list[str]:
    errors: list[str] = []
    if not isinstance(index, dict):
        return ["checkpoint must be an object"]

    expected_scalars = {
        "schema": "cats-r4-a4-p6-control-evidence-index-v1",
        "branch": "codex/a-cats-r4-a4-2cluster",
        "status": "unit_ready_p6_integration_not_ready",
        "evidence_class": "unit_protocol_model_not_real_ip",
        "open_blocker": "A4-CANONICAL-OUTPUT",
    }
    for key, expected in expected_scalars.items():
        if index.get(key) != expected:
            errors.append(f"{key} must be exactly {expected!r}")

    for path in (
        ("implementation_commit", index.get("implementation_commit")),
        (
            "transaction_fanout.implementation_commit",
            (index.get("transaction_fanout") or {}).get("implementation_commit")
            if isinstance(index.get("transaction_fanout"), dict)
            else None,
        ),
        (
            "dual_adapter_control_plane.implementation_commit",
            (index.get("dual_adapter_control_plane") or {}).get(
                "implementation_commit"
            )
            if isinstance(index.get("dual_adapter_control_plane"), dict)
            else None,
        ),
    ):
        if not isinstance(path[1], str) or not HEX40.fullmatch(path[1]):
            errors.append(f"{path[0]} must be a complete 40-hex commit")

    suite = index.get("exact_unit_suite")
    if not isinstance(suite, dict):
        errors.append("exact_unit_suite must be an object")
        suite = {}
    suite_expected = {
        "dirty": False,
        "clusters": 2,
        "mode": 1,
        "seed": 19,
        "status": "PASS",
        "exit_code": 0,
        "timed_out": False,
    }
    for key, expected in suite_expected.items():
        if type(suite.get(key)) is not type(expected) or suite.get(key) != expected:
            errors.append(f"exact_unit_suite.{key} must be exactly {expected!r}")
    if not isinstance(suite.get("source_commit"), str) or not HEX40.fullmatch(
        suite["source_commit"]
    ):
        errors.append("exact_unit_suite.source_commit must be a complete 40-hex commit")

    hashes = index.get("sha256")
    if not isinstance(hashes, dict) or not hashes:
        errors.append("sha256 must be a non-empty object")
        return errors

    root = repo_root.resolve()
    for relative, expected_hash in hashes.items():
        if not isinstance(relative, str) or not relative:
            errors.append("sha256 path must be a non-empty string")
            continue
        if not isinstance(expected_hash, str) or not HEX64.fullmatch(expected_hash):
            errors.append(f"sha256 digest must be 64 hex: {relative}")
            continue
        candidate = (root / relative).resolve()
        try:
            candidate.relative_to(root)
        except ValueError:
            errors.append(f"checkpoint source escapes repository: {relative}")
            continue
        if not candidate.is_file():
            errors.append(f"checkpoint source is missing: {relative}")
            continue
        actual = hashlib.sha256(candidate.read_bytes()).hexdigest()
        if actual.lower() != expected_hash.lower():
            errors.append(
                f"checkpoint source hash mismatch: {relative}; "
                f"expected {expected_hash}, got {actual}"
            )
    return errors


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print("usage: check_cats_r4_a4_checkpoint.py EVIDENCE_INDEX.json", file=sys.stderr)
        return 2
    path = Path(args[0]).resolve()
    try:
        index = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        print(f"A4 checkpoint FAIL: cannot read evidence index: {exc}", file=sys.stderr)
        return 1
    try:
        repo_root = path.parents[2]
    except IndexError:
        print("A4 checkpoint FAIL: index is not below artifacts/<checkpoint>", file=sys.stderr)
        return 1
    errors = validate_checkpoint(index, repo_root)
    if errors:
        print("A4 checkpoint FAIL:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS CATS-R4 A4 P6 CONTROL CHECKPOINT")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
