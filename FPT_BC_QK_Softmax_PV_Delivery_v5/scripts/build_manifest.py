#!/usr/bin/env python3
"""Regenerate deterministic file inventory and SHA-256 manifest."""
from hashlib import sha256
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILE_LIST = ROOT / "FILE_LIST.txt"
MANIFEST = ROOT / "MANIFEST_SHA256.txt"


def included_files(exclude: set[str]) -> list[Path]:
    result: list[Path] = []
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(ROOT).as_posix()
        if relative in exclude:
            continue
        if any(part.startswith("vivado_") for part in path.relative_to(ROOT).parts):
            continue
        result.append(path)
    return sorted(result, key=lambda item: item.relative_to(ROOT).as_posix())


def main() -> None:
    inventory = included_files({"FILE_LIST.txt", "MANIFEST_SHA256.txt"})
    FILE_LIST.write_text(
        "\n".join(path.relative_to(ROOT).as_posix() for path in inventory) + "\n",
        encoding="utf-8",
    )

    manifest_files = included_files({"MANIFEST_SHA256.txt"})
    lines = []
    for path in manifest_files:
        digest = sha256(path.read_bytes()).hexdigest()
        lines.append(f"{digest}  ./{path.relative_to(ROOT).as_posix()}")
    MANIFEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"PASS: regenerated inventory={len(inventory)} manifest={len(lines)}")


if __name__ == "__main__":
    main()
