#!/usr/bin/env python3
"""Bit-oriented software audit of the packaged Softmax RTL vectors.

This is not a replacement for Vivado simulation. It mirrors the integer/LUT math
in softmax_bf16.sv and checks all 65,536 packaged probability outputs against the
FP32 golden file using the same absolute-error criterion as the RTL testbench.
"""
from __future__ import annotations
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
SEQ_LEN = 128
Q_HEADS = 4
TOTAL = Q_HEADS * SEQ_LEN * SEQ_LEN
SCORE_W = 24
SCORE_FRAC = 14
MAX_FIXED = (1 << (SCORE_W - 1)) - 1
MIN_FIXED = -(1 << (SCORE_W - 1))
TOL = 0.0021


def read_hex(path: Path) -> list[int]:
    return [int(x, 16) for x in path.read_text().split()]


def fp32_bits_to_float(bits: int) -> float:
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]


def bf16_bits_to_float(bits: int) -> float:
    return fp32_bits_to_float((bits & 0xFFFF) << 16)


def bf16_to_fixed(bits: int) -> int:
    sign = (bits >> 15) & 1
    exponent = (bits >> 7) & 0xFF
    fraction = bits & 0x7F
    significand = 0x80 | fraction
    if exponent == 0:
        value = 0
    elif exponent == 0xFF:
        if fraction != 0:
            value = 0
        else:
            value = MIN_FIXED if sign else MAX_FIXED
        return value
    else:
        shift = exponent + SCORE_FRAC - 134
        if shift >= SCORE_W - 8:
            magnitude = MAX_FIXED + 1
        elif shift >= 0:
            magnitude = significand << shift
        else:
            right = -shift
            magnitude = 0 if right >= 63 else (significand + (1 << (right - 1))) >> right
        value = -magnitude if sign else magnitude
    return max(MIN_FIXED, min(MAX_FIXED, value))


def q15_to_bf16(q: int) -> int:
    q &= 0xFFFF
    if q == 0:
        return 0
    msb = q.bit_length() - 1
    exponent = msb + 112
    normalized = q << (15 - msb)
    fraction7 = (normalized >> 8) & 0x7F
    round_bit = (normalized >> 7) & 1
    sticky = 1 if (normalized & 0x7F) else 0
    rounded = fraction7
    if round_bit and (sticky or (fraction7 & 1)):
        rounded += 1
    if rounded & 0x80:
        exponent += 1
        fraction = 0
    else:
        fraction = rounded & 0x7F
    return ((exponent & 0xFF) << 7) | fraction


def unpack_tile_stream(words: list[int]) -> list[list[list[int]]]:
    scores = [[[0 for _ in range(SEQ_LEN)] for _ in range(SEQ_LEN)] for _ in range(Q_HEADS)]
    seen = set()
    for i, word in enumerate(words):
        score = word & 0xFFFF
        col = (word >> 16) & 0x7F
        row = (word >> 23) & 0x7F
        head = (word >> 30) & 0x3
        glast = (word >> 32) & 1
        key = (head, row, col)
        if key in seen:
            raise AssertionError(f'duplicate coordinate at input {i}: {key}')
        seen.add(key)
        scores[head][row][col] = score
        expected_last = int(key == (Q_HEADS - 1, SEQ_LEN - 1, SEQ_LEN - 1))
        if glast != expected_last:
            raise AssertionError(f'global-last mismatch at input {i}: {key}')
    if len(seen) != TOTAL:
        raise AssertionError(f'missing coordinates: got {len(seen)} of {TOTAL}')
    return scores


def emulate_row(row_bits: list[int], row_index: int, exp_lut: list[int]) -> list[int]:
    fixed = [bf16_to_fixed(x) for x in row_bits]
    mask = [c > row_index for c in range(SEQ_LEN)]
    unmasked = [fixed[c] for c in range(SEQ_LEN) if not mask[c]]
    max_score = max(unmasked) if unmasked else 0
    exps: list[int] = []
    for c in range(SEQ_LEN):
        if mask[c]:
            exps.append(0)
            continue
        magnitude = max_score - fixed[c]
        if magnitude <= 0:
            address = 0
        elif magnitude > (8 << SCORE_FRAC):
            exps.append(0)
            continue
        else:
            address = (magnitude + (1 << (SCORE_FRAC - 7))) >> (SCORE_FRAC - 6)
            address = min(512, address)
        exps.append(exp_lut[address])
    total = sum(exps)
    reciprocal_q30 = 0 if total == 0 else (1 << 45) // total
    out = []
    for exp_value in exps:
        probability_q15 = ((exp_value * reciprocal_q30) + (1 << 29)) >> 30
        probability_q15 = min(32768, probability_q15)
        out.append(q15_to_bf16(probability_q15))
    return out


def main() -> None:
    data = ROOT / 'data' / 'full_frontend'
    words = read_hex(data / 'qk_scores_tile_order.mem')
    expected_fp32 = read_hex(data / 'full_expected_probs_fp32.mem')
    expected_bf16 = read_hex(data / 'full_expected_probs_bf16.mem')
    exp_lut = read_hex(ROOT / 'rtl' / 'softmax' / 'exp_lut_q15.mem')
    assert len(words) == len(expected_fp32) == len(expected_bf16) == TOTAL
    assert len(exp_lut) >= 513

    scores = unpack_tile_stream(words)
    actual_bits: list[int] = []
    for h in range(Q_HEADS):
        for r in range(SEQ_LEN):
            actual_bits.extend(emulate_row(scores[h][r], r, exp_lut))

    max_error = 0.0
    sum_error = 0.0
    failures = 0
    exact_mismatches = 0
    row_sums = []
    for i, bits in enumerate(actual_bits):
        actual = bf16_bits_to_float(bits)
        expected = fp32_bits_to_float(expected_fp32[i])
        error = abs(actual - expected)
        max_error = max(max_error, error)
        sum_error += error
        failures += int(error > TOL)
        exact_mismatches += int(bits != expected_bf16[i])
    for base in range(0, TOTAL, SEQ_LEN):
        row_sums.append(sum(bf16_bits_to_float(x) for x in actual_bits[base:base + SEQ_LEN]))

    print('SOFTMAX_RTL_REFERENCE_AUDIT')
    print(f'outputs={TOTAL}')
    print(f'tolerance_failures={failures}')
    print(f'exact_bf16_mismatches={exact_mismatches}')
    print(f'max_abs_error={max_error:.10f}')
    print(f'mean_abs_error={sum_error / TOTAL:.10f}')
    print(f'row_sum_min={min(row_sums):.10f}')
    print(f'row_sum_max={max(row_sums):.10f}')
    if failures:
        raise SystemExit('FAIL: packaged RTL reference exceeds tolerance')
    print('PASS')


if __name__ == '__main__':
    main()
