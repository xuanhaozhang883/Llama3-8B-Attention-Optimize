#!/usr/bin/env python3
"""Freeze the verified v2.3 board baseline into a reproducible clean archive."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import zipfile
from datetime import date
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RELEASES = ROOT / "releases"
ARCHIVE_NAME = "FPT_XCZU15EG_Attention_v2.3_baseline_clean.zip"
ARCHIVE_ROOT = "FPT_XCZU15EG_Attention_v2.3_baseline"

SOURCE_ROOT_FILES = {
    ".gitignore",
    "CHANGELOG.md",
    "OPTIMIZATION_LOG.md",
    "README_CN.md",
    "STATUS.md",
    "project_config.json",
}
SOURCE_DIRS = (
    "bd_base",
    "doc",
    "logs",
    "mem",
    "python",
    "reports",
    "rtl",
    "scripts",
    "vitis/data",
    "vitis/src",
)
EXCLUDED_NAMES = {"__pycache__", ".DS_Store"}
EXCLUDED_SUFFIXES = {".pyc", ".jou", ".log"}

ARTIFACTS = {
    "bitstream": ROOT
    / "vivado/fpt_attention_board_v2_8group/"
    "fpt_attention_board_v2_8group.runs/impl_1/attention_board_top.bit",
    "xsa": ROOT / "export/fpt_attention_board_v2_8group.xsa",
    "elf": ROOT / "vitis/workspace/fpt_attention_test/Debug/fpt_attention_test.elf",
    "board_log": ROOT / "logs/v2.3_hardware_profile_10run.txt",
    "timing_report": ROOT / "reports/timing_summary_impl.rpt",
    "utilization_report": ROOT / "reports/utilization_impl.rpt",
    "power_report": ROOT / "reports/power_impl.rpt",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def source_files() -> list[Path]:
    files: set[Path] = set()
    for name in SOURCE_ROOT_FILES:
        path = ROOT / name
        if not path.is_file():
            raise FileNotFoundError(f"required source file missing: {path}")
        files.add(path)

    for dirname in SOURCE_DIRS:
        base = ROOT / dirname
        if not base.is_dir():
            raise FileNotFoundError(f"required source directory missing: {base}")
        for path in base.rglob("*"):
            if not path.is_file():
                continue
            if any(part in EXCLUDED_NAMES for part in path.parts):
                continue
            if path.suffix.lower() in EXCLUDED_SUFFIXES:
                continue
            if path.name in {"V2_3_BASELINE_SHA256.md"}:
                continue
            files.add(path)
    return sorted(files, key=lambda path: path.relative_to(ROOT).as_posix())


def rtl_tree_sha256() -> tuple[str, int]:
    rtl_files = sorted(
        list((ROOT / "rtl").rglob("*.v")) + list((ROOT / "rtl").rglob("*.sv")),
        key=lambda path: path.relative_to(ROOT).as_posix(),
    )
    digest = hashlib.sha256()
    for path in rtl_files:
        relative = path.relative_to(ROOT).as_posix()
        digest.update(f"{relative}\t{sha256_file(path)}\n".encode("utf-8"))
    return digest.hexdigest(), len(rtl_files)


def validate_board_log() -> None:
    text = ARTIFACTS["board_log"].read_text(encoding="utf-8")
    required = (
        "[PASS] v2.3 hardware profiling and ten-run benchmark passed",
        "Correct runs             : 10 / 10",
        "Combined failures             : 0",
        "Total PL cycles             : 276550520",
        "Average latency          : 1843.689 ms",
    )
    missing = [line for line in required if line not in text]
    if missing:
        raise RuntimeError(f"board log does not match frozen baseline: {missing}")


def artifact_records() -> dict[str, dict[str, object]]:
    records: dict[str, dict[str, object]] = {}
    for label, path in ARTIFACTS.items():
        if not path.is_file():
            raise FileNotFoundError(f"required baseline artifact missing: {path}")
        records[label] = {
            "path": path.relative_to(ROOT).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        }

    original_zip = ROOT.parent / "FPT_XCZU15EG_Attention_Board_v2.0.zip"
    if original_zip.is_file():
        records["original_workspace_zip"] = {
            "path": f"../{original_zip.name}",
            "bytes": original_zip.stat().st_size,
            "sha256": sha256_file(original_zip),
        }
    return records


def write_baseline_manifest(records: dict[str, dict[str, object]]) -> Path:
    rtl_hash, rtl_count = rtl_tree_sha256()
    lines = [
        "# v2.3 冻结基线 SHA-256",
        "",
        f"- 冻结日期：{date.today().isoformat()}",
        "- 配置：8 Groups / 32Q / 8KV / S128 / D128 / BF16",
        "- 板测：预热 1 次，正式 10 次，Combined failures = 0",
        f"- RTL 文件数：{rtl_count}",
        f"- RTL tree SHA-256：`{rtl_hash}`",
        "",
        "| 产物 | 路径 | Bytes | SHA-256 |",
        "|---|---|---:|---|",
    ]
    for label, record in records.items():
        lines.append(
            f"| {label} | `{record['path']}` | {record['bytes']} | "
            f"`{record['sha256']}` |"
        )
    lines.extend(
        [
            "",
            "RTL tree hash 的输入为按相对路径排序的每个 `.v`/`.sv` 文件路径与其 SHA-256。",
            "该文档标识冻结时的 v2.3；后续工作区 RTL 变化不会改变已生成的基线压缩包。",
            "",
        ]
    )
    output = ROOT / "doc/V2_3_BASELINE_SHA256.md"
    output.write_text("\n".join(lines), encoding="utf-8")
    return output


def write_package_manifest(files: list[Path]) -> Path:
    config = json.loads((ROOT / "project_config.json").read_text(encoding="utf-8"))
    records = [
        {
            "path": path.relative_to(ROOT).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        }
        for path in files
    ]
    manifest = {
        "name": config["name"],
        "version": config["version"],
        "target_part": config["target_part"],
        "vivado": config["vivado"],
        "scope": (
            f"{config['run_groups']} GQA groups, {config['q_heads']}Q/"
            f"{config['kv_heads']}KV, {config['datatype']}, "
            f"SEQ_LEN={config['seq_len']}, HEAD_DIM={config['head_dim']}"
        ),
        "file_count": len(records),
        "files": records,
    }
    output = ROOT / "PACKAGE_MANIFEST.json"
    output.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return output


def add_file(
    archive: zipfile.ZipFile, source: Path, archive_relative: str
) -> None:
    info = zipfile.ZipInfo(f"{ARCHIVE_ROOT}/{archive_relative}")
    info.date_time = (2026, 7, 28, 0, 0, 0)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o100644 << 16
    archive.writestr(info, source.read_bytes())


def create_archive(files: list[Path]) -> Path:
    RELEASES.mkdir(exist_ok=True)
    output = RELEASES / ARCHIVE_NAME
    if output.exists():
        raise FileExistsError(
            f"refusing to overwrite frozen baseline archive: {output}"
        )

    with zipfile.ZipFile(
        output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9
    ) as archive:
        for path in files:
            add_file(archive, path, path.relative_to(ROOT).as_posix())
        add_file(archive, ROOT / "PACKAGE_MANIFEST.json", "PACKAGE_MANIFEST.json")
        add_file(
            archive,
            ARTIFACTS["bitstream"],
            "artifacts/attention_board_top.bit",
        )
        add_file(
            archive,
            ARTIFACTS["xsa"],
            "artifacts/fpt_attention_board_v2_8group.xsa",
        )
        add_file(
            archive,
            ARTIFACTS["elf"],
            "artifacts/fpt_attention_test.elf",
        )
    return output


def audit_archive(archive_path: Path) -> str:
    with tempfile.TemporaryDirectory(prefix="fpt_v23_audit_") as temp:
        temp_path = Path(temp)
        with zipfile.ZipFile(archive_path) as archive:
            archive.extractall(temp_path)
        package_root = temp_path / ARCHIVE_ROOT
        result = subprocess.run(
            [sys.executable, str(package_root / "python/audit_package.py")],
            cwd=package_root,
            check=True,
            capture_output=True,
            text=True,
            encoding="utf-8",
        )
        return result.stdout


def write_release_sums(archive_path: Path) -> Path:
    output = RELEASES / "V2_3_RELEASE_SHA256SUMS.txt"
    output.write_text(
        f"{sha256_file(archive_path)}  {archive_path.name}\n",
        encoding="ascii",
    )
    return output


def main() -> None:
    validate_board_log()
    records = artifact_records()
    baseline_manifest = write_baseline_manifest(records)
    files = source_files()
    if baseline_manifest not in files:
        files.append(baseline_manifest)
        files.sort(key=lambda path: path.relative_to(ROOT).as_posix())
    write_package_manifest(files)
    archive = create_archive(files)
    audit_output = audit_archive(archive)
    sums = write_release_sums(archive)

    print("================================================")
    print("[PASS] v2.3 baseline frozen and clean package audited")
    print(f"Archive : {archive}")
    print(f"Bytes   : {archive.stat().st_size}")
    print(f"SHA-256 : {sha256_file(archive)}")
    print(f"Sums    : {sums}")
    print("Audit:")
    print(audit_output.rstrip())
    print("================================================")


if __name__ == "__main__":
    main()
