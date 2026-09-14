"""Strict row-versus-online comparability gate for CATS-R4 A3 evidence."""

from __future__ import annotations


MATCH_FIELDS = (
    "input_sha256",
    "numeric_mode",
    "qk_lanes",
    "pv_lanes",
    "clock_mhz",
    "timing_start",
    "timing_end",
)

RESOURCE_FIELDS = ("lut", "ff", "bram", "dsp", "uram")


def compare(row: dict, online: dict) -> dict:
    """Compare candidates only when every experiment-boundary field is equal."""
    missing = object()
    mismatches = {}
    for name in MATCH_FIELDS:
        row_value = row.get(name, missing)
        online_value = online.get(name, missing)
        if row_value != online_value or row_value is missing:
            mismatches[name] = {
                "row": None if row_value is missing else row_value,
                "online": None if online_value is missing else online_value,
            }
    if mismatches:
        return {"comparable": False, "mismatches": mismatches}

    return {
        "comparable": True,
        "cycle_delta": row["cycles"] - online["cycles"],
        "cycle_ratio": row["cycles"] / online["cycles"],
        "resource_delta": {
            name: row["resources"][name] - online["resources"][name]
            for name in RESOURCE_FIELDS
        },
        "stall_delta": {
            name: row["stalls"].get(name, 0) - online["stalls"].get(name, 0)
            for name in sorted(set(row["stalls"]) | set(online["stalls"]))
        },
    }
