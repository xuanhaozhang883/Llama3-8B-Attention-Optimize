# Build the Stage 5 single-GQA PS-DDR/DMA/Attention GUI project.
# No simulation, synthesis, implementation, or bitstream is launched here.

set script_dir [file normalize [file dirname [info script]]]
set system_root [file normalize [file join $script_dir ..]]
set rk_root [file normalize [file join $system_root ..]]
set repo_root [file normalize [file join $rk_root ..]]
set a_root [file join $repo_root A_attention_integration_final_v5]
set bc_root [file join $repo_root FPT_BC_QK_Softmax_PV_Delivery_v5]
set rope_root [file join $repo_root QK_after_RoPE]
set pv_root [file join $repo_root PV_module]
set golden_dir [file join $a_root tb golden_fpga_slice_data]
set project_dir [file join $system_root vx ps_attention]
set project_name rk_ps_attention_single_gqa
set part_name xczu15eg-ffvb1156-2-i
set vendor_ps_tcl [file join $system_root vendor ps apply_ps_config.tcl]

if {[info exists ::env(RK_PS_CONFIG_TCL)] &&
    $::env(RK_PS_CONFIG_TCL) ne ""} {
    set vendor_ps_tcl [file normalize $::env(RK_PS_CONFIG_TCL)]
}
if {![file isfile $vendor_ps_tcl]} {
    error "BLOCKED: verified RK V1.0 PS config is missing. Expected $vendor_ps_tcl"
}
source $vendor_ps_tcl
if {[llength [info procs rk_apply_ps_config]] != 1} {
    error "Vendor PS Tcl must define: proc rk_apply_ps_config {ps_cell}"
}

set design_files [list \
    [file join $a_root rtl top attention_with_pv_config_guard.sv] \
    [file join $a_root rtl controller attention_group_pv_controller.sv] \
    [file join $a_root rtl adapter pv_tile2_to_tile4_buffer_adapter.sv] \
    [file join $a_root rtl top attention_system_with_rope_pv_top.sv] \
    [file join $bc_root rtl adapter causal_mask_stream.sv] \
    [file join $bc_root rtl adapter qk_softmax_adapter.sv] \
    [file join $bc_root rtl adapter score_rowtile_buffer.sv] \
    [file join $bc_root rtl adapter score_rowtile_payload_bram.sv] \
    [file join $bc_root rtl backend bf16_v_cache.sv] \
    [file join $bc_root rtl backend pv_input_loader.sv] \
    [file join $bc_root rtl backend softmax_output_buffer.sv] \
    [file join $bc_root rtl backend softmax_pv_backend.sv] \
    [file join $bc_root rtl integration qk_softmax_frontend.sv] \
    [file join $bc_root rtl integration qk_softmax_pipeline_top.sv] \
    [file join $bc_root rtl integration qk_softmax_pv_pipeline_top.sv] \
    [file join $bc_root rtl qk bf16_to_fp32.v] \
    [file join $bc_root rtl qk fp32_add_ip.v] \
    [file join $bc_root rtl qk fp32_mul_ip.v] \
    [file join $bc_root rtl qk fp32_to_bf16.v] \
    [file join $bc_root rtl qk qk_result_scaler.sv] \
    [file join $bc_root rtl qk qk_systolic_gqa_top.sv] \
    [file join $bc_root rtl qk qk_systolic_pe.sv] \
    [file join $bc_root rtl qk qk_systolic_tile.sv] \
    [file join $bc_root rtl softmax exp_lut.sv] \
    [file join $bc_root rtl softmax softmax_bf16.sv] \
    [file join $bc_root rtl softmax unsigned_restoring_divider.sv] \
    [file join $rope_root rtl rope rope_pair_pipeline.sv] \
    [file join $rope_root rtl rope rope_group_prepare.sv] \
    [file join $rope_root rtl rope rope_qk_group_cache.sv] \
    [file join $rope_root rtl integration rope_group_bridge.sv] \
    [file join $rope_root rtl integration rope_qk_softmax_pv_pipeline_top.sv] \
    [file join $pv_root rtl pv_bf16_to_fp32.v] \
    [file join $pv_root rtl pv_fp32_add_ip.sv] \
    [file join $pv_root rtl pv_fp32_mul_ip.sv] \
    [file join $pv_root rtl pv_fp32_to_bf16.v] \
    [file join $pv_root rtl pv_result_converter.sv] \
    [file join $pv_root rtl pv_systolic_gqa_top.sv] \
    [file join $pv_root rtl pv_systolic_pe.sv] \
    [file join $pv_root rtl pv_systolic_tile.sv] \
    [file join $system_root rtl rk_xpm_sdpram.sv] \
    [file join $system_root rtl axis_qkv_memory_bridge.sv] \
    [file join $system_root rtl axis_bf16_packer.sv] \
    [file join $system_root rtl attention_axis_single_gqa_engine.sv] \
    [file join $system_root rtl attention_axil_control.sv] \
    [file join $system_root rtl attention_axis_accelerator.sv] \
    [file join $system_root rtl attention_axis_accelerator_bd.v]]
set memory_files [list \
    [file join $bc_root rtl softmax exp_lut_q15.mem] \
    [file join $golden_dir sin_bf16.hex] \
    [file join $golden_dir cos_bf16.hex]]
foreach required_file [concat $design_files $memory_files] {
    if {![file isfile $required_file]} {
        error "Missing Attention project input: $required_file"
    }
}

if {[llength [get_projects -quiet]] > 0} {
    close_project
}
# The Tcl and repository RTL are the source of truth.  Remove only this
# script-owned generated project so module-reference OOC checkpoints cannot
# survive an RTL change and silently feed stale logic into implementation.
set expected_project_dir [file normalize \
    [file join $system_root vx ps_attention]]
if {[file normalize $project_dir] ne $expected_project_dir} {
    error "Refusing to recreate unexpected project directory: $project_dir"
}
if {[file exists $project_dir]} {
    file delete -force $project_dir
}
create_project $project_name $project_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property default_lib xil_defaultlib [current_project]
add_files -norecurse $design_files
add_files -norecurse $memory_files
set_property file_type SystemVerilog [get_files -quiet *.sv]
foreach memory_file $memory_files {
    set_property file_type {Memory Initialization Files} \
        [get_files [file tail $memory_file]]
}
update_compile_order -fileset sources_1

source [file join $bc_root scripts create_fp32_ips.tcl]

create_bd_design ps_attention_single_gqa
set ps [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:zynq_ultra_ps_e:* ps_0]
rk_apply_ps_config $ps
foreach interface_name [list M_AXI_HPM0_FPD S_AXI_HPC0_FPD] {
    if {[llength [get_bd_intf_pins -quiet ps_0/$interface_name]] != 1} {
        error "Vendor PS config did not enable required interface $interface_name"
    }
}
foreach pin_name [list pl_clk0 pl_resetn0 maxihpm0_fpd_aclk \
                       saxihpc0_fpd_aclk] {
    if {[llength [get_bd_pins -quiet ps_0/$pin_name]] != 1} {
        error "Vendor PS config did not expose required pin $pin_name"
    }
}

set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:* dma_0]
set_property -dict [list \
    CONFIG.c_include_sg {0} \
    CONFIG.c_include_mm2s {1} \
    CONFIG.c_include_s2mm {1} \
    CONFIG.c_include_mm2s_dre {1} \
    CONFIG.c_include_s2mm_dre {1} \
    CONFIG.c_addr_width {40} \
    CONFIG.c_m_axi_mm2s_data_width {128} \
    CONFIG.c_m_axi_s2mm_data_width {128} \
    CONFIG.c_m_axis_mm2s_tdata_width {128} \
    CONFIG.c_s_axis_s2mm_tdata_width {128} \
    CONFIG.c_sg_length_width {26}] $dma
set accelerator [create_bd_cell -type module \
    -reference attention_axis_accelerator_bd attention_0]
set ctrl_ic [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:smartconnect:* ctrl_smc]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $ctrl_ic
set mem_ic [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:smartconnect:* mem_smc]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $mem_ic
set rst [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:proc_sys_reset:* rst_0]
set locked [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:xlconstant:* locked_1]
set_property -dict [list CONFIG.CONST_VAL {1}] $locked

connect_bd_intf_net [get_bd_intf_pins ps_0/M_AXI_HPM0_FPD] \
    [get_bd_intf_pins ctrl_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M00_AXI] \
    [get_bd_intf_pins dma_0/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M01_AXI] \
    [get_bd_intf_pins attention_0/s_axi_control]
connect_bd_intf_net [get_bd_intf_pins dma_0/M_AXI_MM2S] \
    [get_bd_intf_pins mem_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins dma_0/M_AXI_S2MM] \
    [get_bd_intf_pins mem_smc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins mem_smc/M00_AXI] \
    [get_bd_intf_pins ps_0/S_AXI_HPC0_FPD]
connect_bd_intf_net [get_bd_intf_pins dma_0/M_AXIS_MM2S] \
    [get_bd_intf_pins attention_0/s_axis_qkv]
connect_bd_intf_net [get_bd_intf_pins attention_0/m_axis_context] \
    [get_bd_intf_pins dma_0/S_AXIS_S2MM]

set fabric_clk [get_bd_pins ps_0/pl_clk0]
connect_bd_net $fabric_clk \
    [get_bd_pins ps_0/maxihpm0_fpd_aclk] \
    [get_bd_pins ps_0/saxihpc0_fpd_aclk] \
    [get_bd_pins dma_0/s_axi_lite_aclk] \
    [get_bd_pins dma_0/m_axi_mm2s_aclk] \
    [get_bd_pins dma_0/m_axi_s2mm_aclk] \
    [get_bd_pins ctrl_smc/aclk] \
    [get_bd_pins mem_smc/aclk] \
    [get_bd_pins attention_0/aclk] \
    [get_bd_pins rst_0/slowest_sync_clk]
connect_bd_net [get_bd_pins ps_0/pl_resetn0] \
    [get_bd_pins rst_0/ext_reset_in]
connect_bd_net [get_bd_pins locked_1/dout] \
    [get_bd_pins rst_0/dcm_locked]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] \
    [get_bd_pins dma_0/axi_resetn] \
    [get_bd_pins ctrl_smc/aresetn] \
    [get_bd_pins mem_smc/aresetn] \
    [get_bd_pins attention_0/aresetn]

assign_bd_address
validate_bd_design
save_bd_design
set bd_file [get_files ps_attention_single_gqa.bd]
generate_target all $bd_file
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper
set_property top ps_attention_single_gqa_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1
puts "RK_PS_ATTENTION_PROJECT_READY=[file join $project_dir ${project_name}.xpr]"
puts "RK_PS_ATTENTION_BUILD_SCOPE=PROJECT_AND_OUTPUT_PRODUCTS_ONLY"
close_project
