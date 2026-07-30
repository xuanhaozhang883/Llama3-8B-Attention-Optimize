#!/usr/bin/env python3
"""Generate BF16 HEX files and verify the supplied PV golden reference."""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path

import numpy as np


EXPECTED = {
    "softmax_weights.npy": (4, 128, 128),
    "v.npy": (1, 128, 128),
    "attn_out_per_head.npy": (4, 128, 128),
}


def fp32_to_bf16_rne_bits(array: np.ndarray) -> np.ndarray:
    arr = np.asarray(array, dtype=np.float32)
    bits = arr.view(np.uint32)
    lsb = (bits >> 16) & np.uint32(1)
    bias = np.uint32(0x7FFF) + lsb
    return ((bits + bias) >> 16).astype(np.uint16)


def bf16_bits_to_fp32(bits: np.ndarray) -> np.ndarray:
    return (bits.astype(np.uint32) << np.uint32(16)).view(np.float32)


def write_hex(path: Path, values: np.ndarray) -> None:
    with path.open("w", encoding="ascii", newline="\n") as f:
        for value in values.reshape(-1):
            f.write(f"{int(value):04x}\n")


def load_checked(path: Path, expected_shape: tuple[int, ...]) -> np.ndarray:
    array = np.load(path, allow_pickle=False)
    if array.shape != expected_shape:
        raise ValueError(
            f"{path.name}: expected shape {expected_shape}, got {array.shape}"
        )
    if array.dtype != np.float32:
        raise TypeError(
            f"{path.name}: expected float32, got {array.dtype}"
        )
    if not np.all(np.isfinite(array)):
        raise ValueError(f"{path.name}: contains NaN or Inf")
    return array


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--sim-data-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "sim_data",
    )
    parser.add_argument(
        "--install-dir",
        type=Path,
        default=None,
        help="Optional ASCII-only Vivado runtime directory, e.g. D:/pv_sim_data",
    )
    args = parser.parse_args()

    sim_dir = args.sim_data_dir.resolve()
    sim_dir.mkdir(parents=True, exist_ok=True)

    p = load_checked(
        sim_dir / "softmax_weights.npy",
        EXPECTED["softmax_weights.npy"],
    )
    v = load_checked(
        sim_dir / "v.npy",
        EXPECTED["v.npy"],
    )
    gold = load_checked(
        sim_dir / "attn_out_per_head.npy",
        EXPECTED["attn_out_per_head.npy"],
    )

    p_bits = fp32_to_bf16_rne_bits(p)
    v_bits = fp32_to_bf16_rne_bits(v)
    gold_bits = fp32_to_bf16_rne_bits(gold)

    p_fp32 = bf16_bits_to_fp32(p_bits)
    v_fp32 = bf16_bits_to_fp32(v_bits)[0]

    acc = np.zeros((4, 128, 128), dtype=np.float32)
    for k in range(128):
        product = np.float32(
            p_fp32[:, :, k, None] * v_fp32[k, None, :]
        )
        acc = np.float32(acc + product)

    recomputed_bits = fp32_to_bf16_rne_bits(acc)
    mismatches = np.argwhere(recomputed_bits != gold_bits)

    if len(mismatches):
        h, row, col = (int(x) for x in mismatches[0])
        raise RuntimeError(
            "Golden reference mismatch at "
            f"h={h}, row={row}, col={col}: "
            f"calc={int(recomputed_bits[h,row,col]):04x}, "
            f"gold={int(gold_bits[h,row,col]):04x}"
        )

    outputs = {
        "softmax_weights_bf16.hex": p_bits,
        "v_bf16.hex": v_bits,
        "attn_out_per_head_bf16.hex": gold_bits,
    }
    for name, bits in outputs.items():
        write_hex(sim_dir / name, bits)

    manifest = {
        "P_shape": list(p.shape),
        "V_shape": list(v.shape),
        "Context_shape": list(gold.shape),
        "total_outputs": int(gold_bits.size),
        "reference_matches": int(gold_bits.size),
        "reference_mismatches": 0,
        "first_hex": {
            "P": f"{int(p_bits.flat[0]):04x}",
            "V": f"{int(v_bits.flat[0]):04x}",
            "Context": f"{int(gold_bits.flat[0]):04x}",
        },
    }
    (sim_dir / "pv_data_manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    print("========================================")
    print("PV BF16 HEX generation complete")
    print(f"P       : {p_bits.size} values")
    print(f"V       : {v_bits.size} values")
    print(f"Context : {gold_bits.size} values")
    print(f"Reference check: {gold_bits.size}/{gold_bits.size} PASS")
    print(
        "First values: "
        f"P={int(p_bits.flat[0]):04x}, "
        f"V={int(v_bits.flat[0]):04x}, "
        f"Context={int(gold_bits.flat[0]):04x}"
    )

    if args.install_dir is not None:
        install_dir = args.install_dir
        install_dir.mkdir(parents=True, exist_ok=True)

        for name in outputs:
            shutil.copy2(sim_dir / name, install_dir / name)

        shutil.copy2(
            sim_dir / "pv_data_manifest.json",
            install_dir / "pv_data_manifest.json",
        )
        print(f"Vivado simulation data installed to: {install_dir}")

    print("========================================")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
