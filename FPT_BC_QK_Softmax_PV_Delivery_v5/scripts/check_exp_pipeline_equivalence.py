#!/usr/bin/env python3
"""Audit the v5 EXP pipeline and prove its narrowed address math.

The original RTL used a 32-bit ``integer`` temporary and a redundant clamp.
For the formal Q9.14 configuration, every nonzero accepted magnitude is in
1..8*2^14.  Exhausting that complete interval proves the narrowed expression
selects the same 0..512 LUT address.  Boundary cases prove the zero/forced-zero
decisions outside the interval.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl/softmax/softmax_bf16.sv"

SCORE_FRAC = 14
SHIFT = SCORE_FRAC - 6
LIMIT = 8 << SCORE_FRAC
ROUND_BIAS = 1 << (SHIFT - 1)


def legacy(magnitude: int, masked: bool) -> tuple[int, bool]:
    address = 0
    forced_zero = False
    if masked:
        forced_zero = True
    elif magnitude <= 0:
        address = 0
    elif magnitude > LIMIT:
        forced_zero = True
    else:
        address = (magnitude + ROUND_BIAS) >> SHIFT
        if address > 512:
            address = 512
    return address, forced_zero


def pipelined(magnitude: int, masked: bool) -> tuple[int, bool]:
    if masked:
        return 0, True
    if magnitude <= 0:
        return 0, False
    if magnitude > LIMIT:
        return 0, True
    return (magnitude + ROUND_BIAS) >> SHIFT, False


def main() -> None:
    text = RTL.read_text(encoding="utf-8")
    required = [
        "typedef enum logic [3:0]",
        "ST_EXP_ADDR",
        "ST_EXP_LUT",
        "ST_EXP_ACCUM",
        "exp_score_reg <= score_mem[proc_idx]",
        "exp_addr_reg        <= exp_addr",
        "exp_value_reg <= exp_forced_zero_reg ? 16'd0 : exp_lut_data",
        "sum_exp <= sum_exp + exp_value_reg",
        ".addr(exp_addr_reg)",
        "EXP_LIMIT_FIXED",
        "EXP_ROUND_BIAS",
    ]
    missing = [token for token in required if token not in text]
    if missing:
        raise SystemExit(f"Missing v5 EXP pipeline tokens: {missing}")
    if "integer exp_addr_int" in text:
        raise SystemExit("Legacy 32-bit EXP address temporary is still present")

    checked = 0
    for magnitude in range(1, LIMIT + 1):
        old = legacy(magnitude, False)
        new = pipelined(magnitude, False)
        if old != new:
            raise SystemExit(
                f"EXP address mismatch magnitude={magnitude}: old={old} new={new}"
            )
        checked += 1

    boundaries = [-((1 << 24) - 1), -1, 0, LIMIT + 1, (1 << 24) - 1]
    for masked in (False, True):
        for magnitude in boundaries:
            old = legacy(magnitude, masked)
            new = pipelined(magnitude, masked)
            if old != new:
                raise SystemExit(
                    "EXP boundary mismatch "
                    f"magnitude={magnitude} masked={masked}: old={old} new={new}"
                )
            checked += 1

    assert pipelined(LIMIT, False) == (512, False)
    print("PASS: v5 four-stage EXP pipeline structure")
    print(f"PASS: EXP address equivalence cases={checked} address_range=0..512")


if __name__ == "__main__":
    main()
