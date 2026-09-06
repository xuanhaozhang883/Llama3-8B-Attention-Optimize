#!/usr/bin/env python3
"""Read-only CATS-R4 C2 toolchain and source-tree preflight.

The checker deliberately does not execute Vivado, Vitis, or XSCT.  Tool
versions and device installation are established from installation paths and
the Vivado on-disk part database, so PASS is conservative and reproducible.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
from dataclasses import asdict, dataclass
from pathlib import Path


EXPECTED_VERSION = "2025.2"
EXPECTED_PART = "xczu15eg-ffvb1156-2-i"
RTL_SUFFIXES = {".v", ".sv", ".vhd", ".vhdl"}
MAX_BUILD_ROOT_CHARS = 80
NON_PRODUCTION_RTL = {
    "rtl/core/cluster/cats_r4_cluster_shell.sv",
}


@dataclass(frozen=True)
class Check:
    name: str
    status: str
    detail: str


def pass_check(name: str, detail: str) -> Check:
    return Check(name, "PASS", detail)


def blocked(name: str, detail: str) -> Check:
    return Check(name, "BLOCKED", detail)


def normalized(path: Path) -> Path:
    return Path(os.path.abspath(os.path.normpath(str(path))))


def is_below(path: Path, parent: Path) -> bool:
    try:
        normalized(path).relative_to(normalized(parent))
        return True
    except ValueError:
        return False


def tool_candidates(name: str, override: str | None, env_root: str | None) -> list[Path]:
    candidates: list[Path] = []
    if override:
        candidates.append(Path(override))
    located = shutil.which(name) or shutil.which(f"{name}.bat") or shutil.which(f"{name}.exe")
    if located:
        candidates.append(Path(located))
    if env_root:
        root = Path(env_root)
        candidates.extend(root / "bin" / leaf for leaf in (name, f"{name}.bat", f"{name}.exe"))
    result: list[Path] = []
    seen: set[str] = set()
    for candidate in candidates:
        candidate = normalized(candidate)
        key = os.path.normcase(str(candidate))
        if key not in seen:
            seen.add(key)
            result.append(candidate)
    return result


def find_tool(name: str, override: str | None, env_root: str | None) -> Path | None:
    return next((path for path in tool_candidates(name, override, env_root) if path.is_file()), None)


def path_has_version(path: Path, expected: str) -> bool:
    # Installation roots normally contain a component named exactly 2025.2.
    return expected.casefold() in {part.casefold() for part in path.parts}


def check_tool(name: str, override: str | None, env_root: str | None) -> tuple[Check, Path | None]:
    path = find_tool(name, override, env_root)
    if path is None:
        return blocked(name, f"executable not found (PATH/override/install root); expected {EXPECTED_VERSION}"), None
    if not path_has_version(path, EXPECTED_VERSION):
        return blocked(name, f"found {path}, but its path does not prove version {EXPECTED_VERSION}"), path
    return pass_check(name, f"{path} (path proves {EXPECTED_VERSION}; executable was not started)"), path


def vivado_root(vivado: Path | None) -> Path | None:
    env_root = os.environ.get("XILINX_VIVADO")
    if env_root:
        root = normalized(Path(env_root))
        if root.is_dir():
            return root
    if vivado is not None and vivado.parent.name.casefold() == "bin":
        return vivado.parent.parent
    return None


def check_device_database(root: Path | None) -> Check:
    if root is None:
        return blocked("device_database", "Vivado installation root could not be established")
    parts_root = root / "data" / "parts"
    if not parts_root.is_dir():
        return blocked("device_database", f"Vivado part database is missing: {parts_root}")

    # The speed/package-qualified part normally appears in XML content while
    # the device name appears in a directory or filename.  Limit reads to
    # small text/XML metadata and stop at the first exact token.
    device_token = "xczu15eg"
    part_token = EXPECTED_PART.casefold()
    device_path_seen = False
    files_read = 0
    try:
        for directory, subdirs, files in os.walk(parts_root):
            subdirs[:] = [item for item in subdirs if item.casefold() not in {"simmodels", "templates"}]
            directory_path = Path(directory)
            if device_token in str(directory_path).casefold():
                device_path_seen = True
            for filename in files:
                candidate = directory_path / filename
                lower_name = filename.casefold()
                if device_token in lower_name:
                    device_path_seen = True
                if candidate.suffix.casefold() not in {".xml", ".txt", ".csv"}:
                    continue
                try:
                    if candidate.stat().st_size > 4 * 1024 * 1024:
                        continue
                    files_read += 1
                    if part_token in candidate.read_text(encoding="utf-8", errors="ignore").casefold():
                        return pass_check("device_database", f"{EXPECTED_PART} found in {candidate}")
                except OSError:
                    continue
    except OSError as exc:
        return blocked("device_database", f"cannot read {parts_root}: {exc}")
    hint = "xczu15eg device path exists, but exact package/speed part was not found" if device_path_seen else "xczu15eg was not found"
    return blocked("device_database", f"{hint} under {parts_root} ({files_read} metadata files inspected)")


def parse_manifest(manifest: Path, source_root: Path) -> tuple[list[Path], str | None]:
    try:
        text = manifest.read_text(encoding="utf-8")
    except OSError as exc:
        return [], str(exc)
    entries: list[Path] = []
    pattern = re.compile(r"\[file\s+join\s+\$board_root\s+([^\]]+)\]")
    for match in pattern.finditer(text):
        tokens = match.group(1).split()
        if tokens:
            entries.append(normalized(source_root.joinpath(*tokens)))
    return entries, None


def production_rtl(source_root: Path) -> set[Path]:
    rtl_root = source_root / "rtl"
    if not rtl_root.is_dir():
        return set()
    result: set[Path] = set()
    for path in rtl_root.rglob("*"):
        source_relative = path.relative_to(source_root).as_posix()
        relative_parts = {part.casefold() for part in path.relative_to(rtl_root).parts}
        if relative_parts.intersection({"archive", "tb", "test", "tests", "sim", "simulation"}):
            continue
        if source_relative in NON_PRODUCTION_RTL:
            continue
        if path.is_file() and path.suffix.casefold() in RTL_SUFFIXES:
            result.add(normalized(path))
    return result


def check_manifest(source_root: Path) -> list[Check]:
    manifest = source_root / "scripts" / "source_manifest.tcl"
    entries, error = parse_manifest(manifest, source_root)
    if error:
        return [blocked("source_manifest", f"cannot read {manifest}: {error}")]
    if not entries:
        return [blocked("source_manifest", f"no board_root entries parsed from {manifest}")]
    missing = sorted(path for path in entries if not path.is_file())
    manifest_rtl = {path for path in entries if path.suffix.casefold() in RTL_SUFFIXES}
    disk_rtl = production_rtl(source_root)
    unlisted = sorted(disk_rtl - manifest_rtl)
    stale = sorted(manifest_rtl - disk_rtl)
    checks = []
    if missing:
        checks.append(blocked("manifest_files_exist", "missing: " + ", ".join(str(path) for path in missing[:8])))
    else:
        checks.append(pass_check("manifest_files_exist", f"all {len(entries)} manifest entries exist"))
    if unlisted or stale:
        detail_parts = []
        if unlisted:
            detail_parts.append(
                f"unlisted production RTL ({len(unlisted)}): "
                + ", ".join(str(path.relative_to(source_root)) for path in unlisted)
            )
        if stale:
            detail_parts.append(
                f"manifest RTL outside production scan ({len(stale)}): "
                + ", ".join(str(path.relative_to(source_root)) for path in stale)
            )
        checks.append(blocked("manifest_covers_rtl", "; ".join(detail_parts)))
    else:
        checks.append(pass_check("manifest_covers_rtl", f"manifest exactly covers {len(disk_rtl)} production RTL files"))
    return checks


def check_project_part(source_root: Path) -> Check:
    config = source_root / "scripts" / "project_config.tcl"
    try:
        text = config.read_text(encoding="utf-8")
    except OSError as exc:
        return blocked("project_part", f"cannot read {config}: {exc}")
    match = re.search(r'set\s+fpt_target_part\s+"([^"]+)"', text)
    if match is None:
        return blocked("project_part", "fpt_target_part is not declared")
    actual = match.group(1)
    if actual != EXPECTED_PART:
        return blocked("project_part", f"configured {actual}; expected {EXPECTED_PART}")
    return pass_check("project_part", actual)


def check_build_root(build_root_arg: str, source_root: Path) -> list[Check]:
    build_root = normalized(Path(build_root_arg))
    checks: list[Check] = []
    if not Path(build_root_arg).is_absolute():
        checks.append(blocked("build_root_absolute", f"must be absolute: {build_root_arg}"))
    else:
        checks.append(pass_check("build_root_absolute", str(build_root)))
    try:
        str(build_root).encode("ascii")
        ascii_only = True
    except UnicodeEncodeError:
        ascii_only = False
    if not ascii_only or any(character.isspace() for character in str(build_root)):
        checks.append(blocked("build_root_ascii", "path must contain only ASCII and no whitespace"))
    elif len(str(build_root)) > MAX_BUILD_ROOT_CHARS:
        checks.append(blocked("build_root_ascii", f"path length {len(str(build_root))} exceeds {MAX_BUILD_ROOT_CHARS}"))
    else:
        checks.append(pass_check("build_root_ascii", f"ASCII/no-whitespace, length={len(str(build_root))}"))
    if is_below(build_root, source_root) or build_root == normalized(source_root):
        checks.append(blocked("build_root_outside_source", f"must be outside source root {source_root}"))
    else:
        checks.append(pass_check("build_root_outside_source", str(build_root)))
    if build_root.exists():
        checks.append(blocked("build_root_fresh", f"already exists: {build_root}"))
    else:
        checks.append(pass_check("build_root_fresh", "path does not exist; checker did not create it"))
    parent = build_root.parent
    if parent.is_dir() and os.access(parent, os.W_OK):
        checks.append(pass_check("build_root_parent", f"existing writable parent: {parent}"))
    else:
        checks.append(blocked("build_root_parent", f"parent missing or not writable: {parent}"))
    return checks


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--build-root", required=True, help="planned new short ASCII build root; it must not exist")
    parser.add_argument("--vivado", help="optional path to vivado executable/batch file")
    parser.add_argument("--vitis", help="optional path to vitis executable/batch file")
    parser.add_argument("--xsct", help="optional path to xsct executable/batch file")
    parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = parser.parse_args()

    source_root = normalized(Path(args.source_root))
    checks: list[Check] = []
    vivado_check, vivado_path = check_tool("vivado", args.vivado, os.environ.get("XILINX_VIVADO"))
    vitis_check, _ = check_tool("vitis", args.vitis, os.environ.get("XILINX_VITIS"))
    xsct_check, _ = check_tool("xsct", args.xsct, os.environ.get("XILINX_VITIS"))
    checks.extend((vivado_check, vitis_check, xsct_check))
    checks.append(check_device_database(vivado_root(vivado_path)))
    checks.append(check_project_part(source_root))
    checks.extend(check_manifest(source_root))
    checks.extend(check_build_root(args.build_root, source_root))

    overall = "PASS" if all(item.status == "PASS" for item in checks) else "BLOCKED"
    if args.json:
        print(json.dumps({"status": overall, "checks": [asdict(item) for item in checks]}, indent=2))
    else:
        for item in checks:
            print(f"[{item.status}] {item.name}: {item.detail}")
        print(f"C2_TOOLCHAIN_PREFLIGHT={overall}")
    return 0 if overall == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
