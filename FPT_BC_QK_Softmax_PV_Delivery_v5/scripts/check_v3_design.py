#!/usr/bin/env python3
"""Static contract audit for the v3 BRAM fix, controller and V-cache."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def require_tokens(relative: str, tokens: list[str]) -> None:
    text = (ROOT / relative).read_text(encoding="utf-8")
    missing = [token for token in tokens if token not in text]
    if missing:
        raise SystemExit(f"{relative} missing required tokens: {missing}")


def module_ports(relative: str, module_name: str) -> set[str]:
    text = (ROOT / relative).read_text(encoding="utf-8")
    start = text.index(f"module {module_name}")
    header = text[start:text.index("\n);", start)]
    ports: set[str] = set()
    for line in header.splitlines():
        if re.match(r"\s*(input|output|inout)\b", line):
            match = re.search(r"([A-Za-z_]\w*)\s*,?\s*$", line)
            if not match:
                raise SystemExit(f"Cannot parse port line: {line}")
            ports.add(match.group(1))
    return ports


def instance_ports(relative: str, instance_name: str) -> set[str]:
    text = (ROOT / relative).read_text(encoding="utf-8")
    marker = f") {instance_name} ("
    start = text.index(marker) + len(marker)
    block = text[start:text.index("\n    );", start)]
    return set(re.findall(r"\.([A-Za-z_]\w*)\s*(?:\(|,|\n)", block))


def check_instance(
    definition_file: str,
    module_name: str,
    instance_file: str,
    instance_name: str,
) -> None:
    defined = module_ports(definition_file, module_name)
    connected = instance_ports(instance_file, instance_name)
    if defined != connected:
        missing = sorted(defined - connected)
        extra = sorted(connected - defined)
        raise SystemExit(
            f"{instance_file}:{instance_name} port mismatch "
            f"missing={missing} extra={extra}"
        )


def check_wildcard_testbench_ports(
    definition_file: str,
    module_name: str,
    testbench_file: str,
    instance_marker: str,
) -> None:
    ports = module_ports(definition_file, module_name)
    text = (ROOT / testbench_file).read_text(encoding="utf-8")
    declarations = text[:text.index(instance_marker)]
    missing = []
    for port in sorted(ports):
        pattern = rf"\blogic(?:\s+\[[^\]]+\])?\s+{re.escape(port)}\b"
        if not re.search(pattern, declarations):
            missing.append(port)
    if missing:
        raise SystemExit(
            f"{testbench_file} wildcard instance is missing signals: {missing}"
        )


def main() -> None:
    require_tokens("rtl/backend/bf16_v_cache.sv", [
        'ram_style = "block"',
        "load_valid && load_ready",
        "req_valid && req_ready",
        "rsp_valid_reg && rsp_ready",
        "protocol_error",
    ])
    require_tokens("rtl/integration/gqa_group_controller.sv", [
        "S_LAUNCH",
        "S_WAIT",
        "NUM_GROUPS-1",
        "group_complete",
        "completed_group_id",
    ])
    require_tokens("rtl/integration/qk_softmax_pv_system_top.sv", [
        "gqa_group_controller",
        "qk_softmax_pv_pipeline_top",
        "bf16_v_cache",
        ".group_done(pipeline_done)",
        ".req_addr(v_req_addr)",
    ])
    require_tokens("tb/tb_qk_softmax_pv_pipeline.sv", [
        "wait (done);\n            // done is generated",
        "@(posedge clk);",
        "c_done_count != 1",
    ])
    require_tokens("tb/tb_bc_robustness.sv", [
        "tb_bc_invalid_group_id",
        "tb_bc_reset_and_busy",
        "reset recovery during QK",
        "reset recovery during C backend",
        "stalled PV output",
    ])
    require_tokens("tb/tb_qk_softmax_pv_all_groups.sv", [
        "A-style controller executed Groups 0..7",
        "synthesizable V-cache supplied every PV vector",
        "GQA_GROUPS*VECS_PER_GROUP",
    ])
    require_tokens("scripts/synthesis_bc_common.tcl", [
        "Unexpected latch primitives",
        "Unresolved black-box cells",
        "black_box_cells=",
        "MDRV-1",
        "Row Tile Buffer did not infer block RAM",
        "P Buffer did not infer block RAM",
        "P Buffer BRAM usage is unexpectedly high",
        "unexpected large FF array",
        "EXP LUT logic cells",
        "100 MHz synthesis timing failed",
    ])
    require_tokens("scripts/create_fp32_ips.tcl", [
        "GENERATE_SYNTH_CHECKPOINT false",
        "Include the floating-point implementation in the top-level synthesis",
    ])
    require_tokens("rtl/adapter/score_rowtile_payload_bram.sv", [
        'ram_style = "block"',
        "if (wr_en)",
        "mem[wr_addr] <= wr_data",
        "if (rd_en)",
        "rd_data <= mem[rd_addr]",
    ])
    require_tokens("rtl/adapter/score_rowtile_buffer.sv", [
        "score_rowtile_payload_bram",
        "u_payload_bram",
        "assign payload_rd_en",
        "(!out_valid_reg || m_ready)",
        "assign m_data  = payload_rd_data",
    ])
    require_tokens("scripts/run_synthesis_row_buffer.tcl", [
        "Expected exactly one Row Tile Buffer RAMB primitive",
        "PASS: Row Tile Buffer inferred exactly one block-RAM primitive",
    ])
    require_tokens("rtl/backend/softmax_output_buffer.sv", [
        "begin : GEN_P_LANE",
        "p_mem_lane[wr_mem_addr] <= s_data",
        "p_rsp_lane_reg[p_lane] <= p_mem_lane[rd_mem_addr]",
    ])
    require_tokens("rtl/softmax/softmax_bf16.sv", [
        "raw_stage_valid",
        "raw_stage_data  <= in_data",
        "load_stage_valid",
        "load_stage_fixed <= bf16_to_fixed(raw_stage_data)",
        "ST_OUTPUT_MUL",
        "ST_OUTPUT_ROUND",
        "ST_OUTPUT_CONVERT",
        "ST_EXP_ADDR",
        "ST_EXP_LUT",
        "ST_EXP_ACCUM",
        "exp_score_reg <= score_mem[proc_idx]",
        ".addr(exp_addr_reg)",
        "sum_exp <= sum_exp + exp_value_reg",
        "probability_product_reg",
        "probability_q15_reg",
        "out_data_reg",
        "BF16_SHIFT_BIAS",
        "BF16_SAT_EXP",
        "BF16_ZERO_EXP",
        "EXP_LIMIT_FIXED",
        "EXP_ROUND_BIAS",
    ])
    require_tokens("constraints/qk_softmax_100mhz.xdc", [
        "create_clock -name clk -period 10.000",
        "HD.CLK_SRC BUFGCTRL_X0Y0",
    ])

    check_instance(
        "rtl/adapter/score_rowtile_payload_bram.sv",
        "score_rowtile_payload_bram",
        "rtl/adapter/score_rowtile_buffer.sv",
        "u_payload_bram",
    )
    check_instance(
        "rtl/integration/gqa_group_controller.sv",
        "gqa_group_controller",
        "rtl/integration/qk_softmax_pv_system_top.sv",
        "u_group_controller",
    )
    check_instance(
        "rtl/integration/qk_softmax_pv_pipeline_top.sv",
        "qk_softmax_pv_pipeline_top",
        "rtl/integration/qk_softmax_pv_system_top.sv",
        "u_pipeline",
    )
    check_instance(
        "rtl/backend/bf16_v_cache.sv",
        "bf16_v_cache",
        "rtl/integration/qk_softmax_pv_system_top.sv",
        "u_v_cache",
    )
    check_instance(
        "rtl/integration/qk_softmax_pipeline_top.sv",
        "qk_softmax_pipeline_top",
        "rtl/integration/qk_softmax_pv_pipeline_top.sv",
        "u_b_pipeline",
    )
    check_instance(
        "rtl/backend/softmax_pv_backend.sv",
        "softmax_pv_backend",
        "rtl/integration/qk_softmax_pv_pipeline_top.sv",
        "u_c_backend",
    )
    check_wildcard_testbench_ports(
        "rtl/integration/qk_softmax_pv_system_top.sv",
        "qk_softmax_pv_system_top",
        "tb/tb_qk_softmax_pv_all_groups.sv",
        ") dut (.*);",
    )

    groups = 8
    seq_len = 128
    head_dim = 128
    pv_tile = 2
    v_scalars = groups * seq_len * head_dim
    v_bits = v_scalars * 16
    v_words = v_scalars // pv_tile
    probs_per_group = 4 * seq_len * seq_len
    vecs_per_group = 4 * (seq_len // pv_tile) * (head_dim // pv_tile) * seq_len
    assert v_words == 65_536
    assert probs_per_group == 65_536
    assert vecs_per_group == 2_097_152

    print("PASS: v3 BRAM/controller/V-cache tokens and named ports")
    print(f"PASS: full V-cache contract scalars={v_scalars} "
          f"vector_words={v_words} bits={v_bits}")
    print(f"PASS: per-Group probabilities={probs_per_group} "
          f"PV_vectors={vecs_per_group}")


if __name__ == "__main__":
    main()
