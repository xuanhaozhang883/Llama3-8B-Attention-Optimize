"""Validate lead-owned gate status without granting READY."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
data = json.loads((ROOT / "docs/CATS_R4_RELEASE_GATE.json").read_text(encoding="utf-8"))
required = {"artifacts", "interface", "a_unit", "b_unit", "c_bridge", "c2_board"}
allowed = {"READY", "READY_FOR_UNIT_DEVELOPMENT", "NOT_READY", "BLOCKED_AT_ENTRY_GATE"}
assert data["schema"] == "cats-r4-release-gate/v1"
assert data["overall"] == "NOT_READY"
assert required == set(data["gates"])
assert all(item["status"] in allowed for item in data["gates"].values())
assert data["gates"]["c2_board"]["status"] == "BLOCKED_AT_ENTRY_GATE"
assert data["required_normal_counters"] == {"rd_beats": 196608, "wr_beats": 131072, "rows_committed": 4096, "error_counters": 0}
print("PASS: release gate manifest schema/status/counter targets")
