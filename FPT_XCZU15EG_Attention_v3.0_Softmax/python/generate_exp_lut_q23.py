#!/usr/bin/env python3
"""Generate the 513-entry exp(-address/64) unsigned Q1.23 ROM."""

from __future__ import annotations

import argparse
import math
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="ascii", newline="\n") as output:
        for address in range(513):
            value = round(math.exp(-address / 64.0) * (1 << 23))
            output.write(f"{value:06x}\n")
    print(f"[PASS] generated Q1.23 exp LUT: {args.output}")


if __name__ == "__main__":
    main()

