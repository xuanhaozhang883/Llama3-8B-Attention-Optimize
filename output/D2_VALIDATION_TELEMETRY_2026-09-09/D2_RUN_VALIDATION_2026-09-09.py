#!/usr/bin/env python3
"""Run the D2 software/contract evidence package without modifying production RTL."""

from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
from decimal import Decimal, localcontext
import hashlib
import json
import math
from pathlib import Path
import random
import struct
import subprocess
import sys
from typing import Iterable, Sequence


INTERFACE_TAG = "CATS_R4_INTERFACE_V3_COMMIT"
INTERFACE_COMMIT = "4d386e0f8f39c9f3c6de5ffa2ced408f254146ee"
ABS_LIMIT = 1.0e-4
ULP_LIMIT = 1

EXPECTED_ARCHIVE_HASHES = {
    "row_candidate_study.py": "d0fd8f57bbc904d7b291cf784f3b21fe7f363663448f13a703a7ed585bbd072d",
    "row_candidates_full.json": "1fe8cc632c0cef75d735ce9cd5f89778e1b5cf11d15f7a030555b04dc8d3dc86",
    "row_candidates_stress.json": "85bd41563851eb98b743607a0078c639c97c4a708f5ef6ad2354d602e88fc60a",
    "stress_candidate_study.py": "e354e996513ffa340dfbc9d5e3cbd36762b898b5c12f9b49e23d8baf0a334848",
}

INPUT_PATHS = {
    "q": "vitis/data/q_before_rope_bf16.hex",
    "k": "vitis/data/k_before_rope_bf16.hex",
    "v": "vitis/data/v_bf16.hex",
    "golden": "vitis/data/attn_out_per_head_bf16.hex",
    "sine": "mem/sin_bf16.hex",
    "cosine": "mem/cos_bf16.hex",
    "lut": "mem/exp_lut_q15.mem",
    "model": "python/flash_attention_tile_model.py",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_command(repo: Path, output: Path, name: str, command: list[str]) -> dict[str, object]:
    completed = subprocess.run(
        command,
        cwd=repo,
        text=True,
        encoding="utf-8",
        errors="replace",
        capture_output=True,
        check=False,
    )
    rendered = "$ " + subprocess.list2cmdline(command) + "\n"
    rendered += completed.stdout
    if completed.stderr:
        rendered += "\n[stderr]\n" + completed.stderr
    rendered += f"\n[exit_code] {completed.returncode}\n"
    log = output / "logs" / f"{name}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(rendered, encoding="utf-8")
    return {
        "name": name,
        "command": command,
        "exit_code": completed.returncode,
        "log": str(log.relative_to(output)),
    }


def f32(value: float) -> float:
    return struct.unpack(">f", struct.pack(">f", float(value)))[0]


def f32_bits(value: float) -> int:
    return struct.unpack(">I", struct.pack(">f", f32(value)))[0]


def f32_to_bf16_bits(value: float) -> int:
    bits = f32_bits(value)
    upper = bits >> 16
    lower = bits & 0xFFFF
    if lower > 0x8000 or (lower == 0x8000 and (upper & 1)):
        upper = (upper + 1) & 0xFFFF
    return upper


def bf16_to_float(bits: int) -> float:
    return struct.unpack(">f", struct.pack(">I", (bits & 0xFFFF) << 16))[0]


def bf16_ordered(bits: int) -> int:
    return 0xFFFF - bits if bits & 0x8000 else bits + 0x8000


def bf16_ulp(a: int, b: int) -> int:
    return abs(bf16_ordered(a) - bf16_ordered(b))


@dataclass
class Metrics:
    elements: int = 0
    different: int = 0
    strict_abs_failures: int = 0
    over_one_ulp: int = 0
    combined_failures: int = 0
    max_abs_error: float = 0.0
    max_ulp: int = 0

    def add(self, actual: Iterable[int], expected: Iterable[int]) -> None:
        for got, want in zip(actual, expected):
            absolute = abs(bf16_to_float(got) - bf16_to_float(want))
            distance = bf16_ulp(got, want)
            self.elements += 1
            self.different += int(got != want)
            self.strict_abs_failures += int(absolute > ABS_LIMIT)
            self.over_one_ulp += int(distance > ULP_LIMIT)
            self.combined_failures += int(absolute > ABS_LIMIT and distance > ULP_LIMIT)
            self.max_abs_error = max(self.max_abs_error, absolute)
            self.max_ulp = max(self.max_ulp, distance)


def float_reference(scores: Sequence[int], masks: Sequence[bool], values: Sequence[Sequence[int]]) -> list[int]:
    decoded = [bf16_to_float(word) for word in scores]
    valid = [score for score, mask in zip(decoded, masks) if not mask]
    if not valid:
        raise ValueError("all-masked row is illegal for causal CATS-R4")
    maximum = max(valid)
    weights = [0.0 if mask else math.exp(score - maximum) for score, mask in zip(decoded, masks)]
    denominator = math.fsum(weights)
    result = []
    for feature in range(len(values[0])):
        terms = [weight * bf16_to_float(row[feature]) for weight, row in zip(weights, values)]
        result.append(f32_to_bf16_bits(math.fsum(terms) / denominator))
    return result


def decimal_reference(scores: Sequence[int], masks: Sequence[bool], values: Sequence[Sequence[int]]) -> list[int]:
    with localcontext() as context:
        context.prec = 80
        decoded = [Decimal.from_float(bf16_to_float(word)) for word in scores]
        valid = [score for score, mask in zip(decoded, masks) if not mask]
        if not valid:
            raise ValueError("all-masked row is illegal for causal CATS-R4")
        maximum = max(valid)
        weights = [Decimal(0) if mask else (score - maximum).exp() for score, mask in zip(decoded, masks)]
        denominator = sum(weights, Decimal(0))
        result = []
        for feature in range(len(values[0])):
            numerator = sum(
                (weight * Decimal.from_float(bf16_to_float(row[feature]))
                 for weight, row in zip(weights, values)),
                Decimal(0),
            )
            result.append(f32_to_bf16_bits(float(numerator / denominator)))
        return result


def make_case(scores: Sequence[float], value_rows: Sequence[Sequence[float]], row: int) -> tuple[list[int], list[bool], list[list[int]]]:
    return (
        [f32_to_bf16_bits(value) for value in scores],
        [key > row for key in range(len(scores))],
        [[f32_to_bf16_bits(value) for value in values] for values in value_rows],
    )


def independent_reference_selftest() -> dict[str, object]:
    directed = [
        ("equal_scores", [0.0, 0.0], [[1.0, 0.0], [0.0, 1.0]], 1),
        ("late_max", [-8.0, -4.0, 0.0], [[1.0, -1.0], [0.5, 0.5], [-1.0, 1.0]], 2),
        ("positive_negative_cancel", [0.0, 0.0], [[1.0, -1.0], [-1.0, 1.0]], 1),
        ("causal_row_zero", [1.0, 9.0, 12.0], [[0.25, -0.25], [1.0, 1.0], [-1.0, -1.0]], 0),
        ("long_tail", [0.0, -2.0, -6.0, -12.0], [[1.0, 0.0], [0.0, 1.0], [-1.0, 0.5], [0.25, -0.25]], 3),
    ]
    metrics = Metrics()
    cases = []
    for name, scores, values, row in directed:
        encoded_scores, masks, encoded_values = make_case(scores, values, row)
        actual = float_reference(encoded_scores, masks, encoded_values)
        expected = decimal_reference(encoded_scores, masks, encoded_values)
        metrics.add(actual, expected)
        cases.append({"name": name, "outputs": len(actual), "max_case_ulp": max(bf16_ulp(a, b) for a, b in zip(actual, expected))})

    rng = random.Random(20260909)
    for case_index in range(64):
        length = 1 + rng.randrange(16)
        dimension = 8
        row = rng.randrange(length)
        scores = [rng.uniform(-12.0, 12.0) for _ in range(length)]
        values = [[rng.uniform(-2.0, 2.0) for _ in range(dimension)] for _ in range(length)]
        encoded_scores, masks, encoded_values = make_case(scores, values, row)
        metrics.add(
            float_reference(encoded_scores, masks, encoded_values),
            decimal_reference(encoded_scores, masks, encoded_values),
        )

    rejected = []
    invalid_inputs = {
        "nonfinite_score": lambda: math.isfinite(float("inf")),
        "negative_weight": lambda: -1.0 >= 0.0,
        "nonpositive_sum": lambda: 0.0 > 0.0,
        "nonfinite_inv_sum": lambda: math.isfinite(float("nan")),
        "illegal_numeric_mode": lambda: 2 in (0, 1),
    }
    for name, valid in invalid_inputs.items():
        if valid():
            raise AssertionError(f"negative classifier failed: {name}")
        rejected.append(name)

    result = {
        "reference_a": "Python FP64 math.exp + math.fsum",
        "reference_b": "Decimal precision=80 exp/sum/PV",
        "final_rounding": "BF16 RNE",
        "threshold": {"absolute": ABS_LIMIT, "bf16_ordered_ulp": ULP_LIMIT, "rule": "abs OR ulp"},
        "directed_cases": cases,
        "random_seed": 20260909,
        "random_cases": 64,
        "metrics": asdict(metrics),
        "negative_classifications": rejected,
        "passed": metrics.combined_failures == 0 and len(rejected) == len(invalid_inputs),
    }
    return result


class ProtocolError(ValueError):
    pass


class ProtocolChecker:
    def __init__(self) -> None:
        self.slots: dict[tuple[int, int, int, int, int, int], dict[str, object]] = {}
        self.counters = {
            "weight_wr_accept": 0,
            "weight_rd_request": 0,
            "weight_rd_response": 0,
            "row_commit_count": 0,
            "pv_row_count": 0,
            "weight_release_count": 0,
        }

    def allocate(self, token: tuple[int, int, int, int, int, int]) -> None:
        epoch, group, head, row, slot, mode = token
        if token in self.slots or group != head >> 2 or not 0 <= row < 128 or slot not in range(3) or mode not in (0, 1):
            raise ProtocolError("invalid or duplicate token")
        self.slots[token] = {"state": "SOFTMAX", "next_key": 0, "outstanding": 0, "output": False}

    def write(self, token: tuple[int, int, int, int, int, int], key: int, mask: bool, data: int, last: bool) -> None:
        state = self.slots[token]
        if state["state"] != "SOFTMAX" or key != state["next_key"]:
            raise ProtocolError("write order/owner")
        row = token[3]
        if mask != (key > row) or last != (key == 127) or (mask and data != 0):
            raise ProtocolError("mask/last/data")
        state["next_key"] = key + 1
        self.counters["weight_wr_accept"] += 1

    def commit(self, token: tuple[int, int, int, int, int, int]) -> None:
        state = self.slots[token]
        if state["state"] != "SOFTMAX" or state["next_key"] != 128:
            raise ProtocolError("early commit")
        state["state"] = "SEALED"
        self.counters["row_commit_count"] += 1

    def pv_row(self, token: tuple[int, int, int, int, int, int]) -> None:
        state = self.slots[token]
        if state["state"] != "SEALED":
            raise ProtocolError("pv before commit")
        state["state"] = "PV"
        self.counters["pv_row_count"] += 1

    def read_request(self, token: tuple[int, int, int, int, int, int]) -> None:
        state = self.slots[token]
        if state["state"] != "PV":
            raise ProtocolError("read without PV owner")
        state["outstanding"] += 1
        self.counters["weight_rd_request"] += 1

    def read_response(self, token: tuple[int, int, int, int, int, int]) -> None:
        state = self.slots[token]
        if state["outstanding"] <= 0:
            raise ProtocolError("response without request")
        state["outstanding"] -= 1
        self.counters["weight_rd_response"] += 1

    def accept_output(self, token: tuple[int, int, int, int, int, int]) -> None:
        self.slots[token]["output"] = True

    def release(self, token: tuple[int, int, int, int, int, int]) -> None:
        state = self.slots[token]
        if state["state"] != "PV" or state["outstanding"] != 0 or not state["output"]:
            raise ProtocolError("early release")
        state["state"] = "FREE"
        self.counters["weight_release_count"] += 1


def protocol_selftest() -> dict[str, object]:
    checker = ProtocolChecker()
    positive_tokens = [(1, 0, 0, 0, 0, 1), (1, 0, 3, 127, 1, 1)]
    for token in positive_tokens:
        checker.allocate(token)
        for key in range(128):
            mask = key > token[3]
            checker.write(token, key, mask, 0 if mask else 0x3F800000, key == 127)
        checker.commit(token)
        checker.pv_row(token)
        for _key in range(token[3] + 1):
            checker.read_request(token)
            checker.read_response(token)
        checker.accept_output(token)
        checker.release(token)

    negative_tests = {}

    def expect_error(name: str, action) -> None:
        try:
            action()
        except (ProtocolError, KeyError):
            negative_tests[name] = "detected"
        else:
            negative_tests[name] = "missed"

    duplicate = ProtocolChecker()
    duplicate.allocate((1, 0, 0, 0, 0, 1))
    expect_error("duplicate_token", lambda: duplicate.allocate((1, 0, 0, 0, 0, 1)))

    bad_mask = ProtocolChecker()
    bad_mask.allocate((1, 0, 0, 0, 0, 1))
    expect_error("mask_mismatch", lambda: bad_mask.write((1, 0, 0, 0, 0, 1), 0, True, 0, False))

    bad_last = ProtocolChecker()
    bad_last.allocate((1, 0, 0, 0, 0, 1))
    expect_error("last_mismatch", lambda: bad_last.write((1, 0, 0, 0, 0, 1), 0, False, 0x3F800000, True))

    early_commit = ProtocolChecker()
    early_commit.allocate((1, 0, 0, 0, 0, 1))
    expect_error("early_commit", lambda: early_commit.commit((1, 0, 0, 0, 0, 1)))

    early_release = ProtocolChecker()
    token = (1, 0, 0, 0, 0, 1)
    early_release.allocate(token)
    for key in range(128):
        early_release.write(token, key, key > 0, 0 if key > 0 else 0x3F800000, key == 127)
    early_release.commit(token)
    early_release.pv_row(token)
    early_release.read_request(token)
    expect_error("release_with_outstanding", lambda: early_release.release(token))

    passed = (
        checker.counters["weight_rd_request"] == checker.counters["weight_rd_response"]
        and checker.counters["row_commit_count"] == len(positive_tokens)
        and checker.counters["weight_release_count"] == len(positive_tokens)
        and all(value == "detected" for value in negative_tests.values())
    )
    return {
        "scope": "checker selftest only; no RTL event log supplied",
        "positive_tokens": len(positive_tokens),
        "positive_counters": checker.counters,
        "negative_tests": negative_tests,
        "passed": passed,
    }


def workload_contract() -> dict[str, object]:
    rows = 32 * 128
    valid_exp = 32 * sum(range(1, 129))
    values = {
        "rows": rows,
        "valid_exp": valid_exp,
        "valid_qk_mac": valid_exp * 128,
        "valid_pv_mac": valid_exp * 128,
        "context_words": rows * 128,
        "weight_writes_including_masked": rows * 128,
        "row_commit": rows,
        "pv_row": rows,
        "weight_release": rows,
        "ddr_read_beats": (32 + 8 + 8) * 128 * 128 * 2 // 8,
        "ddr_write_beats": rows * 128 * 2 // 8,
        "rows_committed": rows,
    }
    expected = {
        "rows": 4096,
        "valid_exp": 264192,
        "valid_qk_mac": 33816576,
        "valid_pv_mac": 33816576,
        "context_words": 524288,
        "weight_writes_including_masked": 524288,
        "row_commit": 4096,
        "pv_row": 4096,
        "weight_release": 4096,
        "ddr_read_beats": 196608,
        "ddr_write_beats": 131072,
        "rows_committed": 4096,
    }
    return {"actual": values, "expected": expected, "passed": values == expected}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--d1-artifacts", type=Path)
    args = parser.parse_args()
    repo = args.repo.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    commands = []
    commands.append(run_command(repo, output, "entry_identity", [sys.executable, "tests/check_cats_r4_lead_release.py"]))
    commands.append(run_command(repo, output, "v3_capacity", [sys.executable, "tests/test_cats_r4_v3_capacity.py"]))

    tag = subprocess.run(
        ["git", "rev-parse", f"{INTERFACE_TAG}^{{commit}}"], cwd=repo,
        text=True, encoding="utf-8", capture_output=True, check=False,
    )
    resolved_tag = tag.stdout.strip()

    archive = repo / "docs/architecture_study_20260905"
    full = json.loads((archive / "row_candidates_full.json").read_text(encoding="utf-8"))
    stress = json.loads((archive / "row_candidates_stress.json").read_text(encoding="utf-8"))

    input_manifest = {}
    for name, relative in INPUT_PATHS.items():
        path = repo / relative
        current = sha256(path)
        expected = full["inputs"][name]["sha256"]
        input_manifest[name] = {
            "path": relative,
            "bytes": path.stat().st_size,
            "sha256": current,
            "expected_sha256": expected,
            "matches": current == expected,
        }
    archive_manifest = {
        name: {
            "path": f"docs/architecture_study_20260905/{name}",
            "sha256": sha256(archive / name),
            "expected_sha256": expected,
            "matches": sha256(archive / name) == expected,
        }
        for name, expected in EXPECTED_ARCHIVE_HASHES.items()
    }
    interface_path = repo / "docs/CATS_R4_INTERFACE_V3.md"
    manifest = {
        "schema_version": "D2_HASH_MANIFEST_V1",
        "interface": {
            "tag": INTERFACE_TAG,
            "resolved_commit": resolved_tag,
            "expected_commit": INTERFACE_COMMIT,
            "document": str(interface_path.relative_to(repo)),
            "document_sha256": sha256(interface_path),
        },
        "inputs": input_manifest,
        "historical_archive": archive_manifest,
    }
    if args.d1_artifacts and args.d1_artifacts.exists():
        manifest["d1_artifacts"] = {
            path.name: {"bytes": path.stat().st_size, "sha256": sha256(path)}
            for path in sorted(args.d1_artifacts.glob("D1_V314_SIGNOFF_2026-09-04.*"))
        }
    write_json(output / "D2_INPUT_HASH_MANIFEST.json", manifest)

    historical = {
        "full": {
            "outputs": full["output_elements"],
            "combined_failures": {name: value["combined_failures"] for name, value in full["metrics"].items()},
            "software_only": True,
        },
        "stress": {
            "seed": stress["seed"],
            "cases": stress["cases"],
            "elements": stress["elements"],
            "combined_failures": {name: value["combined_failures"] for name, value in stress["metrics"].items()},
            "software_only": True,
        },
    }
    historical["passed"] = (
        historical["full"]["outputs"] == 524288
        and all(value == 0 for value in historical["full"]["combined_failures"].values())
        and historical["stress"]["combined_failures"] == {
            "online_q15": 482, "row_q15": 459, "row_fp32_exp_software": 0
        }
    )
    write_json(output / "D2_HISTORICAL_REPORT_AUDIT.json", historical)

    independent = independent_reference_selftest()
    protocol = protocol_selftest()
    workload = workload_contract()
    write_json(output / "D2_INDEPENDENT_REFERENCE_SELFTEST.json", independent)
    write_json(output / "D2_PROTOCOL_CHECKER_SELFTEST.json", protocol)
    write_json(output / "D2_WORKLOAD_CONTRACT.json", workload)

    seed_output = output / "D2_REPRO_SEED_12794_RERUN.json"
    seed_command = run_command(repo, output, "seed_12794", [
        sys.executable, "python/flash_attention_tile_model.py", "--synthetic",
        "--seed", "12794", "--cases", "1", "--length", "128", "--dimension", "128",
        "--tile", "4", "--json", str(seed_output),
    ])
    commands.append(seed_command)
    seed = json.loads(seed_output.read_text(encoding="utf-8"))
    seed_expected = {
        "fused_tile_vs_scalar_tile": 0,
        "fused_vs_mathematical_reference": 10,
        "fused_vs_v30": 13,
        "v30_vs_mathematical_reference": 23,
    }
    seed_reproduced = all(seed[name]["combined_failures"] == expected for name, expected in seed_expected.items())

    stress_output = output / "D2_CURRENT_MODEL_STRESS_SEED_20260905.json"
    stress_command = run_command(repo, output, "current_model_stress_20260905", [
        sys.executable, "python/flash_attention_tile_model.py", "--synthetic",
        "--seed", "20260905", "--cases", "32", "--length", "128", "--dimension", "128",
        "--tile", "4", "--json", str(stress_output),
    ])
    commands.append(stress_command)

    full_output = output / "D2_FULL_GQA_RTL_EXACT_RERUN.json"
    full_command = run_command(repo, output, "full_gqa_rtl_exact", [
        sys.executable, "python/flash_attention_tile_model.py", "--full-board", "--rtl-exact-only",
        "--json", str(full_output),
    ])
    commands.append(full_command)

    hashes_pass = all(item["matches"] for item in input_manifest.values()) and all(item["matches"] for item in archive_manifest.values())
    entry_pass = commands[0]["exit_code"] == 0
    capacity_pass = commands[1]["exit_code"] == 0
    full_pass = full_command["exit_code"] == 0 and full_output.exists()
    stress_completed = stress_output.exists()
    contract_ready = all([
        resolved_tag == INTERFACE_COMMIT,
        entry_pass,
        capacity_pass,
        hashes_pass,
        historical["passed"],
        independent["passed"],
        protocol["passed"],
        workload["passed"],
        seed_reproduced,
        stress_completed,
        full_pass,
    ])

    git_status = subprocess.run(
        ["git", "status", "--short", "--branch"], cwd=repo,
        text=True, encoding="utf-8", capture_output=True, check=False,
    ).stdout.strip()

    summary = {
        "schema_version": "D2_VALIDATION_SUMMARY_V1",
        "date": "2026-09-09",
        "stage": "D2",
        "status": "READY" if contract_ready else "NOT READY",
        "meaning": "validation contract/tooling readiness; not CATS-R4 hardware readiness",
        "identity": {
            "interface_tag": INTERFACE_TAG,
            "interface_commit": resolved_tag,
            "expected_interface_commit": INTERFACE_COMMIT,
            "git_status": git_status,
        },
        "gates": {
            "entry_identity": entry_pass,
            "v3_capacity": capacity_pass,
            "input_and_archive_hashes": hashes_pass,
            "historical_report_audit": historical["passed"],
            "independent_reference_selftest": independent["passed"],
            "protocol_checker_selftest": protocol["passed"],
            "workload_contract": workload["passed"],
            "seed_12794_reproduced": seed_reproduced,
            "current_stress_diagnostic_completed": stress_completed,
            "full_gqa_rtl_exact_model": full_pass,
        },
        "evidence_levels": {
            "software_reference": "RUN",
            "historical_artifact_identity": "RUN",
            "protocol_checker_selftest": "RUN",
            "new_rtl": "NOT RUN",
            "xsim": "NOT RUN",
            "ooc_synthesis": "NOT RUN",
            "full_board_implementation": "NOT RUN",
            "board_test": "NOT RUN",
        },
        "known_risks": {
            "historical_stress_online_q15_failures": 482,
            "historical_stress_row_q15_failures": 459,
            "seed_12794_fused_vs_math_failures": 10,
            "line_endings": "Windows core.autocrlf changed byte identity; five LF files were restored before validation",
            "b2_accuracy": "No B2 hardware implementation or hardware exp/reciprocal result supplied",
        },
        "commands": commands,
    }
    write_json(output / "D2_VALIDATION_SUMMARY.json", summary)

    report = f"""# D2 CATS-R4 验证结果\n\n日期：2026-09-09  \n状态：**{summary['status']}（仅验证契约/工具）**\n\n## 结论\n\nD2 软件与契约门禁{'全部通过' if contract_ready else '存在未通过项'}。该状态不代表 CATS-R4 RTL、XSim、OOC、整板或板测 READY。\n\n## 已执行结果\n\n- v3 tag：`{resolved_tag}`，{'匹配' if resolved_tag == INTERFACE_COMMIT else '不匹配'}冻结提交。\n- 历史原件及 8 个输入哈希：{'PASS' if hashes_pass else 'FAIL'}。\n- v3 capacity/workload 单测：{'PASS' if capacity_pass else 'FAIL'}。\n- 独立 FP64 与 Decimal(80) 参考交叉自测：{'PASS' if independent['passed'] else 'FAIL'}，combined_failures={independent['metrics']['combined_failures']}。\n- 协议 checker 正/负向自测：{'PASS' if protocol['passed'] else 'FAIL'}。\n- seed 12794 已知风险复现：{'PASS' if seed_reproduced else 'FAIL'}。\n- 当前模型 stress 诊断：{'完成' if stress_completed else '未完成'}；结果只作软件诊断。\n- full-GQA RTL-exact 软件模型：{'PASS' if full_pass else 'FAIL'}。\n\n## 保留的风险\n\n- 历史 stress：online_q15=482 failures，row_q15=459 failures；不得删除。\n- seed 12794：fused-vs-math=10，fused-vs-v30=13，v30-vs-math=23。\n- Python math.exp 与 Decimal 参考自测不等于硬件 exp/reciprocal 签核。\n- 当前没有 B2 Accuracy RTL、RTL event log、XSim、OOC、全板或新板测输入，全部标记 NOT RUN。\n\n## 下一依赖\n\n等待 B 提交 B2/B3 完整源码、TB、日志、branch 和 commit；等待 A compute-cluster 与 C single-board READY。收到候选后按本 D2 契约进入 D3 独立审查和公平消融。\n"""
    (output / "D2_VALIDATION_REPORT.md").write_text(report, encoding="utf-8")

    delivery = f"""# D2 DELIVERY\n\n- 日期：2026-09-09\n- 阶段：D2\n- 状态：{summary['status']}（validation contract/tooling only）\n- base/head：{resolved_tag}\n- interface：{INTERFACE_TAG} / {INTERFACE_COMMIT}\n- 结果目录：本目录\n- 软件证据：RUN\n- RTL/XSim/OOC/full-board/board：NOT RUN\n- 阈值：abs<=1e-4 OR BF16 ordered ULP<=1\n- 已知失败：stress online_q15=482、row_q15=459；seed12794 fused-vs-math=10\n- 下一依赖：B2/B3、A compute cluster、C single-board 候选及各自完整 commit/log\n\n详细门禁见 `D2_VALIDATION_SUMMARY.json`，人类可读结论见 `D2_VALIDATION_REPORT.md`。\n"""
    (output / "D2_DELIVERY.md").write_text(delivery, encoding="utf-8")

    print(json.dumps({"status": summary["status"], "output": str(output), "gates": summary["gates"]}, indent=2))
    return 0 if contract_ready else 1


if __name__ == "__main__":
    raise SystemExit(main())
