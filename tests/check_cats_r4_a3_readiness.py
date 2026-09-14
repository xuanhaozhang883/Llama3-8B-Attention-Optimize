"""Validate the CATS-R4 A3 sign-off evidence manifest without substitution."""

import json
import math
import sys
from pathlib import Path


EXPECTED = {
    "rows": 4096,
    "causal_scores": 264192,
    "weight_writes": 524288,
    "qk_macs": 33816576,
    "pv_macs": 33816576,
    "context_words": 524288,
    "final_releases": 4096,
    "q_slabs": 256,
    "engine_jobs": 6144,
}


def _mapping(value, path, errors):
    if not isinstance(value, dict):
        errors.append(f"{path} must be an object")
        return {}
    return value


def _exact(obj, key, expected, path, errors):
    value = obj.get(key)
    if type(value) is not type(expected) or value != expected:
        errors.append(f"{path}.{key} must be exactly {expected!r}; got {value!r}")


def validate_manifest(manifest):
    """Return an actionable list of validation failures (empty means ready)."""
    errors = []
    root = _mapping(manifest, "manifest", errors)
    _exact(root, "status", "READY", "manifest", errors)
    _exact(root, "ready", True, "manifest", errors)
    full = _mapping(root.get("full_protocol"), "full_protocol", errors)
    counters = _mapping(full.get("counters"), "full_protocol.counters", errors)
    real = _mapping(root.get("real_ip_xsim"), "real_ip_xsim", errors)
    real_scope = _mapping(real.get("scope"), "real_ip_xsim.scope", errors)
    numeric = _mapping(root.get("numeric"), "numeric", errors)
    ooc = _mapping(root.get("ooc"), "ooc", errors)
    _exact(full, "level", "protocol_model", "full_protocol", errors)
    _exact(full, "result", "PASS", "full_protocol", errors)
    _exact(full, "normal_path_errors", 0, "full_protocol", errors)
    _exact(real, "level", "representative_real_ip", "real_ip_xsim", errors)
    _exact(real, "result", "PASS", "real_ip_xsim", errors)
    _exact(real_scope, "configs_passed", 8, "real_ip_xsim.scope", errors)
    _exact(real_scope, "configs_expected", 8, "real_ip_xsim.scope", errors)
    _exact(real_scope, "rows_per_config", 16, "real_ip_xsim.scope", errors)
    _exact(real_scope, "modes", [0, 1], "real_ip_xsim.scope", errors)
    _exact(real_scope, "seeds", [7, 19, 73, 101], "real_ip_xsim.scope", errors)
    _exact(numeric, "level", "stored_full_numeric", "numeric", errors)
    _exact(numeric, "result", "PASS", "numeric", errors)
    _exact(numeric, "combined_failures", 0, "numeric", errors)
    for key, expected in EXPECTED.items():
        _exact(counters, key, expected, "full_protocol.counters", errors)
    _exact(ooc, "clock_period_ns", 6.666, "ooc", errors)
    _exact(ooc, "level", "routed_ooc", "ooc", errors)
    _exact(ooc, "result", "PASS", "ooc", errors)
    _exact(ooc, "route_complete", True, "ooc", errors)
    _exact(ooc, "drc_complete", True, "ooc", errors)
    _exact(ooc, "tns_ns", 0.0, "ooc", errors)
    wns = ooc.get("wns_ns")
    if type(wns) not in (int, float) or not math.isfinite(wns) or wns < 0:
        errors.append(f"ooc.wns_ns must be a finite number >= 0; got {wns!r}")
    return errors


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print("usage: check_cats_r4_a3_readiness.py MANIFEST.json", file=sys.stderr)
        return 2
    try:
        with Path(args[0]).open("r", encoding="utf-8") as stream:
            manifest = json.load(stream)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        print(f"A3 readiness FAIL: cannot read manifest: {exc}", file=sys.stderr)
        return 1
    errors = validate_manifest(manifest)
    if errors:
        print("A3 readiness FAIL:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print("PASS CATS-R4 A3 READINESS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
