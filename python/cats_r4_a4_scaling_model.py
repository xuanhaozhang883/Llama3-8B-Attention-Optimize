#!/usr/bin/env python3
"""Deterministic CATS-R4 A4 assignment, work, resource, and queue model.

This is an architecture model, not RTL, post-route, or board evidence.  It is
intentionally explicit about the current 32-row per-cluster output queue and
the canonical global output order because those constraints can serialize
otherwise parallel compute clusters.
"""

from __future__ import annotations

import argparse
import json
from collections import deque
from dataclasses import asdict, dataclass


SEQ_LEN = 128
HEAD_DIM = 128
Q_HEADS = 32
KV_GROUPS = 8
Q_HEADS_PER_GROUP = 4
ROWS_PER_GROUP = Q_HEADS_PER_GROUP * SEQ_LEN
WINDOW_ROWS = 16
WINDOWS_PER_HEAD = SEQ_LEN // WINDOW_ROWS
QK_LANES = 32
PV_LANES = 32

A3_LUT = 61_967
A3_FF = 115_025
A3_DSP = 387
TEAM_FULL_BOARD_LUT_TARGET = 230_000
TEAM_FULL_BOARD_FF_TARGET = 380_000

# From the C1 architecture model.  V3 adds three FP32 weight rows and token
# metadata while retaining the existing three BF16 score rows.
C1_BYTES_PER_CLUSTER = 152_960
SCORE_SLOTS = 3
WEIGHT_SLOTS = 3
SLOT_KEYS = 128
SCORE_BYTES = 2
WEIGHT_BYTES = 4
V3_TOKEN_METADATA_BYTES = 3 * (32 + 32) // 8


@dataclass(frozen=True)
class ScheduleJob:
    cluster_id: int
    local_group_index: int
    group: int
    local_head: int
    global_q_head: int
    window: int
    row_start: int
    row_end: int


@dataclass(frozen=True)
class RowAssignment:
    cluster_id: int
    group: int
    global_q_head: int
    row: int
    seq: int


@dataclass(frozen=True)
class OutputSimulation:
    evidence_level: str
    clusters: int
    canonical: bool
    queue_rows: int
    compute_cycles_per_row: int
    output_cycles_per_row: int
    cycles: int
    rows_committed: int
    max_queue_depth: int
    total_queue_stall_cycles: int
    queue_stall_cycles: tuple[int, ...]
    last_local_accept_cycle: tuple[int, ...]


def _validate_clusters(clusters: int) -> None:
    if clusters not in (1, 2, 4):
        raise ValueError("clusters must be 1, 2, or 4")


def group_ownership(clusters: int) -> dict[int, list[int]]:
    _validate_clusters(clusters)
    return {
        cluster: list(range(cluster, KV_GROUPS, clusters))
        for cluster in range(clusters)
    }


def enumerate_jobs(clusters: int) -> list[ScheduleJob]:
    ownership = group_ownership(clusters)
    jobs: list[ScheduleJob] = []
    for cluster, groups in ownership.items():
        for local_group_index, group in enumerate(groups):
            for local_head in range(Q_HEADS_PER_GROUP):
                global_q_head = Q_HEADS_PER_GROUP * group + local_head
                for window in range(WINDOWS_PER_HEAD):
                    row_start = window * WINDOW_ROWS
                    jobs.append(
                        ScheduleJob(
                            cluster_id=cluster,
                            local_group_index=local_group_index,
                            group=group,
                            local_head=local_head,
                            global_q_head=global_q_head,
                            window=window,
                            row_start=row_start,
                            row_end=row_start + WINDOW_ROWS - 1,
                        )
                    )
    return jobs


def enumerate_rows(clusters: int) -> list[RowAssignment]:
    rows: list[RowAssignment] = []
    for job in enumerate_jobs(clusters):
        for row in range(job.row_start, job.row_end + 1):
            rows.append(
                RowAssignment(
                    cluster_id=job.cluster_id,
                    group=job.group,
                    global_q_head=job.global_q_head,
                    row=row,
                    seq=job.global_q_head * SEQ_LEN + row,
                )
            )
    return rows


def _aggregate_workload() -> dict[str, int]:
    rows = Q_HEADS * SEQ_LEN
    causal = Q_HEADS * sum(range(1, SEQ_LEN + 1))
    return {
        "groups": KV_GROUPS,
        "q_heads": Q_HEADS,
        "rows": rows,
        "final_releases": rows,
        "causal_scores": causal,
        "valid_exp": causal,
        "weight_writes": rows * SEQ_LEN,
        "qk_valid_macs": causal * HEAD_DIM,
        "pv_valid_macs": causal * HEAD_DIM,
        "context_words": rows * HEAD_DIM,
        "q_slabs": Q_HEADS * WINDOWS_PER_HEAD,
        "engine_jobs": 6_144,
    }


def workload_report(clusters: int) -> dict[str, object]:
    ownership = group_ownership(clusters)
    aggregate = _aggregate_workload()
    per_cluster: list[dict[str, int]] = []
    for cluster in range(clusters):
        groups = len(ownership[cluster])
        fraction_denominator = KV_GROUPS // groups
        per_cluster.append(
            {
                key: value // fraction_denominator
                for key, value in aggregate.items()
            }
        )
    return {
        "clusters": clusters,
        "ownership": ownership,
        "per_cluster": per_cluster,
        "aggregate": aggregate,
    }


def v3_capacity_per_cluster() -> dict[str, int]:
    score_bytes = SCORE_SLOTS * SLOT_KEYS * SCORE_BYTES
    weight_bytes = WEIGHT_SLOTS * SLOT_KEYS * WEIGHT_BYTES
    delta = weight_bytes + V3_TOKEN_METADATA_BYTES
    return {
        "c1_bytes": C1_BYTES_PER_CLUSTER,
        "score_slots_bytes": score_bytes,
        "weight_slots_bytes": weight_bytes,
        "token_metadata_bytes": V3_TOKEN_METADATA_BYTES,
        "v3_delta_bytes": delta,
        "total_bytes": C1_BYTES_PER_CLUSTER + delta,
    }


def resource_estimate(clusters: int) -> dict[str, object]:
    _validate_clusters(clusters)
    compute_lut = A3_LUT * clusters
    compute_ff = A3_FF * clusters
    compute_dsp = A3_DSP * clusters
    return {
        "evidence_level": "linear_risk_estimate",
        "warning": "not measured implementation utilization",
        "clusters": clusters,
        "compute_lut": compute_lut,
        "compute_ff": compute_ff,
        "compute_dsp": compute_dsp,
        "team_full_board_lut_target": TEAM_FULL_BOARD_LUT_TARGET,
        "team_full_board_ff_target": TEAM_FULL_BOARD_FF_TARGET,
        "exceeds_team_lut_target": compute_lut > TEAM_FULL_BOARD_LUT_TARGET,
        "exceeds_team_ff_target": compute_ff > TEAM_FULL_BOARD_FF_TARGET,
    }


def service_requirements(clusters: int) -> dict[str, int]:
    """Return frozen per-cluster compute ports and invariant DDR traffic."""

    _validate_clusters(clusters)
    return {
        "q_rsp_bits_per_cluster": 16,
        "k_rsp_bits_per_cluster": QK_LANES * 16,
        "v_rsp_bits_per_cluster": PV_LANES * 16,
        "context_bits_per_cluster": PV_LANES * 16,
        "weight_write_bits_per_cluster": 32,
        "weight_read_bits_per_cluster": 32,
        "k_peak_bytes_per_core_cycle": QK_LANES * 2,
        "v_peak_bytes_per_core_cycle": PV_LANES * 2,
        "local_kv_peak_bytes_per_core_cycle": (QK_LANES + PV_LANES) * 2,
        "ddr_read_beats_per_cluster": 196_608 // clusters,
        "ddr_write_beats_per_cluster": 131_072 // clusters,
        "ddr_read_beats_aggregate": 196_608,
        "ddr_write_beats_aggregate": 131_072,
    }


def _rows_by_cluster(clusters: int) -> list[list[int]]:
    rows = [[] for _ in range(clusters)]
    for item in enumerate_rows(clusters):
        rows[item.cluster_id].append(item.seq)
    return rows


def simulate_output_path(
    clusters: int,
    *,
    queue_rows: int = 32,
    canonical: bool = True,
    compute_cycles_per_row: int = 320,
    output_cycles_per_row: int = 32,
) -> OutputSimulation:
    """Model local row production and the C1 canonical output bottleneck.

    The compute period is the QK cycle floor averaged over a row
    (1,310,720 / 4,096 = 320).  It deliberately omits Softmax/fill/drain and
    therefore remains an architecture sensitivity model.
    """

    _validate_clusters(clusters)
    if queue_rows <= 0:
        raise ValueError("queue_rows must be positive")
    if compute_cycles_per_row <= 0 or output_cycles_per_row <= 0:
        raise ValueError("cycle periods must be positive")

    rows_by_cluster = _rows_by_cluster(clusters)
    if not canonical:
        local_cycles = [
            len(rows) * compute_cycles_per_row + output_cycles_per_row
            for rows in rows_by_cluster
        ]
        end = max(local_cycles)
        return OutputSimulation(
            evidence_level="architecture_model",
            clusters=clusters,
            canonical=False,
            queue_rows=queue_rows,
            compute_cycles_per_row=compute_cycles_per_row,
            output_cycles_per_row=output_cycles_per_row,
            cycles=end,
            rows_committed=Q_HEADS * SEQ_LEN,
            max_queue_depth=0,
            total_queue_stall_cycles=0,
            queue_stall_cycles=tuple(0 for _ in range(clusters)),
            last_local_accept_cycle=tuple(
                len(rows) * compute_cycles_per_row for rows in rows_by_cluster
            ),
        )

    queues = [deque() for _ in range(clusters)]
    indices = [0] * clusters
    compute_remaining = [compute_cycles_per_row] * clusters
    stalls = [0] * clusters
    last_accept = [0] * clusters
    max_depth = 0
    expected_seq = 0
    rows_committed = 0
    sink_remaining = 0
    cycles = 0
    total_rows = Q_HEADS * SEQ_LEN
    safety_limit = total_rows * (
        compute_cycles_per_row + output_cycles_per_row + 1
    )

    while rows_committed < total_rows:
        cycles += 1
        for cluster in range(clusters):
            if indices[cluster] >= len(rows_by_cluster[cluster]):
                continue
            if len(queues[cluster]) >= queue_rows:
                stalls[cluster] += 1
                continue
            compute_remaining[cluster] -= 1
            if compute_remaining[cluster] == 0:
                queues[cluster].append(rows_by_cluster[cluster][indices[cluster]])
                indices[cluster] += 1
                compute_remaining[cluster] = compute_cycles_per_row
                last_accept[cluster] = cycles
                max_depth = max(max_depth, len(queues[cluster]))

        if sink_remaining > 0:
            sink_remaining -= 1
            if sink_remaining == 0:
                rows_committed += 1

        if sink_remaining == 0 and expected_seq < total_rows:
            owner = (expected_seq // ROWS_PER_GROUP) % clusters
            if queues[owner] and queues[owner][0] == expected_seq:
                queues[owner].popleft()
                expected_seq += 1
                sink_remaining = output_cycles_per_row

        if cycles > safety_limit:
            raise RuntimeError("canonical output simulation did not converge")

    return OutputSimulation(
        evidence_level="architecture_model",
        clusters=clusters,
        canonical=True,
        queue_rows=queue_rows,
        compute_cycles_per_row=compute_cycles_per_row,
        output_cycles_per_row=output_cycles_per_row,
        cycles=cycles,
        rows_committed=rows_committed,
        max_queue_depth=max_depth,
        total_queue_stall_cycles=sum(stalls),
        queue_stall_cycles=tuple(stalls),
        last_local_accept_cycle=tuple(last_accept),
    )


def full_model(queue_rows: int = 32) -> dict[str, object]:
    simulations = {}
    for clusters in (1, 2, 4):
        simulations[str(clusters)] = {
            "infinite_sink": asdict(
                simulate_output_path(clusters, queue_rows=4096, canonical=False)
            ),
            "finite_canonical": asdict(
                simulate_output_path(clusters, queue_rows=queue_rows, canonical=True)
            ),
            "full_group_queue_sensitivity": asdict(
                simulate_output_path(clusters, queue_rows=512, canonical=True)
            ),
        }
    one = simulations["1"]
    for name in ("infinite_sink", "finite_canonical", "full_group_queue_sensitivity"):
        base_cycles = one[name]["cycles"]
        for clusters in (1, 2, 4):
            simulations[str(clusters)][name]["speedup_vs_1"] = (
                base_cycles / simulations[str(clusters)][name]["cycles"]
            )
    return {
        "schema": "cats-r4-a4-scaling-model-v1",
        "evidence_level": "architecture_model",
        "constants": {
            "seq_len": SEQ_LEN,
            "head_dim": HEAD_DIM,
            "q_heads": Q_HEADS,
            "kv_groups": KV_GROUPS,
            "q_heads_per_group": Q_HEADS_PER_GROUP,
            "windows_per_head": WINDOWS_PER_HEAD,
            "current_output_queue_rows_per_cluster": queue_rows,
        },
        "workload": {str(c): workload_report(c) for c in (1, 2, 4)},
        "v3_capacity_per_cluster": v3_capacity_per_cluster(),
        "resource_risk": {str(c): resource_estimate(c) for c in (1, 2, 4)},
        "service_requirements": {
            str(c): service_requirements(c) for c in (1, 2, 4)
        },
        "output_path": simulations,
    }


def validate() -> None:
    for clusters in (1, 2, 4):
        report = workload_report(clusters)
        assert len(enumerate_jobs(clusters)) == 256
        assert len(enumerate_rows(clusters)) == 4096
        for key, total in report["aggregate"].items():
            assert sum(item[key] for item in report["per_cluster"]) == total
    assert v3_capacity_per_cluster()["total_bytes"] == 154_520


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--queue-rows", type=int, default=32)
    parser.add_argument("--compact", action="store_true")
    args = parser.parse_args()
    validate()
    print(
        json.dumps(
            full_model(args.queue_rows),
            indent=None if args.compact else 2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
