#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path

STATE_NAMES = {
    0: "IDLE", 1: "CLEAR_CONTEXT", 2: "COLLECT", 3: "PREPARE",
    4: "ALPHA", 5: "WEIGHT", 6: "UPDATE_STATE", 7: "PE_LOAD",
    8: "SCALE_ISSUE", 9: "SCALE_WAIT", 10: "V_REQ", 11: "V_WAIT",
    12: "MAC_ISSUE", 13: "MAC_WAIT", 14: "STORE_FEATURE",
    15: "COMMIT_BLOCK", 16: "DIV_START", 17: "DIV_WAIT",
    18: "NORM_LOAD", 19: "NORM_ISSUE", 20: "NORM_WAIT", 21: "OUTPUT",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("profile_csv", type=Path)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    with args.profile_csv.open(newline="", encoding="utf-8") as stream:
        rows = {row["metric"]: int(row["value"]) for row in csv.DictReader(stream)}
    total = rows["total_cycles"]
    if total <= 0:
        raise SystemExit("[FAIL] total_cycles must be positive")

    def percentage(value: int) -> float:
        return 100.0 * value / total

    states = {
        STATE_NAMES[index]: rows.get(f"online_state_{index}_cycles", 0)
        for index in STATE_NAMES
    }
    v_mac = sum(states[name] for name in
                ("V_REQ", "V_WAIT", "MAC_ISSUE", "MAC_WAIT"))
    scale = states["SCALE_ISSUE"] + states["SCALE_WAIT"]
    score_bp = rows["score_backpressure_cycles"]
    if v_mac >= scale and v_mac >= score_bp:
        recommendation = "V prefetch / wider Context feature lanes"
    elif score_bp >= scale:
        recommendation = "4x4 score-tile ping-pong buffer"
    else:
        recommendation = "Context rescale pipeline fusion"

    result = {
        "total_cycles": total,
        "qk_busy_percent": percentage(rows["qk_busy_cycles"]),
        "online_busy_percent": percentage(rows["online_busy_cycles"]),
        "score_backpressure_percent": percentage(score_bp),
        "v_and_mac_percent": percentage(v_mac),
        "scale_percent": percentage(scale),
        "context_words": rows["context_words"],
        "exact_mismatches": rows["exact_mismatches"],
        "combined_failures": rows["combined_failures"],
        "recommended_first_optimization": recommendation,
        "online_state_cycles": states,
    }
    print(json.dumps(result, indent=2))
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 0 if rows["combined_failures"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
