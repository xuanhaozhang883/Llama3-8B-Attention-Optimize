"""Check canonical repository paths and reject duplicated/generated sources."""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]

CANONICAL_FILES = (
    "project_config.json",
    "scripts/source_manifest.tcl",
    "rtl/board/attention_board_top.sv",
    "python/flash_attention_tile_model.py",
    "tests/run_v31_flash_numerical_model.ps1",
    "vitis/data/q_before_rope_bf16.hex",
    "vitis/data/k_before_rope_bf16.hex",
    "vitis/data/v_bf16.hex",
    "vitis/data/attn_out_per_head_bf16.hex",
    "vitis/src/fpt_golden_vectors.h",
    "python/generate_golden_header.py",
    "python/signoff_v31_board_log.py",
    "mem/sin_bf16.hex",
    "mem/cos_bf16.hex",
    "mem/exp_lut_q15.mem",
)

FORBIDDEN_TRACKED = {
    "03_work_v314_causal_bypass.zip",
    "cos_bf16.hex",
    "sin_bf16.hex",
    "exp_lut_q15.mem",
}

FORBIDDEN_PREFIXES = (
    ".Xil/",
    "vivado/",
    "vitis/workspace/",
    "golden_model_outputs/",
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def tracked_files() -> set[str]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
    )
    return {
        item.decode("utf-8").replace("\\", "/")
        for item in result.stdout.split(b"\0")
        if item
    }


def main() -> int:
    tracked = tracked_files()
    for relative in CANONICAL_FILES:
        require((ROOT / relative).is_file(), f"missing canonical file: {relative}")
        require(relative in tracked, f"canonical file is not tracked: {relative}")

    bad_exact = sorted(tracked & FORBIDDEN_TRACKED)
    require(not bad_exact, f"forbidden tracked files: {bad_exact}")
    bad_prefix = sorted(
        path for path in tracked if path.startswith(FORBIDDEN_PREFIXES)
    )
    require(not bad_prefix, f"forbidden tracked paths: {bad_prefix}")

    for duplicate in ("cos_bf16.hex", "sin_bf16.hex", "exp_lut_q15.mem"):
        require(not (ROOT / duplicate).exists(), f"remove root ROM duplicate: {duplicate}")

    with tempfile.TemporaryDirectory(prefix="fpt_golden_header_check_") as temp:
        rebuilt = Path(temp) / "fpt_golden_vectors.h"
        subprocess.run(
            [
                sys.executable,
                str(ROOT / "python/generate_golden_header.py"),
                "--output",
                str(rebuilt),
            ],
            cwd=ROOT,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        expected = ROOT / "vitis/src/fpt_golden_vectors.h"
        require(
            rebuilt.read_bytes() == expected.read_bytes(),
            "derived fpt_golden_vectors.h differs from canonical vitis/data inputs",
        )

    print("PASS: canonical paths, tracked-file policy, ROM uniqueness, generated header")
    print("Scope: repository layout and byte identity only; no RTL/board signoff")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
