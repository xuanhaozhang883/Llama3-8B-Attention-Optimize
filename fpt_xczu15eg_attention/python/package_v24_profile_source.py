#!/usr/bin/env python3
"""Create a deterministic board-validated v2.4 source/evidence archive."""

from __future__ import annotations

import hashlib
import json
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = (
    ROOT.parent
    / "FPT_XCZU15EG_Attention_v2.4_profile_source_board_pass.zip"
)
ARCHIVE_ROOT = "FPT_XCZU15EG_Attention_v2.4_profile_source"
EXCLUDED_TOPS = {
    "artifacts",
    "export",
    "vivado",
    "bd_staging",
    ".Xil",
    "releases",
}
EXCLUDED_NAMES = {"PACKAGE_MANIFEST.json", "__pycache__", ".DS_Store"}
EXCLUDED_SUFFIXES = {".pyc", ".jou", ".zip"}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source_files() -> list[Path]:
    files = []
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT)
        if relative.parts[0] in EXCLUDED_TOPS:
            continue
        if any(part in EXCLUDED_NAMES for part in relative.parts):
            continue
        if path.suffix.lower() in EXCLUDED_SUFFIXES:
            continue
        files.append(path)
    return sorted(files, key=lambda item: item.relative_to(ROOT).as_posix())


def manifest_bytes(files: list[Path]) -> bytes:
    config = json.loads((ROOT / "project_config.json").read_text("utf-8"))
    records = []
    for path in files:
        data = path.read_bytes()
        records.append(
            {
                "path": path.relative_to(ROOT).as_posix(),
                "bytes": len(data),
                "sha256": sha256_bytes(data),
            }
        )
    manifest = {
        "name": config["name"],
        "version": config["version"],
        "target_part": config["target_part"],
        "vivado": config["vivado"],
        "scope": "8 GQA groups, 32Q/8KV, BF16, SEQ_LEN=128, HEAD_DIM=128",
        "artifact_policy": (
            "source and verification evidence; bit/XSA/ELF are distributed "
            "separately in the board-validated Vitis one-click package"
        ),
        "file_count": len(records),
        "files": records,
    }
    return (
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    ).encode("utf-8")


def write_member(
    archive: zipfile.ZipFile, relative: str, data: bytes
) -> None:
    info = zipfile.ZipInfo(f"{ARCHIVE_ROOT}/{relative}")
    info.date_time = (2026, 7, 29, 0, 0, 0)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    archive.writestr(info, data)


def verify_archive(path: Path) -> None:
    with zipfile.ZipFile(path) as archive:
        bad = archive.testzip()
        if bad is not None:
            raise RuntimeError(f"ZIP CRC failure: {bad}")
        manifest = json.loads(
            archive.read(f"{ARCHIVE_ROOT}/PACKAGE_MANIFEST.json")
        )
        for item in manifest["files"]:
            data = archive.read(f"{ARCHIVE_ROOT}/{item['path']}")
            if len(data) != item["bytes"]:
                raise RuntimeError(f"size mismatch: {item['path']}")
            if sha256_bytes(data) != item["sha256"]:
                raise RuntimeError(f"hash mismatch: {item['path']}")


def main() -> None:
    files = source_files()
    manifest = manifest_bytes(files)
    (ROOT / "PACKAGE_MANIFEST.json").write_bytes(manifest)

    with tempfile.NamedTemporaryFile(
        prefix="v24_profile_", suffix=".zip", delete=False, dir=OUTPUT.parent
    ) as stream:
        temporary = Path(stream.name)

    try:
        with zipfile.ZipFile(
            temporary,
            "w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
        ) as archive:
            for path in files:
                write_member(
                    archive,
                    path.relative_to(ROOT).as_posix(),
                    path.read_bytes(),
                )
            write_member(archive, "PACKAGE_MANIFEST.json", manifest)
        verify_archive(temporary)
        temporary.replace(OUTPUT)
    finally:
        if temporary.exists():
            temporary.unlink()

    digest = hashlib.sha256(OUTPUT.read_bytes()).hexdigest()
    print("================================================")
    print("[PASS] v2.4 profiling source archive")
    print(f"Files   : {len(files) + 1}")
    print(f"Archive : {OUTPUT}")
    print(f"Bytes   : {OUTPUT.stat().st_size}")
    print(f"SHA-256 : {digest}")
    print("================================================")


if __name__ == "__main__":
    main()
