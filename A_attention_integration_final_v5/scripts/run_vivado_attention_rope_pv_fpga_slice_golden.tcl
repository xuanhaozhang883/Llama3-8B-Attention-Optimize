# One-Group fpga_slice numerical regression:
# raw Q/K -> RTL RoPE -> QK -> causal mask -> Softmax -> real PV -> Context.
#
# Install this file under A_attention_integration_final_v5/scripts and run:
#   cd D:/FPT/Llama3-8B/A_attention_integration_final_v5
#   source scripts/run_vivado_attention_rope_pv_fpga_slice_golden.tcl
#
# Before running, prepare the exact repository tensors with:
#   python scripts/prepare_attention_fpga_slice_vectors.py --project-root ..

set a_root [file normalize [file join [file dirname [info script]] ..]]
set repo_root [file normalize [file join $a_root ..]]
set bc_root [file join $repo_root FPT_BC_QK_Softmax_PV_Delivery_v5]
set rope_root [file join $repo_root QK_after_RoPE]
set pv_root [file join $repo_root PV_module]
set golden_data [file join $a_root tb golden_fpga_slice_data]

set project_dir [file join $a_root vivado_attention_rope_pv_fpga_slice_golden]
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
    [file join $a_root tb tb_attention_system_with_rope_pv_fpga_slice_golden.sv] \
    [file join $bc_root sim_models floating_point_behavioral.sv]]

set memory_files [list \
    [file join $bc_root rtl softmax exp_lut_q15.mem] \
    [file join $golden_data q_before_rope_bf16.hex] \
    [file join $golden_data k_before_rope_bf16.hex] \
    [file join $golden_data v_bf16.hex] \
    [file join $golden_data q_after_rope_golden_bf16.hex] \
    [file join $golden_data k_after_rope_golden_bf16.hex] \
    [file join $golden_data softmax_weights_bf16.hex] \
    [file join $golden_data attn_out_per_head_bf16.hex] \
    [file join $golden_data sin_bf16.hex] \
    [file join $golden_data cos_bf16.hex]]

foreach file_name [concat $design_files $simulation_files $memory_files] {
    if {![file isfile $file_name]} {
        error "Required golden-regression file is missing: $file_name"
    }
}

catch {close_sim}
if {[llength [get_projects -quiet]] > 0} {
    close_project
}

create_project fpt_attention_rope_pv_fpga_slice_golden \
    $project_dir -part $part_name -force

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -norecurse $design_files
add_files -fileset sim_1 -norecurse $simulation_files
add_files -fileset sim_1 -norecurse $memory_files

set_property file_type SystemVerilog [get_files -quiet *.sv]
foreach memory_file $memory_files {
    set imported [get_files -quiet [file tail $memory_file]]
    if {[llength $imported] != 1} {
        error "Expected exactly one imported memory file named [file tail $memory_file]"
    }
    set_property file_type {Memory Initialization Files} $imported
}

set_property top attention_system_with_rope_pv_top [get_filesets sources_1]
set_property top tb_attention_system_with_rope_pv_fpga_slice_golden [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "============================================================"
puts "FPGA_SLICE FULL-CHAIN GOLDEN REGRESSION"
puts "raw Q/K -> RoPE -> QK -> Mask -> Softmax -> real PV -> Context"
puts "Design top    : attention_system_with_rope_pv_top"
puts "Simulation top: tb_attention_system_with_rope_pv_fpga_slice_golden"
puts "Physical      : 8 GQA Groups (normal Llama interface widths)"
puts "This command  : Group 0 only = 4 Q heads + 1 KV head"
puts "Shape         : SEQ_LEN=128, HEAD_DIM=128"
puts "Constraints   : none (behavioral simulation)"
puts "This numerical run is much longer than the 4x4 smoke test."
puts "============================================================"

launch_simulation -simset sim_1 -mode behavioral
run all

puts "============================================================"
puts "Required success line:"
puts {[PASS] fpga_slice full-chain numerical comparison passed}
puts "If it fails, use the ROPE-Q/ROPE-K/SOFTMAX/CONTEXT labels to localize it."
puts "============================================================"
