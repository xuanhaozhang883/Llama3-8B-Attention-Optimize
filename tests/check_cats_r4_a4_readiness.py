"""Fail-closed validator for CATS-R4 A4 evidence manifests."""

from __future__ import annotations

import hashlib
import json
import math
import re
import sys
from pathlib import Path


EXPECTED = {
    "groups": 8,
    "q_heads": 32,
    "rows": 4096,
    "final_releases": 4096,
    "causal_scores": 264192,
    "valid_exp": 264192,
    "weight_writes": 524288,
    "qk_valid_macs": 33816576,
    "pv_valid_macs": 33816576,
    "context_words": 524288,
    "q_slabs": 256,
    "engine_jobs": 6144,
}

REQUIRED_DEPENDENCIES = {
    "A3-INTEGRATION-ACCEPTANCE",
    "A4-CANONICAL-OUTPUT",
    "A4-INTERFACE-ACCEPTANCE",
    "A4-RESOURCE-BUDGET",
    "A4-PERFORMANCE-REVIEW",
    "B4-OWNER-ACCEPTANCE",
    "SIN-BF16-IDENTITY",
}

HEX40 = re.compile(r"^[0-9a-fA-F]{40}$")
HEX64 = re.compile(r"^[0-9a-fA-F]{64}$")


def _mapping(value, path, errors):
    if not isinstance(value, dict):
        errors.append(f"{path} must be an object")
        return {}
    return value


def _exact(mapping, key, expected, path, errors):
    value = mapping.get(key)
    if type(value) is not type(expected) or value != expected:
        errors.append(f"{path}.{key} must be exactly {expected!r}; got {value!r}")


def _finite_number(mapping, key, path, errors, *, minimum=None, maximum=None):
    value = mapping.get(key)
    if type(value) not in (int, float) or not math.isfinite(value):
        errors.append(f"{path}.{key} must be a finite number; got {value!r}")
        return None
    if minimum is not None and value < minimum:
        errors.append(f"{path}.{key} must be >= {minimum}; got {value!r}")
    if maximum is not None and value >= maximum:
        errors.append(f"{path}.{key} must be < {maximum}; got {value!r}")
    return value


def validate_manifest(manifest, base_dir=None):
    """Return actionable validation failures; an empty list means A4 READY."""

    errors = []
    root = _mapping(manifest, "manifest", errors)
    _exact(root, "schema", "cats-r4-a4-evidence-v1", "manifest", errors)
    _exact(root, "status", "READY", "manifest", errors)
    _exact(root, "ready", True, "manifest", errors)

    config = _mapping(root.get("configuration"), "configuration", errors)
    clusters = config.get("clusters")
    if clusters not in (1, 2, 4) or type(clusters) is not int:
        errors.append(f"configuration.clusters must be 1, 2, or 4; got {clusters!r}")
        clusters = 0
    _exact(config, "modes", [0, 1], "configuration", errors)
    _exact(config, "seeds", [7, 19, 73, 101], "configuration", errors)
    _exact(config, "clock_period_ns", 6.666, "configuration", errors)
    _exact(config, "canonical_output", True, "configuration", errors)
    queue_rows = config.get("queue_rows_per_cluster")
    if type(queue_rows) is not int or queue_rows <= 0:
        errors.append(
            "configuration.queue_rows_per_cluster must be a positive integer; "
            f"got {queue_rows!r}"
        )

    git = _mapping(root.get("git"), "git", errors)
    for key in ("source_head", "tree_hash"):
        if not isinstance(git.get(key), str) or not HEX40.fullmatch(git[key]):
            errors.append(f"git.{key} must be a complete 40-hex identity")
    _exact(git, "dirty", False, "git", errors)

    functional = _mapping(root.get("functional"), "functional", errors)
    _exact(functional, "result", "PASS", "functional", errors)
    _exact(functional, "normal_path_errors", 0, "functional", errors)
    aggregate = _mapping(functional.get("aggregate"), "functional.aggregate", errors)
    for key, expected in EXPECTED.items():
        _exact(aggregate, key, expected, "functional.aggregate", errors)
    per_cluster = functional.get("per_cluster")
    if not isinstance(per_cluster, list) or len(per_cluster) != clusters:
        errors.append(
            f"functional.per_cluster must contain exactly {clusters} entries"
        )
        per_cluster = []
    for key, expected in EXPECTED.items():
        values = [item.get(key) for item in per_cluster if isinstance(item, dict)]
        if len(values) != clusters or any(type(value) is not int for value in values):
            errors.append(f"functional.per_cluster entries must all contain integer {key}")
        elif sum(values) != expected:
            errors.append(
                f"functional.per_cluster sum {key} must be {expected}; got {sum(values)}"
            )

    real_ip = _mapping(root.get("real_ip"), "real_ip", errors)
    _exact(real_ip, "result", "PASS", "real_ip", errors)
    _exact(
        real_ip,
        "evidence_level",
        "representative_real_ip",
        "real_ip",
        errors,
    )
    expected_configs = real_ip.get("configs_expected")
    passed_configs = real_ip.get("configs_passed")
    if type(expected_configs) is not int or expected_configs <= 0:
        errors.append("real_ip.configs_expected must be a positive integer")
    if passed_configs != expected_configs:
        errors.append(
            "real_ip.configs_passed must equal configs_expected; "
            f"got {passed_configs!r}/{expected_configs!r}"
        )

    ooc = _mapping(root.get("ooc"), "ooc", errors)
    _exact(ooc, "result", "PASS", "ooc", errors)
    _exact(ooc, "evidence_level", "routed_ooc", "ooc", errors)
    _exact(ooc, "route_complete", True, "ooc", errors)
    _exact(ooc, "drc_errors", 0, "ooc", errors)
    _finite_number(ooc, "wns_ns", "ooc", errors, minimum=0.0)
    _exact(ooc, "tns_ns", 0.0, "ooc", errors)
    _finite_number(ooc, "whs_ns", "ooc", errors, minimum=0.0)
    _exact(ooc, "ths_ns", 0.0, "ooc", errors)

    performance = _mapping(root.get("performance"), "performance", errors)
    _exact(performance, "comparable", True, "performance", errors)
    speedup = _finite_number(
        performance, "speedup_vs_1", "performance", errors, minimum=0.0
    )
    if clusters == 2 and speedup is not None and speedup < 1.6:
        errors.append(
            f"performance.speedup_vs_1 must be >= 1.6 for two clusters; got {speedup}"
        )
    if clusters == 4:
        _finite_number(
            performance, "imbalance", "performance", errors, minimum=0.0, maximum=0.05
        )
    else:
        _finite_number(performance, "imbalance", "performance", errors, minimum=0.0)

    dependencies = root.get("dependencies")
    if not isinstance(dependencies, list):
        errors.append("dependencies must be a list")
        dependencies = []
    dependency_map = {
        item.get("id"): item for item in dependencies if isinstance(item, dict)
    }
    for dependency_id in sorted(REQUIRED_DEPENDENCIES):
        item = dependency_map.get(dependency_id)
        if item is None:
            errors.append(f"dependency {dependency_id} is missing")
            continue
        if item.get("status") != "ACCEPTED":
            errors.append(f"dependency {dependency_id} is not ACCEPTED")
        sha = item.get("sha")
        if not isinstance(sha, str) or not HEX40.fullmatch(sha):
            errors.append(f"dependency {dependency_id} must include an accepted 40-hex sha")

    evidence_files = root.get("evidence_files")
    if not isinstance(evidence_files, list) or not evidence_files:
        errors.append("evidence_files must be a non-empty list")
        evidence_files = []
    evidence_root = Path(base_dir) if base_dir is not None else None
    for index, item in enumerate(evidence_files):
        if not isinstance(item, dict):
            errors.append(f"evidence_files[{index}] must be an object")
            continue
        relative = item.get("path")
        digest = item.get("sha256")
        if not isinstance(relative, str) or not relative:
            errors.append(f"evidence_files[{index}].path must be non-empty")
            continue
        if not isinstance(digest, str) or not HEX64.fullmatch(digest):
            errors.append(f"evidence_files[{index}].sha256 must be 64 hex")
            continue
        if evidence_root is not None:
            candidate = (evidence_root / relative).resolve()
            try:
                candidate.relative_to(evidence_root.resolve())
            except ValueError:
                errors.append(f"evidence file escapes manifest directory: {relative}")
                continue
            if not candidate.is_file():
                errors.append(f"evidence file is missing: {relative}")
                continue
            actual = hashlib.sha256(candidate.read_bytes()).hexdigest()
            if actual.lower() != digest.lower():
                errors.append(
                    f"evidence file hash mismatch: {relative}; expected {digest}, got {actual}"
                )

    return errors


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print("usage: check_cats_r4_a4_readiness.py MANIFEST.json", file=sys.stderr)
        return 2
    path = Path(args[0]).resolve()
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        print(f"A4 readiness FAIL: cannot read manifest: {exc}", file=sys.stderr)
        return 1
    errors = validate_manifest(manifest, path.parent)
    if errors:
        print("A4 readiness FAIL:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS CATS-R4 A4 READINESS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
