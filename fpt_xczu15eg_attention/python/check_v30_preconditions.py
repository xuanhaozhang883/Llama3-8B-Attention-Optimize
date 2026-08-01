#!/usr/bin/env python3
"""Read-only pre-optimization checks for the v3.0 online-fused baseline."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


COUNTER_MACROS = {
    "V30_QK_TILES_COMPUTED_EXPECTED": "tiles_processed",
    "V30_QK_TILES_SKIPPED_EXPECTED": "tiles_skipped",
    "V30_MASKED_TILES_EMITTED_EXPECTED": "tiles_skipped",
    "V30_ONLINE_TILES_PROCESSED_EXPECTED": "tiles_processed",
    "V30_ONLINE_TILES_SKIPPED_EXPECTED": "tiles_skipped",
    "V30_ONLINE_V_VECTORS_EXPECTED": "v_vectors",
    "V30_ONLINE_MAC_TERMS_EXPECTED": "mac_terms",
    "V30_ONLINE_MAC_SKIPPED_EXPECTED": "mac_skipped",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, required=True)
    return parser.parse_args()


def read(path: Path) -> str:
    if not path.is_file():
        raise SystemExit(f"[FAIL] missing file: {path}")
    return path.read_text(encoding="utf-8", errors="strict")


def expected_counts(q_heads: int, seq: int, dim: int, tile: int = 4) -> dict[str, int]:
    if seq % tile or dim % tile:
        raise SystemExit("[FAIL] SEQ_LEN and HEAD_DIM must be divisible by TILE=4")
    row_tiles = seq // tile
    tiles_per_head = row_tiles * row_tiles
    processed_per_head = row_tiles * (row_tiles + 1) // 2
    skipped_per_head = tiles_per_head - processed_per_head
    valid_scores_per_head = seq * (seq + 1) // 2
    total_mac_terms = q_heads * seq * seq * dim
    mac_terms = q_heads * valid_scores_per_head * dim
    return {
        "tiles_processed": q_heads * processed_per_head,
        "tiles_skipped": q_heads * skipped_per_head,
        # The current RTL performs one TILE4 V-vector request for each
        # reduce lane and feature tile: TILE * (DIM/TILE) == DIM requests.
        "v_vectors": q_heads * processed_per_head * dim,
        "mac_terms": mac_terms,
        "mac_skipped": total_mac_terms - mac_terms,
        "context_words": q_heads * seq * dim,
    }


def main() -> int:
    root = parse_args().project_root.resolve()
    cfg = json.loads(read(root / "project_config.json"))
    groups = int(cfg["run_groups"])
    q_heads = int(cfg["q_heads"])
    kv_heads = int(cfg["kv_heads"])
    seq = int(cfg["seq_len"])
    dim = int(cfg["head_dim"])
    expected = expected_counts(q_heads, seq, dim)
    failures: list[str] = []

    if (groups, q_heads, kv_heads, seq, dim) != (8, 32, 8, 128, 128):
        failures.append(
            "project_config is not the required 8-GQA S128/D128 baseline: "
            f"got groups={groups}, Q={q_heads}, KV={kv_heads}, S={seq}, D={dim}"
        )

    board_top = read(root / "rtl/board/attention_board_top.sv")
    for pattern, label in [
        (r"parameter\s+int\s+RUN_GROUPS\s*=\s*8", "RUN_GROUPS=8"),
        (r"parameter\s+bit\s+ONLINE_MODE\s*=\s*1'b1", "ONLINE_MODE=1"),
    ]:
        if re.search(pattern, board_top) is None:
            failures.append(f"board top does not default to {label}")

    online_top = read(root / "rtl/core/online/attention_online_system_with_rope_top.sv")
    for token in [
        "attention_online_system_with_rope_top",
        "group_counter == RUN_GQA_GROUPS-1",
        "online_tiles_processed <= online_tiles_processed +",
        "online_v_vectors_read <= online_v_vectors_read +",
        "online_mac_terms <= online_mac_terms +",
    ]:
        if token not in online_top:
            failures.append(f"online top missing required token: {token}")
    if "assign completed_group_id = group_counter;" in online_top:
        failures.append(
            "completed_group_id is combinationally tied to group_counter; after "
            "online_done the first seven group_complete pulses report the next group"
        )

    online_tile = read(root / "rtl/core/online/online_softmax_context_tile.sv")
    for token in ["running_max", "running_sum", "alpha_q15", "weight_q15",
                  "online_context_bank", "OP_SCALE", "OP_MAC", "OP_NORM"]:
        if token not in online_tile:
            failures.append(f"online tile missing required token: {token}")

    fixed_generator = root / "python/generate_v30_board_golden_fixed.py"
    generator_path = (
        fixed_generator if fixed_generator.is_file()
        else root / "python/generate_v30_board_golden.py"
    )
    generator = read(generator_path)
    if "x[:, :, 0::2]" in generator or "x[:, :, 1::2]" in generator:
        failures.append(
            f"full-size Golden generator {generator_path.name} uses adjacent "
            "even/odd RoPE pairing; "
            "RTL requires split-half pairing [0:D/2] with [D/2:D]"
        )
    if "rotate_bf16_split_half" not in generator:
        failures.append(
            f"full-size Golden generator {generator_path.name} does not expose "
            "the reviewed split-half RoPE implementation"
        )

    context_name = str(cfg.get("context_golden_file", ""))
    if context_name != "attn_out_online_fused_bf16.hex":
        failures.append(
            "project_config context_golden_file still selects the Legacy/PyTorch "
            f"Golden ({context_name!r}), not the quantized online-fused Golden"
        )
    else:
        context_path = root / "vitis/data" / context_name
        if not context_path.is_file():
            failures.append(f"selected online-fused Golden is missing: {context_path}")
        else:
            context_tokens = context_path.read_text(encoding="ascii").split()
            if len(context_tokens) != expected["context_words"]:
                failures.append(
                    f"selected online-fused Golden must contain "
                    f"{expected['context_words']} words, found {len(context_tokens)}"
                )

    board_c = read(root / "vitis/src/fpt_attention_board_test.c")
    macro_values = {
        name: int(value)
        for name, value in re.findall(
            r"^#define\s+(V30_[A-Z0-9_]+_EXPECTED)\s+(\d+)U\s*$",
            board_c,
            flags=re.MULTILINE,
        )
    }
    for macro, key in COUNTER_MACROS.items():
        got = macro_values.get(macro)
        want = expected[key]
        if got != want:
            failures.append(f"{macro}: expected full-8-GQA value {want}, found {got}")

    print("v3.0 pre-optimization contract")
    print(f"  scope            : {groups} groups / {q_heads} Q / {kv_heads} KV / S{seq} / D{dim}")
    print(f"  context words    : {expected['context_words']}")
    print(f"  tiles processed  : {expected['tiles_processed']}")
    print(f"  tiles skipped    : {expected['tiles_skipped']}")
    print(f"  V vectors        : {expected['v_vectors']}")
    print(f"  valid MAC terms  : {expected['mac_terms']}")
    print(f"  skipped MAC terms: {expected['mac_skipped']}")

    if failures:
        print("\n[FAIL] baseline is not ready for performance RTL changes")
        for index, failure in enumerate(failures, 1):
            print(f"  {index}. {failure}")
        return 1

    print("\n[PASS] baseline preconditions are closed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
