#!/usr/bin/env python3
"""Create the deterministic v3.0 release ZIP and package manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PACKAGE_NAME = "FPT_XCZU15EG_Attention_v3.0_Softmax"
FIXED_ZIP_TIME = (2026, 8, 3, 0, 0, 0)
RELEASE_ARTIFACTS = {
    Path("export/fpt_attention_board_v30_causal_dualtile.bit"),
    Path("export/fpt_attention_board_v30_causal_dualtile.xsa"),
}


def excluded(relative: Path) -> bool:
    if relative in RELEASE_ARTIFACTS:
        return False
    parts = set(relative.parts)
    if parts & {
        ".git",
        ".Xil",
        "__pycache__",
        "archive_online_2025_2",
        "b",
        "export",
        "vivado",
        "workspace",
    }:
        return True
    if relative.name in {
        "PACKAGE_MANIFEST.json",
        "dfx_runtime.txt",
        "xelab.pb",
        "xvlog.pb",
    }:
        return True
    return relative.suffix.lower() in {".zip", ".bit", ".xsa", ".dcp", ".jou", ".log"}


def source_files() -> list[Path]:
    return sorted(
        path
        for path in ROOT.rglob("*")
        if path.is_file() and not excluded(path.relative_to(ROOT))
    )


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_manifest(files: list[Path]) -> Path:
    records = []
    for path in files:
        relative = path.relative_to(ROOT).as_posix()
        records.append(
            {
                "path": relative,
                "bytes": path.stat().st_size,
                "sha256": digest(path),
            }
        )
    manifest = {
        "name": PACKAGE_NAME,
        "version": "3.0-online-softmax-exact-denominator-board-pass",
        "target_part": "xczu15eg-ffvb1156-2-i",
        "vivado": "2024.2 (synthesis, implementation, timing, DRC, BIT/XSA and board validation)",
        "frequency_mhz": 150.0,
        "scope": "8 GQA groups, 32Q/8KV, BF16, SEQ_LEN=128, HEAD_DIM=128",
        "features": [
            "v2.5 cross-Group Ping-Pong",
            "causal QK whole-tile skip",
            "dual 4x4 QK",
            "native TILE4 capture",
            "causal PV row-effective reduction",
            "dual 4x4 PV",
            "streaming online Softmax with cross-row state isolation",
            "exact denominator path for BF16 1-ULP board agreement",
        ],
        "baseline_source_sha256": (
            "711bdadf66cc54e7176ee59c58fe3c889064cc38ba3b64d5a4e893e97fc1832f"
        ),
        "board_verified": True,
        "validation": (
            "host/Icarus and Vivado XSIM regression pass; Vivado 2024.2 XCZU15EG "
            "synthesis, route, timing, DRC, bitstream and XSA pass; board correctness "
            "and determinism pass 10/10 with zero combined failures"
        ),
        "validation_vivado": "2024.2",
        "board_test_date": "2026-08-03",
        "correct_runs": 10,
        "deterministic_runs": 10,
        "combined_failures": 0,
        "manifest_self_excluded": True,
        "file_count": len(records),
        "files": records,
    }
    output = ROOT / "PACKAGE_MANIFEST.json"
    output.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return output


def write_zip(files: list[Path], manifest: Path, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(
        output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as archive:
        for path in [*files, manifest]:
            relative = path.relative_to(ROOT).as_posix()
            info = zipfile.ZipInfo(f"{PACKAGE_NAME}/{relative}", FIXED_ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT.parent / f"{PACKAGE_NAME}.zip",
    )
    parser.add_argument(
        "--manifest-only",
        action="store_true",
        help="refresh PACKAGE_MANIFEST.json without creating the source ZIP",
    )
    args = parser.parse_args()
    files = source_files()
    manifest = write_manifest(files)
    if args.manifest_only:
        print(f"MANIFEST={manifest}")
        print(f"FILES={len(files)}")
        return
    write_zip(files, manifest, args.output.resolve())
    print(f"PACKAGE={args.output.resolve()}")
    print(f"FILES={len(files) + 1}")
    print(f"SHA256={digest(args.output.resolve())}")


if __name__ == "__main__":
    main()
