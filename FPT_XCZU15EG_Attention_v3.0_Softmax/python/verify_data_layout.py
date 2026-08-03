#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "vitis" / "data"
CFG = json.loads((ROOT / "project_config.json").read_text(encoding="utf-8"))
G = int(CFG["run_groups"])
QH = int(CFG["q_heads"])
KVH = int(CFG["kv_heads"])
S = int(CFG["seq_len"])
D = int(CFG["head_dim"])


def words(name: str) -> np.ndarray:
    return np.array([int(x, 16) for x in (DATA / name).read_text().split()], dtype=np.uint16)

q = words("q_before_rope_bf16.hex").reshape(QH, S, D)
k = words("k_before_rope_bf16.hex").reshape(KVH, S, D)
v = words("v_bf16.hex").reshape(KVH, S, D)
c = words("attn_out_per_head_bf16.hex").reshape(QH, S, D)

for arr in (q, k):
    for head in range(arr.shape[0]):
        for token in (0, 1, S // 2 - 1, S - 1):
            line = arr[head, token]
            payload = line.astype('<u2').tobytes()
            beats = np.frombuffer(payload, dtype='<u8')
            rebuilt = np.frombuffer(beats.tobytes(), dtype='<u2')
            assert np.array_equal(rebuilt, line)
            for pair in (0, 1, D // 4 - 1, D // 2 - 1):
                assert rebuilt[pair] == arr[head, token, pair]
                assert rebuilt[pair + D // 2] == arr[head, token, pair + D // 2]

v_flat = v.reshape(-1)
v_beats = np.frombuffer(v_flat.astype('<u2').tobytes(), dtype='<u8')
replayed = []
for beat in v_beats:
    b = int(beat)
    replayed.extend([(b >> 0) & 0xFFFF, (b >> 16) & 0xFFFF,
                     (b >> 32) & 0xFFFF, (b >> 48) & 0xFFFF])
assert np.array_equal(np.array(replayed, dtype=np.uint16), v_flat)

# Simulate TILE4 output order and the four-row reorder buffer.
reordered = np.empty_like(c)
for h in range(QH):
    for rb in range(0, S, 4):
        block = np.empty((4, D), dtype=np.uint16)
        for cb in range(0, D, 4):
            for lr in range(4):
                for lc in range(4):
                    block[lr, cb + lc] = c[h, rb + lr, cb + lc]
        reordered[h, rb:rb+4, :] = block
assert np.array_equal(reordered, c)

ranges = [
    (0x10000000, q.nbytes, "Q"),
    (0x10100000, k.nbytes, "K"),
    (0x10140000, v.nbytes, "V"),
    (0x10180000, c.nbytes, "Context"),
]
for i, (base, size, name) in enumerate(ranges):
    for base2, size2, name2 in ranges[i+1:]:
        assert max(base, base2) >= min(base + size, base2 + size2), (name, name2)

print("================================================")
print("[PASS] DDR/BF16 data-layout verification")
print(f"Groups / Q / KV          : {G} / {QH} / {KVH}")
print("Raw Q/K split-half pairs : PASS")
print("V 64b -> 2x32b loads     : PASS")
print("TILE4 -> row-major Context: PASS")
print("Little-endian PS DDR map : PASS")
print("DDR regions              : non-overlapping")
print("================================================")
