#!/usr/bin/env python3
"""Static contract checks for the v2.5 Ping-Pong integration."""

from __future__ import annotations

import hashlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

PROTECTED_V24_HASHES = {
    "rtl/core/bc/qk/qk_systolic_gqa_top.sv":
        "3b8ba506fb3e9bd0700e5b512d9f77f09440414c30362961f7b406be1b0192b9",
    "rtl/core/bc/qk/qk_systolic_tile.sv":
        "bf3834516d91c13cd952aca93e4bb7755e00634f8c1a0646144a0de519f1c8d0",
    "rtl/core/bc/qk/qk_systolic_pe.sv":
        "32083419ec9c9543f614b1d7fddd52317f4e3b93dcbdc41eec97bd2e3b6ebc89",
    "rtl/core/bc/softmax/softmax_bf16.sv":
        "f82a506f0c45d4f849cf5de011edf84a28dcb0d241d3b1372bc7d6ad753c87af",
    "rtl/core/bc/softmax/exp_lut.sv":
        "16f7d51980ed67ed965e98460075f2e1066aaf7077510cd7e1553ec767613cd8",
    "rtl/core/bc/softmax/unsigned_restoring_divider.sv":
        "7223a534740ae7d53e2db42aa4b04fb15883a9687eb67b7581554aa884fe7a1b",
    "rtl/core/pv/pv_systolic_gqa_top.sv":
        "b7972d7ecc5a33827e415a3758b9fe58540d94c8fecb2fbec4598d0a9a1bdbb8",
    "rtl/core/pv/pv_systolic_tile.sv":
        "b7e4ba12ce677006fb2095ae6cf3d0dfa77771511b0db6ae9102f219c61a0c9e",
    "rtl/core/pv/pv_systolic_pe.sv":
        "2d70602a534c7c74c3c1848596ee64ecd31eaccd0593f7decaeb673a1112716a",
    "rtl/core/pv/pv_result_converter.sv":
        "4ce76056fb5754ebe45b788930f7cf2d3854ce1bc53b869da817d9c2f3c235d8",
    "rtl/core/bc/integration/qk_softmax_pv_pipeline_top.sv":
        "f80519fbf319481104c3b83694974f6b00fe5ddc67f0a7fd40741b2a9029ddc6",
    "rtl/core/bc/backend/softmax_pv_backend.sv":
        "ac8a63cded0067df75ae58eb8dc57f328a1ac7cea5439b66494d573bee34553c",
}


def fail(message: str) -> None:
    raise SystemExit(f"[FAIL] {message}")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


for relative, expected in PROTECTED_V24_HASHES.items():
    path = ROOT / relative
    if not path.is_file():
        fail(f"protected v2.4 RTL is missing: {relative}")
    actual = sha256(path)
    if actual != expected:
        fail(f"protected v2.4 RTL changed: {relative}")

top = (
    ROOT / "rtl/core/a/attention_system_with_rope_pv_top.sv"
).read_text(encoding="utf-8")
controller = (
    ROOT / "rtl/core/a/attention_group_pingpong_controller.sv"
).read_text(encoding="utf-8")
adapter = (
    ROOT / "rtl/core/a/pv_tile2_to_tile4_pingpong_adapter.sv"
).read_text(encoding="utf-8")

for token in [
    "attention_group_pingpong_controller",
    "pv_tile2_to_tile4_pingpong_adapter",
    ".group_id(bc_launch_group_id)",
    "assign context_group_id = pv_active_group_id;",
    "assign context_global_last",
]:
    if token not in top:
        fail(f"v2.5 top-level contract token is missing: {token}")

if "attention_group_pv_controller #(" in top:
    fail("v2.4 serialized controller is still instantiated by the top")
if "pv_tile2_to_tile4_buffer_adapter #(" in top:
    fail("v2.4 single-Group repack adapter is still instantiated by the top")

for token in [
    "fill_start_ready",
    "drain_valid",
    "pv_inflight",
    "bc_inflight",
    "drain_release",
]:
    if token not in controller:
        fail(f"Ping-Pong controller contract token is missing: {token}")

for token in [
    "BANK_EMPTY",
    "BANK_FILLING",
    "BANK_READY",
    "BANK_DRAINING",
    'ram_style = "block"',
    "feed_complete",
    "response_is_last",
]:
    if token not in adapter:
        fail(f"Ping-Pong buffer contract token is missing: {token}")

q_heads = 4
seq_len = 128
head_dim = 128
lanes = 4
row_tiles = seq_len // lanes
col_tiles = head_dim // lanes
p_depth_per_lane = 2 * q_heads * row_tiles * seq_len
v_depth_per_lane = 2 * seq_len * col_tiles

# A RAMB36E2 configured at 18-bit width stores 2048 words.
p_ramb36 = lanes * ((p_depth_per_lane + 2047) // 2048)
v_ramb36 = lanes * ((v_depth_per_lane + 2047) // 2048)
new_ramb36 = p_ramb36 + v_ramb36
baseline_bram_tiles = 99.5
available_bram_tiles = 744.0
projected_bram_tiles = baseline_bram_tiles + new_ramb36
projected_percent = 100.0 * projected_bram_tiles / available_bram_tiles

if new_ramb36 != 80:
    fail(f"unexpected Ping-Pong RAMB36 estimate: {new_ramb36}")
if projected_percent >= 25.0:
    fail(
        "projected BRAM exceeds the Stage-2 25% guard: "
        f"{projected_percent:.2f}%"
    )

print("================================================")
print("[PASS] v2.5 Ping-Pong static contract")
print(f"Protected v2.4 RTL : {len(PROTECTED_V24_HASHES)} files unchanged")
print(f"Estimated new RAMB36: {new_ramb36} (P={p_ramb36}, V={v_ramb36})")
print(
    "Projected BRAM Tile: "
    f"{projected_bram_tiles:.1f}/{available_bram_tiles:.0f} "
    f"({projected_percent:.2f}%)"
)
print("BC/PV Group IDs    : decoupled")
print("Context Group ID   : bound to active PV Group")
print("================================================")
