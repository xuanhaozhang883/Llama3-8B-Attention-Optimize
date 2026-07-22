#!/usr/bin/env python3
"""Validate the repository's fpga_slice tensors and prepare Vivado HEX files.

No random or synthetic attention data is generated. Q, K, V, intermediate
goldens, and final Context are read only from golden_model_outputs/fpga_slice.
The RoPE sin/cos tables are read from the repository's existing RoPE/data
files, which were generated for the same slice by prepare_rope_vectors.py.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np


SHAPES = {
    "q_before_rope.npy": (4, 128, 128),
    "k_before_rope.npy": (1, 128, 128),
    "v.npy": (1, 128, 128),
    "q_after_rope.npy": (4, 128, 128),
    "k_after_rope.npy": (1, 128, 128),
    "softmax_weights.npy": (4, 128, 128),
    "attn_out_per_head.npy": (4, 128, 128),
}

NPY_TO_HEX = {
    "q_before_rope.npy": "q_before_rope_bf16.hex",
    "k_before_rope.npy": "k_before_rope_bf16.hex",
    "v.npy": "v_bf16.hex",
    "q_after_rope.npy": "q_after_rope_golden_bf16.hex",
    "k_after_rope.npy": "k_after_rope_golden_bf16.hex",
    "softmax_weights.npy": "softmax_weights_bf16.hex",
    "attn_out_per_head.npy": "attn_out_per_head_bf16.hex",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def load_real_npy(path: Path, shape: tuple[int, ...]) -> np.ndarray:
    if not path.is_file():
        raise FileNotFoundError(f"missing golden tensor: {path}")
    prefix = path.read_bytes()[:64]
    if prefix.startswith(b"version https://git-lfs.github.com/spec/v1"):
        raise RuntimeError(
            f"{path} is only a Git LFS pointer, not array data. "
            "Run 'git lfs pull' in the repository or restore the real file."
        )
    array = np.load(path, allow_pickle=False)
    if array.shape != shape:
        raise ValueError(f"{path.name}: expected shape {shape}, got {array.shape}")
    if array.dtype != np.float32:
        raise TypeError(f"{path.name}: expected float32 storage, got {array.dtype}")
    if not np.isfinite(array).all():
        raise ValueError(f"{path.name}: NaN or Inf is not permitted")

    bits = array.view(np.uint32)
    if np.any(bits & np.uint32(0xFFFF)):
        raise ValueError(
            f"{path.name}: values are not already exact BF16 boundary values"
        )
    return array


def bf16_words(array: np.ndarray) -> np.ndarray:
    # The validated tensors already contain exact BF16 values in FP32 storage.
    return (array.view(np.uint32) >> np.uint32(16)).astype(np.uint16)


def read_hex(path: Path, expected_words: int) -> np.ndarray:
    if not path.is_file():
        raise FileNotFoundError(f"missing repository HEX file: {path}")
    words: list[int] = []
    with path.open("r", encoding="ascii") as handle:
        for line_number, line in enumerate(handle, 1):
            text = line.strip()
            if not text:
                continue
            try:
                value = int(text, 16)
            except ValueError as exc:
                raise ValueError(f"{path}:{line_number}: invalid HEX {text!r}") from exc
            if not 0 <= value <= 0xFFFF:
                raise ValueError(f"{path}:{line_number}: value is wider than BF16")
            words.append(value)
    if len(words) != expected_words:
        raise ValueError(f"{path}: expected {expected_words} words, got {len(words)}")
    return np.asarray(words, dtype=np.uint16)


def write_hex(path: Path, words: np.ndarray) -> None:
    with path.open("w", encoding="ascii", newline="\n") as handle:
        for word in np.asarray(words, dtype=np.uint16).reshape(-1):
            handle.write(f"{int(word):04X}\n")


def assert_existing_hex_matches(
    existing: Path, generated: np.ndarray, logical_name: str
) -> None:
    if not existing.is_file():
        return
    committed = read_hex(existing, int(generated.size))
    flat = np.asarray(generated, dtype=np.uint16).reshape(-1)
    mismatch = np.flatnonzero(committed != flat)
    if mismatch.size:
        index = int(mismatch[0])
        raise RuntimeError(
            f"{logical_name}: fpga_slice .npy disagrees with {existing} at "
            f"word {index}: npy={int(flat[index]):04X}, existing={int(committed[index]):04X}"
        )


def parse_args() -> argparse.Namespace:
    candidates = [Path.cwd(), Path(__file__).resolve().parent]
    candidates.extend(Path(__file__).resolve().parents)
    candidates.extend(Path.cwd().parents)
    default_root = Path.cwd()
    for candidate in candidates:
        if (
            (candidate / "golden_model_outputs" / "fpga_slice").is_dir()
            and (candidate / "A_attention_integration_final_v5").is_dir()
        ):
            default_root = candidate
            break

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--project-root",
        type=Path,
        default=default_root,
        help="Llama3-8B-Attention-Optimize-main directory",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=None,
        help="default: A_attention_integration_final_v5/tb/golden_fpga_slice_data",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.project_root.resolve()
    golden = root / "golden_model_outputs" / "fpga_slice"
    out_dir = (
        args.out_dir.resolve()
        if args.out_dir is not None
        else root / "A_attention_integration_final_v5" / "tb" / "golden_fpga_slice_data"
    )
    out_dir.mkdir(parents=True, exist_ok=True)

    arrays: dict[str, np.ndarray] = {}
    source_manifest: dict[str, object] = {}
    for name, shape in SHAPES.items():
        path = golden / name
        array = load_real_npy(path, shape)
        arrays[name] = array
        source_manifest[name] = {
            "path": path.relative_to(root).as_posix(),
            "shape": list(array.shape),
            "dtype": str(array.dtype),
            "sha256": sha256(path),
        }

    existing = {
        "q_before_rope.npy": root / "RoPE/data/q_before_rope_bf16.hex",
        "k_before_rope.npy": root / "RoPE/data/k_before_rope_bf16.hex",
        "q_after_rope.npy": root / "RoPE/data/q_after_rope_golden_bf16.hex",
        "k_after_rope.npy": root / "RoPE/data/k_after_rope_golden_bf16.hex",
        "v.npy": root / "PV_module/sim_data/v_bf16.hex",
        "softmax_weights.npy": root / "PV_module/sim_data/softmax_weights_bf16.hex",
        "attn_out_per_head.npy": root / "PV_module/sim_data/attn_out_per_head_bf16.hex",
    }

    output_manifest: dict[str, object] = {}
    for npy_name, hex_name in NPY_TO_HEX.items():
        words = bf16_words(arrays[npy_name])
        assert_existing_hex_matches(existing[npy_name], words, npy_name)
        output = out_dir / hex_name
        write_hex(output, words)
        output_manifest[hex_name] = {
            "words": int(words.size),
            "sha256": sha256(output),
            "source": npy_name,
        }

    # These exact tables were prepared by the repository's RoPE tooling from
    # the same Llama-3 theta=500000 definition and token range 0..127.
    for name in ("sin_bf16.hex", "cos_bf16.hex"):
        words = read_hex(root / "RoPE/data" / name, 128 * 64)
        output = out_dir / name
        write_hex(output, words)
        output_manifest[name] = {
            "words": int(words.size),
            "sha256": sha256(output),
            "source": f"RoPE/data/{name}",
        }

    manifest = {
        "purpose": "Raw Q/K -> RoPE -> QK -> causal mask -> Softmax -> real PV -> Context",
        "configuration": {
            "physical_gqa_groups": 8,
            "run_gqa_groups": 1,
            "q_heads_per_group": 4,
            "seq_len": 128,
            "head_dim": 128,
            "rope_pairing": "x0=dimension[pair], x1=dimension[pair+64]",
        },
        "sources": source_manifest,
        "outputs": output_manifest,
    }
    manifest_path = out_dir / "attention_fpga_slice_manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    print("================================================")
    print("[PASS] fpga_slice golden vectors validated")
    print(f"Source : {golden}")
    print(f"Output : {out_dir}")
    print("Q heads=4, KV heads=1, sequence=128, head_dim=128")
    print("No random/synthetic attention tensors were generated")
    print("================================================")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
