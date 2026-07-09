# 2026-07-09T15:45:59.743078400
import vitis

client = vitis.create_client()
client.set_workspace(path="Attention_Mask_TEST")

comp = client.create_hls_component(name = "TEST_v1",cfg_file = ["hls_config.cfg"],template = "empty_hls_component")

cfg = client.get_config_file(path="D:\00game\FPT\Attention_Mask\Attention_Mask_TEST\TEST_v1\hls_config.cfg")

cfg.set_values(key="tb.file", values=["../tb/tb_attention_mask_from_file.cpp", "../mask_test_vectors/golden_masked_scores.hex", "../mask_test_vectors/raw_scores.hex"])

comp = client.get_component(name="TEST_v1")
comp.run(operation="C_SIMULATION")

cfg.set_values(key="tb.file", values=["../tb/tb_attention_mask_from_file.cpp", "../mask_test_vectors/raw_scores.hex"])

cfg.set_values(key="tb.file", values=["../tb/tb_attention_mask_from_file.cpp"])

cfg.set_values(key="tb.file", values=["../tb/tb_attention_mask_from_file.cpp", "../mask_test_vectors"])

comp.run(operation="C_SIMULATION")

comp.run(operation="SYNTHESIS")

comp.run(operation="CO_SIMULATION")

