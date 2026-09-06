import importlib.util
import sys
from pathlib import Path


MODEL_PATH = (
    Path(__file__).resolve().parents[1] / "python" / "cats_r4_c1_capacity_model.py"
)
SPEC = importlib.util.spec_from_file_location("cats_r4_c1_capacity_model", MODEL_PATH)
assert SPEC is not None and SPEC.loader is not None
MODEL = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODEL
SPEC.loader.exec_module(MODEL)


def test_reference_model_self_check() -> None:
    MODEL.validate()


def test_cluster_scaling_does_not_duplicate_work() -> None:
    total_beats = []
    total_qk_cycles = []
    total_pv_cycles = []
    for clusters in (1, 2, 4):
        scale = MODEL.scale_model(clusters)
        total_beats.append(scale.total_beats_per_cluster * clusters)
        total_qk_cycles.append(scale.qk_cycle_floor_per_cluster * clusters)
        total_pv_cycles.append(scale.pv_cycle_floor_per_cluster * clusters)
    assert total_beats == [327_680] * 3
    assert total_qk_cycles == [1_310_720] * 3
    assert total_pv_cycles == [1_056_768] * 3


def test_each_gqa_group_is_one_complete_dma_unit() -> None:
    traffic = MODEL.traffic_bytes()
    assert traffic["read"] // MODEL.KV_HEADS == 196_608
    assert traffic["write"] // MODEL.KV_HEADS == 131_072
    assert traffic["total"] // MODEL.KV_HEADS == 327_680
    assert (
        traffic["total"] // MODEL.KV_HEADS // MODEL.AXI_DATA_BYTES
        == 40_960
    )


def test_v2_q_slabs_partition_q_traffic_without_replication() -> None:
    slabs = MODEL.q_slab_schedule()
    traffic = MODEL.traffic_bytes()
    assert slabs["bytes_per_slab"] == 4_096
    assert slabs["beats_per_slab"] == 512
    assert slabs["bursts_per_slab"] == 2
    assert slabs["slabs_per_q_head"] == 8
    assert slabs["slabs_per_group"] == 32
    assert slabs["total_slabs"] == 256
    assert slabs["total_beats"] == traffic["q"] // MODEL.AXI_DATA_BYTES
    assert slabs["total_bursts"] == 512


if __name__ == "__main__":
    test_reference_model_self_check()
    test_cluster_scaling_does_not_duplicate_work()
    test_each_gqa_group_is_one_complete_dma_unit()
    test_v2_q_slabs_partition_q_traffic_without_replication()
    print("CATS-R4 C1 capacity model tests: PASS")
