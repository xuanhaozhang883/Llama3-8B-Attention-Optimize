#!/usr/bin/env python3
"""Check the RTL/C/Python profiling-page and CSV contracts."""

from __future__ import annotations

import importlib.util
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TOP = (ROOT / "rtl/board/attention_board_top.sv").read_text(encoding="utf-8")
ENGINE = (ROOT / "rtl/board/fpt_attention_board_engine.sv").read_text(
    encoding="utf-8"
)
CORE_TOP = (
    ROOT / "rtl/core/a/attention_system_with_rope_pv_top.sv"
).read_text(encoding="utf-8")
C_APP = (ROOT / "vitis/src/fpt_attention_board_test.c").read_text(
    encoding="utf-8"
)
PARSER_PATH = ROOT / "python/parse_v23_profile_log.py"

EXPECTED_NEW_PAGES = {
    "PROF_ROPE_BUSY_CYCLES": 27,
    "PROF_QK_BUSY_CYCLES": 28,
    "PROF_MASK_BUSY_CYCLES": 29,
    "PROF_SOFTMAX_BUSY_CYCLES": 30,
    "PROF_BC_BACKEND_BUSY_CYCLES": 31,
    "PROF_CAPTURE_BUSY_CYCLES": 32,
    "PROF_CONTEXT_TRANSFER_CYCLES": 33,
    "PROF_BC_PV_OVERLAP_CYCLES": 34,
    "PROF_CORE_IDLE_CYCLES": 35,
    "PROF_REPACK_STALL_CYCLES": 36,
    "PROF_PV_FEED_STALL_CYCLES": 37,
    "PROF_SOFTMAX_STALL_CYCLES": 38,
    "PROF_INTERSTAGE_WAIT_CYCLES": 39,
}


def fail(message: str) -> None:
    raise SystemExit(f"[FAIL] {message}")


def load_parser_module():
    spec = importlib.util.spec_from_file_location("profile_parser", PARSER_PATH)
    if spec is None or spec.loader is None:
        fail("cannot load profile parser module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def printf_placeholder_count(prefix: str) -> int:
    match = re.search(
        rf'xil_printf\("({re.escape(prefix)}[^"]*)"', C_APP, re.MULTILINE
    )
    if not match:
        fail(f"{prefix} printf format not found")
    return match.group(1).count("%lu")


def main() -> None:
    if "logic [5:0] profile_page;" not in TOP:
        fail("RTL profile page selector is not 6-bit")
    if "assign profile_page = gpio_control[8:3];" not in TOP:
        fail("RTL profile selector does not use gpio_control[8:3]")
    if "#define CTRL_PROFILE_MASK  (0x3FU << CTRL_PROFILE_SHIFT)" not in C_APP:
        fail("C profile mask is not 6-bit")
    if "((page & 0x3FU) << CTRL_PROFILE_SHIFT)" not in C_APP:
        fail("C profile control word still truncates pages")

    enum_values = {
        name: int(value)
        for name, value in re.findall(
            r"\b(PROF_[A-Z0-9_]+)\s*=\s*(\d+)", C_APP
        )
    }
    for name, expected in EXPECTED_NEW_PAGES.items():
        if enum_values.get(name) != expected:
            fail(f"{name}: expected page {expected}, got {enum_values.get(name)}")
        if not re.search(rf"\b6'd{expected}\s*:", TOP):
            fail(f"RTL case page {expected} missing")

    if len(set(EXPECTED_NEW_PAGES.values())) != len(EXPECTED_NEW_PAGES):
        fail("duplicate profiling page assignment")

    parser = load_parser_module()
    if len(parser.FIELDS) != printf_placeholder_count("HWPROF_CSV,"):
        fail("legacy HWPROF_CSV field count differs between C and Python")
    if len(parser.FINE_FIELDS) != printf_placeholder_count("HWPROF_FINE_CSV,"):
        fail("fine HWPROF_FINE_CSV field count differs between C and Python")

    for name in EXPECTED_NEW_PAGES:
        if f"read_profile_page({name})" not in C_APP:
            fail(f"C application never reads {name}")

    rtl_counter_signals = {
        "prof_rope_busy_cycles": "core_rope_busy",
        "prof_qk_busy_cycles": "core_qk_busy",
        "prof_mask_busy_cycles": "core_mask_busy",
        "prof_softmax_busy_cycles": "core_softmax_busy",
        "prof_bc_backend_busy_cycles": "core_bc_backend_busy",
        "prof_capture_busy_cycles": "core_capture_busy",
        "prof_repack_stall_cycles": "core_repack_input_stall",
        "prof_pv_feed_stall_cycles": "core_pv_feed_stall",
        "prof_softmax_stall_cycles": "core_softmax_output_stall",
    }
    for counter, signal in rtl_counter_signals.items():
        if f"output logic [31:0] {counter}" not in ENGINE:
            fail(f"board engine output missing: {counter}")
        if not re.search(
            rf"if\s*\(\s*{signal}\s*\)\s*{counter}\s*<=",
            ENGINE,
            re.MULTILINE,
        ):
            fail(f"{counter} is not incremented from {signal}")
        if f".{counter}" not in TOP:
            fail(f"board top does not connect {counter}")

    required_core_outputs = (
        "rope_busy",
        "qk_busy",
        "mask_busy",
        "softmax_busy",
        "bc_backend_busy",
        "capture_busy",
        "repack_input_stall",
        "pv_feed_stall",
        "softmax_output_stall",
    )
    for signal in required_core_outputs:
        if not re.search(rf"\boutput\s+logic\s+{signal}\b", CORE_TOP):
            fail(f"core observation output missing: {signal}")
        if f".{signal}(core_{signal})" not in ENGINE:
            fail(f"board engine does not connect core signal {signal}")

    active_match = re.search(
        r"assign\s+core_any_stage_busy\s*=(.*?);",
        ENGINE,
        re.DOTALL,
    )
    if not active_match:
        fail("core_any_stage_busy union not found")
    active_union = active_match.group(1)
    for signal in ("raw_busy", "core_rope_busy", "core_qk_busy",
                   "core_mask_busy", "core_softmax_busy",
                   "core_bc_backend_busy", "core_capture_busy",
                   "core_pv_busy", "ctx_busy"):
        if signal not in active_union:
            fail(f"core activity union omits {signal}")

    if "context_valid && context_ready" not in ENGINE:
        fail("context transfer handshake counter missing")
    if "core_bc_busy && core_pv_busy" not in ENGINE:
        fail("B+C/PV overlap counter condition missing")

    print("================================================")
    print("[PASS] profiling RTL/C/Python contract")
    print("Profile selector : 6 bits / 64 pages")
    print("Legacy pages     : 0..26 preserved")
    print("Fine pages       : 27..39")
    print(f"Legacy CSV fields: {len(parser.FIELDS)}")
    print(f"Fine CSV fields  : {len(parser.FINE_FIELDS)}")
    print("================================================")


if __name__ == "__main__":
    main()
