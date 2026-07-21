#!/usr/bin/env python3
"""Print shapes and basic statistics for the PV NumPy files."""

from pathlib import Path
import numpy as np

sim_dir = Path(__file__).resolve().parents[1] / "sim_data"

for name in [
    "softmax_weights.npy",
    "v.npy",
    "attn_out_per_head.npy",
]:
    array = np.load(sim_dir / name, allow_pickle=False)
    print(
        f"{name:28s} shape={array.shape!s:16s} "
        f"dtype={array.dtype} "
        f"min={float(array.min()):.9g} "
        f"max={float(array.max()):.9g}"
    )
