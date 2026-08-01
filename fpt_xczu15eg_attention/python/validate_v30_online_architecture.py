#!/usr/bin/env python3
"""Static architectural guard for the v3.0 online-fused data path."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ONLINE_TOP = ROOT / "rtl/core/online/attention_online_system_with_rope_top.sv"
ONLINE_TILE = ROOT / "rtl/core/online/online_softmax_context_tile.sv"
CONTEXT_BANK = ROOT / "rtl/core/online/online_context_bank.sv"
BOARD = ROOT / "rtl/board/fpt_attention_board_engine.sv"


def require(text: str, token: str, source: Path) -> None:
    if token not in text:
        raise SystemExit(f"[FAIL] {source}: missing required token {token!r}")


def forbid(text: str, token: str, source: Path) -> None:
    if token in text:
        raise SystemExit(f"[FAIL] {source}: forbidden legacy token {token!r}")


def main() -> None:
    top = ONLINE_TOP.read_text(encoding="utf-8")
    tile = ONLINE_TILE.read_text(encoding="utf-8")
    bank = CONTEXT_BANK.read_text(encoding="utf-8")
    board = BOARD.read_text(encoding="utf-8")

    for token in (
        "qk_parallel_systolic_gqa_top",
        "bf16_v_cache",
        "online_softmax_context_tile",
    ):
        require(top, token, ONLINE_TOP)
    for token in (
        "running_max",
        "running_sum",
        "online_context_bank",
        "online_context_pe",
        "context_valid",
    ):
        require(tile, token, ONLINE_TILE)
    require(bank, 'ram_style = "distributed"', CONTEXT_BANK)
    require(bank, "write_en", CONTEXT_BANK)
    for token in (
        "score_rowtile_buffer",
        "softmax_output_buffer",
        "pv_tile4_pingpong_buffer",
        "pv_parallel_systolic_gqa_top",
    ):
        forbid(top, token, ONLINE_TOP)
        forbid(tile, token, ONLINE_TILE)

    require(board, "GEN_V30_ONLINE_FUSED", BOARD)
    require(board, "ONLINE_MODE", BOARD)
    require(board, "online_mac_terms", BOARD)

    full_p_bits = 4 * 128 * 128 * 16
    online_context_bits = 4 * 128 * 32
    score_tile_bits = 4 * 4 * 32
    print("[PASS] v3.0 online-fused architecture guard")
    print(f"legacy full-P payload (one GQA group): {full_p_bits} bits")
    print(
        "online persistent payload: "
        f"{online_context_bits} context bits + {score_tile_bits} score-tile bits"
    )
    print("legacy P capture/replay/PV hierarchy: absent from online path")


if __name__ == "__main__":
    main()
