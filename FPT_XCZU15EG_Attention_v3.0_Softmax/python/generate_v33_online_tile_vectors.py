#!/usr/bin/env python3
"""Generate deterministic Stage 2B FIFO-to-online-tile test vectors."""

from __future__ import annotations

import argparse
import random
from pathlib import Path

from generate_v32_online_row_vectors import (
    EXP_W,
    L_SUM_W,
    SCORE_W,
    float_to_bf16,
    model_update,
    pack_lanes,
    q15_to_bf16,
    q23_to_q15,
    read_lut,
    signed_hex,
)


TILE = 4
Q_HEADS = 4
SEQ_LEN = 128


def build_tile_schedule() -> list[tuple[int, int, int, int, int]]:
    """Return (group_start, group, head, row_base, col_base)."""
    schedule: list[tuple[int, int, int, int, int]] = []

    # Group 0 stresses repeated column tiles and deliberately includes a fully
    # future tile. Real causal tile skip may remove that tile upstream, but the
    # consumer remains correct if a masked placeholder reaches it.
    for head in range(Q_HEADS):
        for row_base in (0, 4, 8, 12):
            for col_base in (0, 4, 8, 12):
                schedule.append(
                    (int(len(schedule) == 0), 0, head, row_base, col_base)
                )

    # Group 1 verifies that state_clear prevents state leakage when local Q-head
    # numbers are reused by the next 4Q/1KV GQA group.
    group_one_start = len(schedule)
    for head in range(Q_HEADS):
        for row_base in (60, 124):
            for col_base in (0, 56, 60, 64, 120, 124):
                if col_base < SEQ_LEN:
                    schedule.append(
                        (
                            int(len(schedule) == group_one_start),
                            1,
                            head,
                            row_base,
                            col_base,
                        )
                    )
    return schedule


def score_pool() -> list[int]:
    values = [
        -16.0,
        -12.0,
        -8.0,
        -7.5,
        -4.0,
        -2.0,
        -1.0,
        -0.5,
        0.0,
        0.125,
        0.5,
        1.0,
        2.0,
        3.0,
        4.0,
        7.5,
        8.0,
        12.0,
        16.0,
    ]
    return [float_to_bf16(value) for value in values]


def generate_cases(lut: list[int]) -> list[tuple[int, ...]]:
    rng = random.Random(0xF1A533)
    pool = score_pool()
    state: dict[tuple[int, int], tuple[int, int, int]] = {}
    cases: list[tuple[int, ...]] = []
    schedule = build_tile_schedule()

    for case_id, (group_start, group, head, row_base, col_base) in enumerate(
        schedule
    ):
        if group_start:
            state.clear()

        scores = [rng.choice(pool) for _ in range(TILE * TILE)]
        expected_state_valid: list[int] = []
        expected_m: list[int] = []
        expected_l: list[int] = []
        expected_alpha: list[int] = []
        expected_alpha_q15: list[int] = []
        expected_alpha_bf16: list[int] = []
        expected_weights: list[int] = []
        expected_weights_q15: list[int] = []
        expected_weights_bf16: list[int] = []
        expected_row_sum: list[int] = []
        expected_all_masked: list[int] = []
        expected_error: list[int] = []
        mask_bits: list[int] = []

        for row_lane in range(TILE):
            absolute_row = row_base + row_lane
            row_scores = scores[row_lane * TILE : (row_lane + 1) * TILE]
            row_mask = 0
            for col_lane in range(TILE):
                absolute_col = col_base + col_lane
                masked = int(absolute_col > absolute_row)
                row_mask |= masked << col_lane
                mask_bits.append(masked)

            old_valid, old_m, old_l = state.get(
                (head, absolute_row), (0, 0, 0)
            )
            result = model_update(
                row_scores, row_mask, old_valid, old_m, old_l, lut
            )
            (
                new_valid,
                new_m,
                new_l,
                alpha,
                weights,
                row_sum,
                all_masked,
                numeric_error,
            ) = result
            state[(head, absolute_row)] = (new_valid, new_m, new_l)

            expected_state_valid.append(new_valid)
            expected_m.append(signed_hex(new_m, SCORE_W))
            expected_l.append(new_l)
            expected_alpha.append(alpha)
            expected_alpha_q15.append(q23_to_q15(alpha))
            expected_alpha_bf16.append(q15_to_bf16(q23_to_q15(alpha)))
            expected_weights.extend(weights)
            expected_weights_q15.extend(q23_to_q15(value) for value in weights)
            expected_weights_bf16.extend(
                q15_to_bf16(q23_to_q15(value)) for value in weights
            )
            expected_row_sum.append(row_sum)
            expected_all_masked.append(all_masked)
            expected_error.append(numeric_error)

        group_last = int(
            case_id == len(schedule) - 1
            or schedule[case_id + 1][1] != group
        )
        cases.append(
            (
                case_id,
                group_start,
                head,
                row_base,
                col_base,
                group_last,
                pack_lanes(scores, 16),
                pack_lanes(mask_bits, 1),
                pack_lanes(expected_state_valid, 1),
                pack_lanes(expected_m, SCORE_W),
                pack_lanes(expected_l, L_SUM_W),
                pack_lanes(expected_alpha, EXP_W),
                pack_lanes(expected_alpha_q15, 16),
                pack_lanes(expected_alpha_bf16, 16),
                pack_lanes(expected_weights, EXP_W),
                pack_lanes(expected_weights_q15, 16),
                pack_lanes(expected_weights_bf16, 16),
                pack_lanes(expected_row_sum, L_SUM_W),
                pack_lanes(expected_all_masked, 1),
                pack_lanes(expected_error, 1),
            )
        )
    return cases


def write_cases(path: Path, cases: list[tuple[int, ...]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="ascii", newline="\n") as output:
        for case in cases:
            (
                case_id,
                group_start,
                head,
                row_base,
                col_base,
                group_last,
                scores,
                mask,
                state_valid,
                m_fixed,
                l_q23,
                alpha_q23,
                alpha_q15,
                alpha_bf16,
                weights_q23,
                weights_q15,
                weights_bf16,
                row_sum,
                all_masked,
                numeric_error,
            ) = case
            output.write(
                f"{case_id:d} {group_start:01x} {head:01x} "
                f"{row_base:02x} {col_base:02x} {group_last:01x} "
                f"{scores:064x} {mask:04x} {state_valid:01x} "
                f"{m_fixed:024x} {l_q23:032x} {alpha_q23:024x} "
                f"{alpha_q15:016x} {alpha_bf16:016x} "
                f"{weights_q23:096x} {weights_q15:064x} "
                f"{weights_bf16:064x} {row_sum:032x} "
                f"{all_masked:01x} {numeric_error:01x}\n"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lut", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    lut = read_lut(args.lut)
    cases = generate_cases(lut)
    write_cases(args.output, cases)
    print(
        f"[PASS] generated {len(cases)} Stage 2B tile vectors: "
        f"{args.output}"
    )


if __name__ == "__main__":
    main()
