#!/usr/bin/env python3
from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CFG = json.loads((ROOT / "project_config.json").read_text(encoding="utf-8"))


def fail(msg: str) -> None:
    raise SystemExit(f"[FAIL] {msg}")

hdl = sorted((ROOT / "rtl").rglob("*.v")) + sorted((ROOT / "rtl").rglob("*.sv"))
core = [p for p in hdl if "rtl/core" in p.as_posix()]
board = [p for p in hdl if "rtl/board" in p.as_posix()]
if len(core) != 44:
    fail(f"expected 44 authoritative core HDL files, got {len(core)}")
if len(board) != 6:
    fail(f"expected 6 board HDL files, got {len(board)}")

modules = {}
for path in hdl:
    text = path.read_text(encoding="utf-8", errors="ignore")
    for name in re.findall(r"(?m)^\s*module\s+([A-Za-z_]\w*)", text):
        if name in modules:
            fail(f"duplicate module {name}: {modules[name]} and {path}")
        modules[name] = path

for name in ["attention_board_top", "fpt_attention_board_engine",
             "fpt_v_ddr_loader", "fpt_raw_qk_ddr_reader",
             "fpt_context_ddr_writer", "aq_axi_master_fixed",
             "attention_system_with_rope_pv_top",
             "rope_qk_softmax_pv_pipeline_top", "pv_systolic_gqa_top"]:
    if name not in modules:
        fail(f"required module missing: {name}")

for name, expected in {"exp_lut_q15.mem": 513,
                       "sin_bf16.hex": 8192,
                       "cos_bf16.hex": 8192}.items():
    words = [x for x in (ROOT / "mem" / name).read_text().splitlines() if x.strip()]
    if len(words) != expected:
        fail(f"{name}: expected {expected} words, got {len(words)}")

G = int(CFG["run_groups"]); QH = int(CFG["q_heads"]); KVH = int(CFG["kv_heads"])
S = int(CFG["seq_len"]); D = int(CFG["head_dim"])
counts = {
    "q_before_rope_bf16.hex": QH*S*D,
    "k_before_rope_bf16.hex": KVH*S*D,
    "v_bf16.hex": KVH*S*D,
    "attn_out_per_head_bf16.hex": QH*S*D,
}
for name, expected in counts.items():
    got = len((ROOT / "vitis" / "data" / name).read_text().split())
    if got != expected:
        fail(f"{name}: expected {expected}, got {got}")

# Top default must match the package scope.
top = (ROOT / "rtl" / "board" / "attention_board_top.sv").read_text()
m = re.search(r"parameter\s+int\s+RUN_GROUPS\s*=\s*(\d+)", top)
if not m or int(m.group(1)) != G:
    fail("attention_board_top RUN_GROUPS does not match project_config.json")

header = (ROOT / "vitis" / "src" / "fpt_golden_vectors.h").read_text(encoding="ascii")
for macro, value in [("FPT_RUN_GROUPS", G), ("FPT_Q_HEADS", QH),
                     ("FPT_KV_HEADS", KVH), ("FPT_SEQ_LEN", S),
                     ("FPT_HEAD_DIM", D)]:
    if f"#define {macro} {value}u" not in header:
        fail(f"header macro mismatch: {macro}")

if not (ROOT / "bd_base" / "design_1" / "design_1.bd").is_file():
    fail("vendor PS block design is missing")

# The imported vendor BD must not retain generation metadata from the
# unrelated machine/project where it was first created.
path_sensitive = [
    ROOT / "bd_base" / "design_1" / "design_1.bd",
    *sorted((ROOT / "bd_base" / "design_1" / "ip").rglob("*.xci")),
]
for path in path_sensitive:
    text = path.read_text(encoding="utf-8", errors="ignore")
    if "pl_read_write_ps_ddr" in text:
        fail(f"stale source-project generation path remains in {path}")

project_cfg = (ROOT / "scripts" / "project_config.tcl").read_text(
    encoding="utf-8"
)
create_script = (
    ROOT / "scripts" / "create_attention_board_project.tcl"
).read_text(encoding="utf-8")
check_script = (
    ROOT / "scripts" / "check_rtl_elaboration.tcl"
).read_text(encoding="utf-8")
for token, text in [
    ("FPT_VIVADO_BUILD_ROOT", project_cfg),
    ("_fpt_v24_build", project_cfg),
    ("fpt_patch_bd_generation_paths", create_script),
    ("BD wrapper escaped the current build root", create_script),
    ("source [file join $script_dir create_attention_board_project.tcl]",
     check_script),
]:
    if token not in text:
        fail(f"portable Vivado build guard missing: {token}")

for forbidden in [".Xil", "bd_staging", "vivado", "vitis/workspace"]:
    if (ROOT / forbidden).exists():
        fail(f"generated directory must not be in clean package: {forbidden}")

for script in ["project_config.tcl", "create_attention_board_project.tcl",
               "build_attention_board_all.tcl", "create_vitis_app_xsct.tcl",
               "run_on_board_no_gtr_xsct.tcl"]:
    if not (ROOT / "scripts" / script).is_file():
        fail(f"missing script: {script}")

print("================================================")
print("[PASS] clean board package static audit")
print(f"Version / groups : {CFG['version']} / {G}")
print(f"Core HDL files   : {len(core)}")
print(f"Board HDL files  : {len(board)}")
print(f"Unique modules   : {len(modules)}")
print("Golden vectors   : complete")
print("Generated clutter: absent")
print("Vendor PS BD     : present")
print("Vivado path guard: portable/clean")
print("================================================")
