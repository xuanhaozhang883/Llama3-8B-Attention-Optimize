#!/usr/bin/env python3
"""Deterministic CATS-R4 C1 capacity, traffic, and cycle-floor model.

This is an architecture model only.  It deliberately excludes Softmax latency,
pipeline fill/drain, arbitration, DDR latency, and all measured implementation
claims.  Those terms must be added from the frozen A/B interface and later RTL
counters.
"""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass


SEQ_LEN = 128
HEAD_DIM = 128
Q_HEADS = 32
KV_HEADS = 8
Q_PER_KV = Q_HEADS // KV_HEADS
ROW_GROUP = 16
LANES = 32
BF16_BYTES = 2
ACCUM_BYTES = 4
AXI_DATA_BYTES = 8
AXI_CLOCK_MHZ = 150
AXI_BURST_BEATS = 256

# xczu15eg-ffvb1156-2-i capacities used only for percentage calculations.
DEVICE_LUT = 341_280
DEVICE_FF = 682_560
DEVICE_BRAM36 = 744


@dataclass(frozen=True)
class MemoryModel:
    k_ping_pong_bytes: int
    v_ping_pong_bytes: int
    q_ping_pong_bytes: int
    abc_row_slots_bytes: int
    qk_pv_accum_bytes: int
    output_queue_bytes: int
    metadata_fifos_bytes: int
    cluster_total_bytes: int
    cluster_bram36: int
    cluster_uram: int
    cluster_distributed_bits: int


@dataclass(frozen=True)
class ScaleModel:
    clusters: int
    groups_per_cluster: int
    q_heads_per_cluster: int
    logical_kib: float
    local_bram36: int
    infrastructure_bram36_with_shared: int
    infrastructure_lut_ceiling: int
    infrastructure_ff_ceiling: int
    read_beats_per_cluster: int
    write_beats_per_cluster: int
    total_beats_per_cluster: int
    qk_cycle_floor_per_cluster: int
    pv_cycle_floor_per_cluster: int
    core_floor_ms_150: float
    core_floor_ms_200: float
    local_k_read_gbs_150: float
    local_v_read_gbs_150: float
    local_k_read_gbs_200: float
    local_v_read_gbs_200: float


def ceil_div(value: int, divisor: int) -> int:
    return (value + divisor - 1) // divisor


def memory_model() -> MemoryModel:
    # K/V each retain one active and one fill image for a single KV group.
    k_bytes = 2 * SEQ_LEN * HEAD_DIM * BF16_BYTES
    v_bytes = 2 * SEQ_LEN * HEAD_DIM * BF16_BYTES
    # Q ping-pongs two R-row slabs.
    q_bytes = 2 * ROW_GROUP * HEAD_DIM * BF16_BYTES
    # A/B/C are independent whole-row, 16-bit payload slots.
    abc_bytes = 3 * SEQ_LEN * BF16_BYTES
    # R contexts x 32 lanes x FP32 for both QK and PV.
    accum_bytes = 2 * ROW_GROUP * LANES * ACCUM_BYTES
    # Thirty-two complete BF16 output rows, serialized as 1,024 64-bit beats.
    output_bytes = 2 * ROW_GROUP * HEAD_DIM * BF16_BYTES
    # Per-cluster command, completion, output-tag, and ownership queues.
    metadata_bytes = 640
    total_bytes = (
        k_bytes
        + v_bytes
        + q_bytes
        + abc_bytes
        + accum_bytes
        + output_bytes
        + metadata_bytes
    )

    # K: 32 RAMB18, V: 32 RAMB18, Q: 4 RAMB18, output: 4 RAMB18.
    # Two RAMB18 are counted as one RAMB36 tile by Vivado.
    bram36 = (32 + 32 + 4 + 4) // 2
    distributed_bits = (abc_bytes + accum_bytes + metadata_bytes) * 8
    return MemoryModel(
        k_ping_pong_bytes=k_bytes,
        v_ping_pong_bytes=v_bytes,
        q_ping_pong_bytes=q_bytes,
        abc_row_slots_bytes=abc_bytes,
        qk_pv_accum_bytes=accum_bytes,
        output_queue_bytes=output_bytes,
        metadata_fifos_bytes=metadata_bytes,
        cluster_total_bytes=total_bytes,
        cluster_bram36=bram36,
        cluster_uram=0,
        cluster_distributed_bits=distributed_bits,
    )


def traffic_bytes() -> dict[str, int]:
    q = Q_HEADS * SEQ_LEN * HEAD_DIM * BF16_BYTES
    k = KV_HEADS * SEQ_LEN * HEAD_DIM * BF16_BYTES
    v = KV_HEADS * SEQ_LEN * HEAD_DIM * BF16_BYTES
    output = Q_HEADS * SEQ_LEN * HEAD_DIM * BF16_BYTES
    return {
        "q": q,
        "k": k,
        "v": v,
        "output": output,
        "read": q + k + v,
        "write": output,
        "total": q + k + v + output,
    }


def cycle_floors_per_q_head() -> tuple[int, int]:
    # Causal QK: 32 keys in parallel, one feature step per cycle.
    qk = sum(ceil_div(row + 1, LANES) * HEAD_DIM for row in range(SEQ_LEN))
    # Causal PV: 32 features in parallel, four feature passes over valid keys.
    pv = sum((HEAD_DIM // LANES) * (row + 1) for row in range(SEQ_LEN))
    return qk, pv


def scale_model(clusters: int) -> ScaleModel:
    if clusters not in (1, 2, 4):
        raise ValueError("clusters must be 1, 2, or 4")
    if KV_HEADS % clusters or Q_HEADS % clusters:
        raise ValueError("cluster count must divide the head counts")

    mem = memory_model()
    traffic = traffic_bytes()
    qk_head, pv_head = cycle_floors_per_q_head()
    q_heads_local = Q_HEADS // clusters
    qk_cycles = qk_head * q_heads_local
    pv_cycles = pv_head * q_heads_local
    core_floor_cycles = max(qk_cycles, pv_cycles)
    bytes_per_cycle = LANES * BF16_BYTES

    # C-owned logic planning ceilings: fixed shared DMA/CDC/arbiter plus local
    # banking/control.  These are budgets, not synthesis estimates.
    shared_lut = 4_000
    shared_ff = 6_000
    shared_bram36 = 2
    local_lut = 3_000
    local_ff = 6_000

    return ScaleModel(
        clusters=clusters,
        groups_per_cluster=KV_HEADS // clusters,
        q_heads_per_cluster=q_heads_local,
        logical_kib=mem.cluster_total_bytes * clusters / 1024.0,
        local_bram36=mem.cluster_bram36 * clusters,
        infrastructure_bram36_with_shared=mem.cluster_bram36 * clusters
        + shared_bram36,
        infrastructure_lut_ceiling=shared_lut + local_lut * clusters,
        infrastructure_ff_ceiling=shared_ff + local_ff * clusters,
        read_beats_per_cluster=traffic["read"] // AXI_DATA_BYTES // clusters,
        write_beats_per_cluster=traffic["write"] // AXI_DATA_BYTES // clusters,
        total_beats_per_cluster=traffic["total"] // AXI_DATA_BYTES // clusters,
        qk_cycle_floor_per_cluster=qk_cycles,
        pv_cycle_floor_per_cluster=pv_cycles,
        core_floor_ms_150=core_floor_cycles / 150_000.0,
        core_floor_ms_200=core_floor_cycles / 200_000.0,
        local_k_read_gbs_150=bytes_per_cycle * 150_000_000 / 1e9,
        local_v_read_gbs_150=bytes_per_cycle * 150_000_000 / 1e9,
        local_k_read_gbs_200=bytes_per_cycle * 200_000_000 / 1e9,
        local_v_read_gbs_200=bytes_per_cycle * 200_000_000 / 1e9,
    )


def full_model() -> dict[str, object]:
    mem = memory_model()
    traffic = traffic_bytes()
    scales = [scale_model(c) for c in (1, 2, 4)]
    return {
        "constants": {
            "seq_len": SEQ_LEN,
            "head_dim": HEAD_DIM,
            "q_heads": Q_HEADS,
            "kv_heads": KV_HEADS,
            "q_per_kv": Q_PER_KV,
            "row_group": ROW_GROUP,
            "lanes": LANES,
            "axi_data_bits": AXI_DATA_BYTES * 8,
            "axi_clock_mhz": AXI_CLOCK_MHZ,
            "axi_burst_beats": AXI_BURST_BEATS,
        },
        "memory_per_cluster": asdict(mem),
        "traffic_full_workload_bytes": traffic,
        "traffic_full_workload_beats": {
            key: value // AXI_DATA_BYTES for key, value in traffic.items()
        },
        "scale": [asdict(item) for item in scales],
    }


def validate() -> None:
    mem = memory_model()
    traffic = traffic_bytes()
    qk_head, pv_head = cycle_floors_per_q_head()
    assert mem.cluster_total_bytes == 152_960
    assert mem.cluster_bram36 == 36
    assert mem.cluster_distributed_bits == 44_032
    assert traffic["read"] == 1_572_864
    assert traffic["write"] == 1_048_576
    assert traffic["total"] == 2_621_440
    assert traffic["total"] // AXI_DATA_BYTES == 327_680
    assert qk_head == 40_960
    assert pv_head == 33_024
    assert scale_model(4).total_beats_per_cluster == 81_920


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--compact", action="store_true", help="emit compact rather than indented JSON"
    )
    args = parser.parse_args()
    validate()
    print(
        json.dumps(
            full_model(),
            indent=None if args.compact else 2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
