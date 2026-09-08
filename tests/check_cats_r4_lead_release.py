"""Verify recovered historical artifacts, not hardware or numerical correctness."""
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
ARCHIVE = ROOT / "docs/architecture_study_20260905"
HASHES = {
    "row_candidate_study.py": "d0fd8f57bbc904d7b291cf784f3b21fe7f363663448f13a703a7ed585bbd072d",
    "row_candidates_full.json": "1fe8cc632c0cef75d735ce9cd5f89778e1b5cf11d15f7a030555b04dc8d3dc86",
    "row_candidates_stress.json": "85bd41563851eb98b743607a0078c639c97c4a708f5ef6ad2354d602e88fc60a",
    "stress_candidate_study.py": "e354e996513ffa340dfbc9d5e3cbd36762b898b5c12f9b49e23d8baf0a334848",
}
INPUTS = {
    "q": "vitis/data/q_before_rope_bf16.hex",
    "k": "vitis/data/k_before_rope_bf16.hex",
    "v": "vitis/data/v_bf16.hex",
    "golden": "vitis/data/attn_out_per_head_bf16.hex",
    "sine": "mem/sin_bf16.hex",
    "cosine": "mem/cos_bf16.hex",
    "lut": "mem/exp_lut_q15.mem",
    "model": "python/flash_attention_tile_model.py",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    for name, expected in HASHES.items():
        require(hashlib.sha256((ARCHIVE / name).read_bytes()).hexdigest() == expected,
                f"archive SHA256 mismatch: {name}")
    full = json.loads((ARCHIVE / "row_candidates_full.json").read_text(encoding="utf-8"))
    stress = json.loads((ARCHIVE / "row_candidates_stress.json").read_text(encoding="utf-8"))
    require(full["heads"] == list(range(32)) and full["rows"] == list(range(128)), "full coverage")
    require(full["output_elements"] == 524288, "full output count")
    require(len(full["metrics"]) == 4, "full candidate count")
    require(all(m["elements"] == 524288 and m["combined_failures"] == 0
                for m in full["metrics"].values()), "full historical metrics")
    require((stress["seed"], stress["cases"], stress["elements"]) == (20260905, 32, 4096), "stress scope")
    for name, failures in {"online_q15": 482, "row_q15": 459, "row_fp32_exp_software": 0}.items():
        require(stress["metrics"][name]["combined_failures"] == failures, f"stress metrics: {name}")
    for name, relative in INPUTS.items():
        require(hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() == full["inputs"][name]["sha256"],
                f"current input differs from historical bytes: {relative}")
    print("PASS: 4 archive hashes, report structure/metrics, 8 input hashes")
    print("Scope: artifact identity only; no new numerical/RTL/OOC/board signoff")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
