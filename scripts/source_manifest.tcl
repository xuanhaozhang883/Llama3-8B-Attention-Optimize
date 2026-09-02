set board_root [file normalize [file join [file dirname [info script]] ..]]

# Production RTL reachable from attention_board_top.
# Files under archive/ are historical references and must not enter Vivado.
set design_files [list \
    [file join $board_root rtl board aq_axi_master_fixed.v] \
    [file join $board_root rtl board attention_board_top.sv] \
    [file join $board_root rtl board fpt_attention_board_engine.sv] \
    [file join $board_root rtl board fpt_context_ddr_writer.sv] \
    [file join $board_root rtl board fpt_raw_qk_ddr_reader.sv] \
    [file join $board_root rtl board fpt_v_ddr_loader.sv] \
    [file join $board_root rtl core a flash_attention_system_with_rope_top.sv] \
    [file join $board_root rtl core bc backend bf16_v_cache.sv] \
    [file join $board_root rtl core bc qk bf16_to_fp32.v] \
    [file join $board_root rtl core bc qk fp32_add_ip.v] \
    [file join $board_root rtl core bc qk fp32_mul_ip.v] \
    [file join $board_root rtl core bc qk fp32_to_bf16.v] \
    [file join $board_root rtl core bc qk qk_parallel_systolic_gqa_top.sv] \
    [file join $board_root rtl core bc qk qk_result_scaler.sv] \
    [file join $board_root rtl core bc qk qk_systolic_gqa_top.sv] \
    [file join $board_root rtl core bc qk qk_systolic_pe.sv] \
    [file join $board_root rtl core bc qk qk_systolic_tile.sv] \
    [file join $board_root rtl core bc softmax exp_lut.sv] \
    [file join $board_root rtl core bc softmax unsigned_restoring_divider.sv] \
    [file join $board_root rtl core online flash_attention_consumer_top.sv] \
    [file join $board_root rtl core online flash_context_fusion_backend.sv] \
    [file join $board_root rtl core online flash_context_update_pe.sv] \
    [file join $board_root rtl core online flash_online_softmax_frontend.sv] \
    [file join $board_root rtl core online flash_score_tile_fifo.sv] \
    [file join $board_root rtl core online qk_flash_attention_pipeline_top.sv] \
    [file join $board_root rtl core online rope_qk_flash_attention_pipeline_top.sv] \
    [file join $board_root rtl core pv pv_fp32_add_ip.sv] \
    [file join $board_root rtl core pv pv_fp32_mul_ip.sv] \
    [file join $board_root rtl core rope rope_group_bridge.sv] \
    [file join $board_root rtl core rope rope_group_prepare.sv] \
    [file join $board_root rtl core rope rope_pair_pipeline.sv] \
    [file join $board_root rtl core rope rope_qk_group_cache.sv]]

set memory_files [list \
    [file join $board_root mem exp_lut_q15.mem] \
    [file join $board_root mem sin_bf16.hex] \
    [file join $board_root mem cos_bf16.hex]]
set constraint_files [list \
    [file join $board_root scripts attention_board.xdc]]

proc require_files {items} {
    foreach f $items {
        if {![file isfile $f]} { error "Missing required file: $f" }
    }
}

require_files $design_files
require_files $memory_files
require_files $constraint_files
