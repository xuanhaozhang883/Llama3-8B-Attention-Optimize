#!/usr/bin/env python3
"""Exhaustively prove the v4 narrow BF16 converter matches the legacy math.

The timing fix replaces a synthesizable but expensive 64-bit variable-shift and
saturation implementation with an eight-bit-exponent/24-bit-magnitude form.
All 65,536 BF16 encodings are checked, including zeros, subnormals, infinities
and NaNs.
"""

SCORE_W = 24
SCORE_FRAC = 14
MAX_FIXED = (1 << (SCORE_W - 1)) - 1
MIN_FIXED = -(1 << (SCORE_W - 1))
SHIFT_BIAS = 134 - SCORE_FRAC
SAT_EXP = SHIFT_BIAS + SCORE_W - 8
ZERO_EXP = SHIFT_BIAS - 9


def legacy_converter(bits: int) -> int:
    sign = (bits >> 15) & 1
    exponent = (bits >> 7) & 0xFF
    fraction = bits & 0x7F
    significand = 0x80 | fraction

    if exponent == 0:
        value = 0
    elif exponent == 0xFF:
        if fraction:
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
            magnitude = (0 if right >= 63 else
                         (significand + (1 << (right - 1))) >> right)
        value = -magnitude if sign else magnitude

    return max(MIN_FIXED, min(MAX_FIXED, value))


def optimized_converter(bits: int) -> int:
    sign = (bits >> 15) & 1
    exponent = (bits >> 7) & 0xFF
    fraction = bits & 0x7F
    significand = 0x80 | fraction

    if exponent == 0:
        return 0
    if exponent == 0xFF:
        if fraction:
            return 0
        return MIN_FIXED if sign else MAX_FIXED
    if exponent >= SAT_EXP:
        return MIN_FIXED if sign else MAX_FIXED
    if exponent <= ZERO_EXP:
        return 0

    if exponent >= SHIFT_BIAS:
        magnitude = significand << (exponent - SHIFT_BIAS)
    else:
        right = SHIFT_BIAS - exponent
        magnitude = (significand + (1 << (right - 1))) >> right
    return -magnitude if sign else magnitude


def main() -> None:
    mismatches: list[tuple[int, int, int]] = []
    for bits in range(1 << 16):
        old = legacy_converter(bits)
        new = optimized_converter(bits)
        if old != new:
            mismatches.append((bits, old, new))
            if len(mismatches) >= 16:
                break

    if mismatches:
        details = "\n".join(
            f"BF16=0x{bits:04x} legacy={old} optimized={new}"
            for bits, old, new in mismatches
        )
        raise SystemExit("FAIL: BF16 converter mismatch\n" + details)

    print("PASS: optimized BF16-to-Q9.14 converter matches legacy RTL")
    print("encodings_checked=65536")
    print(f"shift_bias={SHIFT_BIAS} zero_exp={ZERO_EXP} sat_exp={SAT_EXP}")


if __name__ == "__main__":
    main()
