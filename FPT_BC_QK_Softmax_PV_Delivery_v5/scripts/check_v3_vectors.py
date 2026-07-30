#!/usr/bin/env python3
"""Check packaged vector counts, coordinates, and small real-QK consistency."""
from pathlib import Path
import struct
import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def read_hex(path: Path) -> list[int]:
    return [int(x, 16) for x in path.read_text().split()]


def bf16_to_np32(bits: int) -> np.float32:
    return np.array([np.uint32(bits) << np.uint32(16)], dtype=np.uint32).view(np.float32)[0]


def np32_to_bf16(value: np.float32) -> int:
    u = np.asarray([value], dtype=np.float32).view(np.uint32)[0]
    return int((u + np.uint32(0x7FFF) + ((u >> np.uint32(16)) & np.uint32(1))) >> np.uint32(16))


def check_small_real_qk(small: Path) -> None:
    q_words = read_hex(small / 'q_small_bf16.mem')
    k_words = read_hex(small / 'k_small_bf16.mem')
    expected = read_hex(small / 'expected_adapter_row_order.mem')
    assert len(q_words) == 128
    assert len(k_words) == 64
    assert len(expected) == 128
    scale_bits = read_hex(small / 'scale_fp32.hex')[0]
    scale = np.asarray([scale_bits], dtype=np.uint32).view(np.float32)[0]

    for h in range(2):
        for r in range(8):
            for c in range(8):
                acc = np.float32(0.0)
                for d in range(8):
                    a = bf16_to_np32(q_words[h * 64 + r * 8 + d])
                    b = bf16_to_np32(k_words[c * 8 + d])
                    acc = np.float32(acc + np.float32(a * b))
                score = np32_to_bf16(np.float32(acc * scale))
                index = h * 64 + r * 8 + c
                word = expected[index]
                mask = int(c > r)
                expected_data = 0xFF80 if mask else score
                assert (word & 0xFFFF) == expected_data
                assert ((word >> 16) & 1) == mask
                assert ((word >> 17) & 1) == h
                assert ((word >> 18) & 0x7) == r
                assert ((word >> 21) & 0x7) == c
                assert ((word >> 24) & 1) == int(c == 0)
                assert ((word >> 25) & 1) == int(c == 7)

    assert len(read_hex(small / 'small_expected_probs_bf16.mem')) == 128
    assert len(read_hex(small / 'small_expected_probs_fp32.mem')) == 128


def check() -> None:
    full = ROOT / 'data' / 'full_frontend'
    inp = read_hex(full / 'qk_scores_tile_order.mem')
    expected_bf16 = read_hex(full / 'full_expected_probs_bf16.mem')
    expected_fp32 = read_hex(full / 'full_expected_probs_fp32.mem')
    assert len(inp) == len(expected_bf16) == len(expected_fp32) == 65536
    assert sum((x >> 32) & 1 for x in inp) == 1
    seen = set()
    for word in inp:
        h = (word >> 30) & 3
        r = (word >> 23) & 0x7F
        c = (word >> 16) & 0x7F
        assert (h, r, c) not in seen
        seen.add((h, r, c))
        assert ((word >> 32) & 1) == int((h, r, c) == (3, 127, 127))
    assert len(seen) == 65536

    masks = read_hex(full / 'input_masks_reference.mem')
    assert len(masks) == 65536
    assert sum(masks) == 32512
    for i, mask in enumerate(masks):
        r = (i // 128) % 128
        c = i % 128
        assert mask == int(c > r)

    small = ROOT / 'data' / 'real_qk_small'
    check_small_real_qk(small)
    print('PASS: vector counts, coordinates, masks, and small real-QK arithmetic')
    print('full_items=65536 causal_masks=32512 small_q=128 small_k=64')


if __name__ == '__main__':
    check()
