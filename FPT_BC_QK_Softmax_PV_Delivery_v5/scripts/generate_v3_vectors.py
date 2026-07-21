#!/usr/bin/env python3
"""Regenerate v3 vectors from the original project data.

Example:
  python scripts/generate_v3_vectors.py \
    --softmax-data-dir ../Llama3-8B-Attention-Optimize/softmax_module/data \
    --q-npy ../Llama3-8B-Attention-Optimize/QK_PV_module/sim_data/q_after_rope.npy \
    --k-npy ../Llama3-8B-Attention-Optimize/QK_PV_module/sim_data/k_after_rope.npy
"""
from __future__ import annotations
import argparse
from pathlib import Path
import struct
import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def fp32_to_bf16_bits(x: np.ndarray) -> np.ndarray:
    a = np.asarray(x, dtype=np.float32)
    u = a.view(np.uint32)
    bias = np.uint32(0x7FFF) + ((u >> 16) & 1)
    return ((u + bias) >> 16).astype(np.uint16)


def bf16_bits_to_fp32(bits: int) -> np.float32:
    return np.array([np.uint32(bits) << np.uint32(16)], dtype=np.uint32).view(np.float32)[0]


def fp32_scalar_to_bf16(value: np.float32) -> int:
    return int(fp32_to_bf16_bits(np.asarray([value], dtype=np.float32))[0])


def generate_full_frontend(source_dir: Path) -> None:
    required = [
        'input_scores_bf16.mem', 'input_masks.mem',
        'expected_probs_bf16.mem', 'expected_probs_fp32.mem'
    ]
    for name in required:
        if not (source_dir / name).is_file():
            raise FileNotFoundError(source_dir / name)

    out = ROOT / 'data' / 'full_frontend'
    out.mkdir(parents=True, exist_ok=True)
    scores = [int(x, 16) for x in (source_dir / 'input_scores_bf16.mem').read_text().split()]
    masks = [int(x, 16) for x in (source_dir / 'input_masks.mem').read_text().split()]
    heads, seq, tile = 4, 128, 4
    arr = np.asarray(scores, dtype=np.uint16).reshape(heads, seq, seq)
    mask_arr = np.asarray(masks, dtype=np.uint8).reshape(heads, seq, seq)
    causal = np.fromfunction(lambda h, r, c: c > r, (heads, seq, seq), dtype=int).astype(np.uint8)
    if not np.array_equal(mask_arr, causal):
        raise RuntimeError('input_masks.mem is not the expected causal mask')

    with (out / 'qk_scores_tile_order.mem').open('w') as f:
        for h in range(heads):
            for rb in range(0, seq, tile):
                for cb in range(0, seq, tile):
                    for lr in range(tile):
                        for lc in range(tile):
                            r, c = rb + lr, cb + lc
                            last = int(h == heads - 1 and r == seq - 1 and c == seq - 1)
                            packed = (last << 32) | (h << 30) | (r << 23) | (c << 16) | int(arr[h, r, c])
                            f.write(f'{packed:09X}\n')

    for source_name, output_name in [
        ('expected_probs_bf16.mem', 'full_expected_probs_bf16.mem'),
        ('expected_probs_fp32.mem', 'full_expected_probs_fp32.mem'),
    ]:
        (out / output_name).write_text((source_dir / source_name).read_text())
    (out / 'input_masks_reference.mem').write_text((source_dir / 'input_masks.mem').read_text())


def f32_add(a: np.float32, b: np.float32) -> np.float32:
    return np.float32(np.float32(a) + np.float32(b))


def f32_mul(a: np.float32, b: np.float32) -> np.float32:
    return np.float32(np.float32(a) * np.float32(b))


def generate_small_real_qk(q_npy: Path, k_npy: Path) -> None:
    out = ROOT / 'data' / 'real_qk_small'
    out.mkdir(parents=True, exist_ok=True)
    q = np.load(q_npy).astype(np.float32)[:2, :8, :8]
    k_all = np.load(k_npy).astype(np.float32)
    k = k_all[0, :8, :8] if k_all.ndim == 3 else k_all[:8, :8]
    qb = fp32_to_bf16_bits(q)
    kb = fp32_to_bf16_bits(k)

    with (out / 'q_small_bf16.mem').open('w') as f:
        for h in range(2):
            for r in range(8):
                for d in range(8):
                    f.write(f'{int(qb[h, r, d]):04X}\n')
    with (out / 'k_small_bf16.mem').open('w') as f:
        for c in range(8):
            for d in range(8):
                f.write(f'{int(kb[c, d]):04X}\n')

    scale = np.float32(1.0 / np.sqrt(np.float32(8.0)))
    scale_bits = struct.unpack('>I', struct.pack('>f', float(scale)))[0]
    scores = np.zeros((2, 8, 8), dtype=np.uint16)
    for h in range(2):
        for r in range(8):
            for c in range(8):
                acc = np.float32(0.0)
                for d in range(8):
                    av = bf16_bits_to_fp32(int(qb[h, r, d]))
                    bv = bf16_bits_to_fp32(int(kb[c, d]))
                    acc = f32_add(acc, f32_mul(av, bv))
                scores[h, r, c] = fp32_scalar_to_bf16(f32_mul(acc, scale))

    with (out / 'expected_adapter_row_order.mem').open('w') as f:
        for h in range(2):
            for r in range(8):
                for c in range(8):
                    mask = int(c > r)
                    data = 0xFF80 if mask else int(scores[h, r, c])
                    first, last = int(c == 0), int(c == 7)
                    packed = (last << 25) | (first << 24) | (c << 21) | (r << 18) | (h << 17) | (mask << 16) | data
                    f.write(f'{packed:07X}\n')

    # Standard FP32 Softmax golden probabilities for the small end-to-end test.
    probabilities: list[np.float32] = []
    for h in range(2):
        for r in range(8):
            valid_scores = np.asarray(
                [bf16_bits_to_fp32(int(scores[h, r, c])) for c in range(r + 1)],
                dtype=np.float32
            )
            shifted = valid_scores - np.max(valid_scores)
            exp_values = np.exp(shifted, dtype=np.float32)
            valid_probs = exp_values / np.sum(exp_values, dtype=np.float32)
            for c in range(8):
                probabilities.append(np.float32(valid_probs[c]) if c <= r else np.float32(0.0))
    with (out / 'small_expected_probs_fp32.mem').open('w') as f:
        for value in probabilities:
            bits = struct.unpack('>I', struct.pack('>f', float(value)))[0]
            f.write(f'{bits:08X}\n')
    with (out / 'small_expected_probs_bf16.mem').open('w') as f:
        for value in probabilities:
            f.write(f'{fp32_scalar_to_bf16(value):04X}\n')

    (out / 'scale_fp32.hex').write_text(f'{scale_bits:08X}\n')
    (out / 'README.txt').write_text(
        'Configuration: TILE=4, SEQ_LEN=8, HEAD_DIM=8, Q_HEADS=2\n'
        f'SCALE_FP32=0x{scale_bits:08X} (1/sqrt(8))\n'
        'Expected 26-bit adapter words pack '
        '{row_last,row_first,col[2:0],row[2:0],head,mask,data[15:0]}.\n'
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--softmax-data-dir', type=Path, required=True)
    parser.add_argument('--q-npy', type=Path, required=True)
    parser.add_argument('--k-npy', type=Path, required=True)
    args = parser.parse_args()
    generate_full_frontend(args.softmax_data_dir.resolve())
    generate_small_real_qk(args.q_npy.resolve(), args.k_npy.resolve())
    print('Generated v3 vectors under', ROOT / 'data')


if __name__ == '__main__':
    main()
