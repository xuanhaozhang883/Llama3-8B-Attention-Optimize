#!/usr/bin/env python3
"""Compare the full RTL PV dump with the BF16 golden output."""

from __future__ import annotations

import argparse
from pathlib import Path


TOTAL = 4 * 128 * 128


def read_hex(path: Path) -> list[int]:
    values: list[int] = []
    with path.open("r", encoding="ascii") as f:
        for line_number, line in enumerate(f, 1):
            text = line.strip()
            if not text:
                continue
            try:
                values.append(int(text, 16))
            except ValueError as exc:
                raise ValueError(
                    f"{path}: invalid HEX at line {line_number}: {text!r}"
                ) from exc
    return values


def decode(index: int) -> tuple[int, int, int]:
    head = index // (128 * 128)
    rem = index % (128 * 128)
    row = rem // 128
    col = rem % 128
    return head, row, col


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--rtl",
        type=Path,
        default=Path("D:/pv_sim_data/rtl_pv_context_bf16.hex"),
    )
    parser.add_argument(
        "--gold",
        type=Path,
        default=Path(
            "D:/pv_sim_data/attn_out_per_head_bf16.hex"
        ),
    )
    args = parser.parse_args()

    rtl = read_hex(args.rtl)
    gold = read_hex(args.gold)

    print("========================================")
    print("Full PV RTL comparison")
    print(f"Expected count: {TOTAL}")
    print(f"RTL count     : {len(rtl)}")
    print(f"Gold count    : {len(gold)}")

    if len(rtl) != TOTAL or len(gold) != TOTAL:
        print("[FAIL] Incorrect file length")
        return 1

    mismatches = [
        index
        for index, (rtl_value, gold_value) in enumerate(zip(rtl, gold))
        if rtl_value != gold_value
    ]

    print(f"Matches       : {TOTAL - len(mismatches)}")
    print(f"Mismatches    : {len(mismatches)}")

    if mismatches:
        print("First mismatches:")
        for index in mismatches[:20]:
            head, row, col = decode(index)
            print(
                f"  h={head} row={row} col={col} "
                f"gold={gold[index]:04x} rtl={rtl[index]:04x}"
            )
        print("[FAIL] RTL output differs from golden output")
        print("========================================")
        return 1

    print("[PASS] 65536 / 65536 exact BF16 match")
    print("========================================")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
