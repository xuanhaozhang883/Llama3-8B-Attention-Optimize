# Full-chain behavioral smoke test:
# raw Q/K -> RTL RoPE -> QK -> causal mask -> Softmax -> real PV -> Context.
#
# Place this file at:
#   A_attention_integration_final_v5/scripts/
# Then run it from the Vivado Tcl Console with:
#   cd D:/path/to/Llama3-8B/A_attention_integration_final_v5
#   source scripts/run_vivado_attention_with_rope_pv_fullchain_smoke.tcl
#
# Constraints are intentionally not added: behavioral simulation does not use
# XDC timing constraints. A separate synthesis/implementation project should
# add a board/clock-specific XDC later.

set a_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $a_root ..]]
set bc_root [file join $repo_root FPT_BC_QK_Softmax_PV_Delivery_v5]
set rope_root [file join $repo_root QK_after_RoPE]
set rope_data_root [file join $repo_root RoPE data]
set pv_root [file join $repo_root PV_module]

set project_dir [file join $a_root vivado_attention_with_rope_pv_fullchain_smoke]
set part_name "xc7a35tcpg236-1"

set design_files [list \
    [file join $a_root rtl top attention_with_pv_config_guard.sv] \
    [file join $a_root rtl controller attention_group_pv_controller.sv] \
    [file join $a_root rtl adapter pv_tile2_to_tile4_buffer_adapter.sv] \
    [file join $a_root rtl top attention_system_with_rope_pv_top.sv] \
    \
    [file join $bc_root rtl adapter causal_mask_stream.sv] \
    [file join $bc_root rtl adapter qk_softmax_adapter.sv] \
    [file join $bc_root rtl adapter score_rowtile_buffer.sv] \
    [file join $bc_root rtl adapter score_rowtile_payload_bram.sv] \
    \
    [file join $bc_root rtl backend bf16_v_cache.sv] \
    [file join $bc_root rtl backend pv_input_loader.sv] \
    [file join $bc_root rtl backend softmax_output_buffer.sv] \
    [file join $bc_root rtl backend softmax_pv_backend.sv] \
    \
    [file join $bc_root rtl integration qk_softmax_frontend.sv] \
    [file join $bc_root rtl integration qk_softmax_pipeline_top.sv] \
    [file join $bc_root rtl integration qk_softmax_pv_pipeline_top.sv] \
    \
    [file join $bc_root rtl qk bf16_to_fp32.v] \
    [file join $bc_root rtl qk fp32_add_ip.v] \
    [file join $bc_root rtl qk fp32_mul_ip.v] \
    [file join $bc_root rtl qk fp32_to_bf16.v] \
    [file join $bc_root rtl qk qk_result_scaler.sv] \
    [file join $bc_root rtl qk qk_systolic_gqa_top.sv] \
    [file join $bc_root rtl qk qk_systolic_pe.sv] \
    [file join $bc_root rtl qk qk_systolic_tile.sv] \
    \
    [file join $bc_root rtl softmax exp_lut.sv] \
    [file join $bc_root rtl softmax softmax_bf16.sv] \
    [file join $bc_root rtl softmax unsigned_restoring_divider.sv] \
    \
    [file join $rope_root rtl rope rope_pair_pipeline.sv] \
    [file join $rope_root rtl rope rope_group_prepare.sv] \
    [file join $rope_root rtl rope rope_qk_group_cache.sv] \
    [file join $rope_root rtl integration rope_group_bridge.sv] \
    [file join $rope_root rtl integration rope_qk_softmax_pv_pipeline_top.sv] \
    \
    [file join $pv_root rtl pv_bf16_to_fp32.v] \
    [file join $pv_root rtl pv_fp32_add_ip.sv] \
    [file join $pv_root rtl pv_fp32_mul_ip.sv] \
    [file join $pv_root rtl pv_fp32_to_bf16.v] \
    [file join $pv_root rtl pv_result_converter.sv] \
    [file join $pv_root rtl pv_systolic_gqa_top.sv] \
    [file join $pv_root rtl pv_systolic_pe.sv] \
    [file join $pv_root rtl pv_systolic_tile.sv]]

set simulation_files [list \
    [file join $a_root tb tb_attention_system_with_rope_pv_small.sv] \
    [file join $bc_root sim_models floating_point_behavioral.sv]]

set memory_files [list \
    [file join $bc_root rtl softmax exp_lut_q15.mem] \
    [file join $rope_root tb data rope_small_sin.hex] \
    [file join $rope_root tb data rope_small_cos.hex]]

foreach file_name [concat $design_files $simulation_files $memory_files] {
    if {![file isfile $file_name]} {
        error "Required full-chain source is missing: $file_name"
    }
}

catch {close_sim}
if {[llength [get_projects -quiet]] > 0} {
    close_project
}

create_project fpt_attention_rope_pv_fullchain_smoke \
    $project_dir -part $part_name -force

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -norecurse $design_files
add_files -fileset sim_1 -norecurse $simulation_files
add_files -fileset sim_1 -norecurse $memory_files

set_property file_type SystemVerilog [get_files -quiet *.sv]
set_property file_type {Memory Initialization Files} \
    [get_files -quiet *exp_lut_q15.mem]
set_property file_type {Memory Initialization Files} \
    [get_files -quiet *rope_small_sin.hex]
set_property file_type {Memory Initialization Files} \
    [get_files -quiet *rope_small_cos.hex]

set_property top attention_system_with_rope_pv_top [get_filesets sources_1]
set_property top tb_attention_system_with_rope_pv_small [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "============================================================"
puts "FULL-CHAIN RTL SMOKE TEST"
puts "raw Q/K -> RoPE -> QK -> Mask -> Softmax -> real PV -> Context"
puts "Design top    : attention_system_with_rope_pv_top"
puts "Simulation top: tb_attention_system_with_rope_pv_small"
puts "Config        : SEQ_LEN=4 HEAD_DIM=4 GROUPS=8"
puts "Constraints   : none (behavioral simulation)"
puts "============================================================"

launch_simulation -simset sim_1 -mode behavioral
run all

puts "============================================================"
puts "Simulation ended. Required final line:"
puts {[PASS] Raw-QK+RoPE+QK+Mask+Softmax+real-PV full-chain smoke test}
puts "There must be no FATAL, protocol_error, or TIMEOUT."
puts "============================================================"
