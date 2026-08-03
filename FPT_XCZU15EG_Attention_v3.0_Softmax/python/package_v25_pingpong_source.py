#!/usr/bin/env python3
"""Create and verify the clean v2.5 Ping-Pong integration source archive."""

from __future__ import annotations

import hashlib
import json
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT.parents[1] / (
    "FPT_XCZU15EG_Attention_v2.5_pingpong_integration_source.zip"
)
ARCHIVE_ROOT = "FPT_XCZU15EG_Attention_v2.5_pingpong_integration"
EXCLUDED_TOPS = {
    ".Xil",
    "export",
    "vivado",
    "vivado_v25_pingpong_unit",
    "bd_staging",
    "releases",
}
EXCLUDED_NAMES = {"PACKAGE_MANIFEST.json", "__pycache__", ".DS_Store"}
EXCLUDED_SUFFIXES = {
    ".bit",
    ".dcp",
    ".jou",
    ".log",
    ".pyc",
    ".str",
    ".xsa",
    ".zip",
}


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def source_files() -> list[Path]:
    files: list[Path] = []
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
        "scope": (
            "8 GQA groups, 32Q/8KV, BF16, "
            "SEQ_LEN=128, HEAD_DIM=128"
        ),
        "artifact_policy": (
            "clean v2.5 integration source and v2.4 baseline evidence; "
            "generated bit/XSA/DCP/workspaces are excluded"
        ),
        "board_verified": False,
        "baseline_board_verified": "v2.4-profile-counters-board-pass",
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
    info.date_time = (2026, 7, 30, 0, 0, 0)
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

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix="v25_pingpong_",
        suffix=".zip",
        delete=False,
        dir=OUTPUT.parent,
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

    print("================================================")
    print("[PASS] v2.5 Ping-Pong clean source archive")
    print(f"Files   : {len(files) + 1}")
    print(f"Archive : {OUTPUT}")
    print(f"Bytes   : {OUTPUT.stat().st_size}")
    print(f"SHA-256 : {sha256_bytes(OUTPUT.read_bytes())}")
    print("================================================")


if __name__ == "__main__":
    main()
