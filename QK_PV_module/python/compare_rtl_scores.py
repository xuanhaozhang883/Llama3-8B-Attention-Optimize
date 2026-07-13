#!/usr/bin/env python3
from pathlib import Path
import struct
import sys

TOTAL = 4 * 128 * 128

def read_hex(path: Path) -> list[int]:
    values: list[int] = []
    with path.open("r", encoding="ascii") as f:
        for line_no, line in enumerate(f, 1):
            text = line.strip()
            if not text:
                continue
            try:
                values.append(int(text, 16))
            except ValueError as exc:
                raise ValueError(f"{path}: 第{line_no}行不是合法hex: {text!r}") from exc
    return values

def bf16_to_float(v: int) -> float:
    raw = (v & 0xFFFF) << 16
    return struct.unpack(">f", struct.pack(">I", raw))[0]

def decode_index(index: int) -> tuple[int, int, int]:
    head = index // (128 * 128)
    remain = index % (128 * 128)
    row = remain // 128
    col = remain % 128
    return head, row, col

def main() -> int:
    base = Path(r"D:/qk_sim_data")
    rtl_path = base / "rtl_scores_seq128.hex"
    gold_path = base / "scores_before_mask.hex"

    if len(sys.argv) >= 2:
        rtl_path = Path(sys.argv[1])
    if len(sys.argv) >= 3:
        gold_path = Path(sys.argv[2])

    if not rtl_path.exists():
        print(f"[ERROR] 找不到RTL结果文件: {rtl_path}")
        return 2
    if not gold_path.exists():
        print(f"[ERROR] 找不到黄金文件: {gold_path}")
        return 2

    rtl = read_hex(rtl_path)
    gold = read_hex(gold_path)

    print("========================================")
    print("QK BF16全量比较")
    print(f"RTL文件 : {rtl_path}")
    print(f"Gold文件: {gold_path}")
    print(f"期望数量: {TOTAL}")
    print(f"RTL数量 : {len(rtl)}")
    print(f"Gold数量: {len(gold)}")

    if len(rtl) != TOTAL or len(gold) != TOTAL:
        print("[FAIL] 文件行数不正确")
        print("========================================")
        return 1

    mismatch_indices = [i for i, (a, b) in enumerate(zip(rtl, gold)) if a != b]

    print(f"完全匹配: {TOTAL - len(mismatch_indices)}")
    print(f"不匹配  : {len(mismatch_indices)}")

    if mismatch_indices:
        print("前20个不匹配：")
        for idx in mismatch_indices[:20]:
            h, r, c = decode_index(idx)
            rv = rtl[idx]
            gv = gold[idx]
            print(
                f"  index={idx} h={h} row={r} col={c} "
                f"gold={gv:04x} ({bf16_to_float(gv):.9g}) "
                f"rtl={rv:04x} ({bf16_to_float(rv):.9g})"
            )
        print("[FAIL] RTL与黄金结果不完全一致")
        print("========================================")
        return 1

    print("[PASS] 65536 / 65536 完全一致")
    print("========================================")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
