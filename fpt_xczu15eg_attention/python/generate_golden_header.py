#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


def read_hex(path: Path, expected: int) -> list[int]:
    words = [int(line.strip(), 16) for line in path.read_text().splitlines() if line.strip()]
    if len(words) != expected:
        raise ValueError(f"{path}: expected {expected} words, got {len(words)}")
    if any(not 0 <= w <= 0xFFFF for w in words):
        raise ValueError(f"{path}: non-BF16 word")
    return words


def main() -> int:
    parser = argparse.ArgumentParser()
    root = Path(__file__).resolve().parents[1]
    cfg = json.loads((root / "project_config.json").read_text(encoding="utf-8"))
    parser.add_argument("--data-dir", type=Path, default=root / "vitis" / "data")
    parser.add_argument("--output", type=Path, default=root / "vitis" / "src" / "fpt_golden_vectors.h")
    args = parser.parse_args()

    groups = int(cfg["run_groups"])
    seq_len = int(cfg["seq_len"])
    head_dim = int(cfg["head_dim"])
    q_heads = int(cfg["q_heads"])
    kv_heads = int(cfg["kv_heads"])
    context_golden = str(cfg.get(
        "context_golden_file", "attn_out_per_head_bf16.hex"
    ))
    files = [
        ("q_before_rope_bf16.hex", "fpt_q_bf16", q_heads * seq_len * head_dim),
        ("k_before_rope_bf16.hex", "fpt_k_bf16", kv_heads * seq_len * head_dim),
        ("v_bf16.hex", "fpt_v_bf16", kv_heads * seq_len * head_dim),
        (context_golden, "fpt_context_expected_bf16", q_heads * seq_len * head_dim),
    ]

    arrays = [(symbol, read_hex(args.data_dir / filename, count))
              for filename, symbol, count in files]

    out = [
        "#ifndef FPT_GOLDEN_VECTORS_H",
        "#define FPT_GOLDEN_VECTORS_H",
        "#include <stdint.h>",
        "",
        f"#define FPT_RUN_GROUPS {groups}u",
        f"#define FPT_Q_HEADS {q_heads}u",
        f"#define FPT_KV_HEADS {kv_heads}u",
        f"#define FPT_SEQ_LEN {seq_len}u",
        f"#define FPT_HEAD_DIM {head_dim}u",
        "",
    ]
    for symbol, words in arrays:
        out.append(f"#define {symbol.upper()}_WORDS {len(words)}u")
        out.append(f"static const uint16_t {symbol}[{len(words)}] __attribute__((aligned(64))) = {{")
        for i in range(0, len(words), 12):
            chunk = ", ".join(f"0x{w:04X}u" for w in words[i:i+12])
            out.append(f"    {chunk},")
        out.append("};")
        out.append("")
    out.append("#endif")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(out) + "\n", encoding="ascii")
    print(f"[PASS] wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
