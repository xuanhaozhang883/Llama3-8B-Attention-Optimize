#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import tempfile
import zipfile
from pathlib import Path

import numpy as np

NAMES = {
    "q_before_rope": "q_before_rope_bf16.hex",
    "k_before_rope": "k_before_rope_bf16.hex",
    "v": "v_bf16.hex",
    "attn_out_per_head": "attn_out_per_head_bf16.hex",
}


def load_npy(source: Path, scope: str, name: str, temp: Path) -> np.ndarray:
    rel = Path("golden_model_outputs") / scope / f"{name}.npy"
    if source.is_file():
        with zipfile.ZipFile(source) as zf:
            member = rel.as_posix()
            if member not in zf.namelist():
                raise FileNotFoundError(f"{member} not found in {source}")
            zf.extract(member, temp)
        path = temp / rel
    else:
        candidates = [source / rel, source / scope / f"{name}.npy", source / f"{name}.npy"]
        path = next((p for p in candidates if p.is_file()), None)
        if path is None:
            raise FileNotFoundError(f"Cannot locate {name}.npy under {source}")
    return np.load(path)


def to_bf16_words(array: np.ndarray) -> np.ndarray:
    f32 = np.ascontiguousarray(array, dtype=np.float32)
    return (f32.view(np.uint32) >> 16).astype(np.uint16)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    cfg = json.loads((root / "project_config.json").read_text(encoding="utf-8"))
    parser = argparse.ArgumentParser(description="Prepare BF16 board vectors from golden_model_outputs")
    parser.add_argument("--source", type=Path, required=True,
                        help="golden_model_outputs.zip or extracted golden directory")
    args = parser.parse_args()

    run_groups = int(cfg["run_groups"])
    seq_len = int(cfg["seq_len"])
    head_dim = int(cfg["head_dim"])
    q_heads = int(cfg["q_heads"])
    kv_heads = int(cfg["kv_heads"])
    scope = str(cfg["golden_scope"])
    out_dir = root / "vitis" / "data"
    out_dir.mkdir(parents=True, exist_ok=True)

    expected = {
        "q_before_rope": (q_heads, seq_len, head_dim),
        "k_before_rope": (kv_heads, seq_len, head_dim),
        "v": (kv_heads, seq_len, head_dim),
        "attn_out_per_head": (q_heads, seq_len, head_dim),
    }

    with tempfile.TemporaryDirectory() as td:
        temp = Path(td)
        for name, filename in NAMES.items():
            arr = load_npy(args.source, scope, name, temp)
            target_shape = expected[name]
            if arr.ndim != 3 or arr.shape[0] < target_shape[0] or arr.shape[1] < seq_len or arr.shape[2] != head_dim:
                raise ValueError(f"{name}: source shape {arr.shape} cannot provide {target_shape}")
            arr = arr[:target_shape[0], :seq_len, :]
            if arr.shape != target_shape:
                raise ValueError(f"{name}: expected {target_shape}, got {arr.shape}")
            words = to_bf16_words(arr).reshape(-1)
            (out_dir / filename).write_text("".join(f"{int(x):04X}\n" for x in words), encoding="ascii")
            print(f"{name:22s} {arr.shape} -> {filename} ({words.size} words)")

    # Reuse the package's authoritative header generator.
    import subprocess, sys
    subprocess.run([sys.executable, str(root / "python" / "generate_golden_header.py")], check=True)
    print(f"[PASS] prepared {run_groups} GQA group(s) from {args.source}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
