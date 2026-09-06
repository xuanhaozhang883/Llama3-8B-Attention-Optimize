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


if __name__ == "__main__":
    test_reference_model_self_check()
    test_cluster_scaling_does_not_duplicate_work()
    test_each_gqa_group_is_one_complete_dma_unit()
    print("CATS-R4 C1 capacity model tests: PASS")
