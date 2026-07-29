# Build the Stage 3/4 PS-DDR + AXI DMA simple-mode loopback GUI project.
# No simulation, synthesis, implementation, or bitstream is launched here.

set script_dir [file normalize [file dirname [info script]]]
set system_root [file normalize [file join $script_dir ..]]
set rk_root [file normalize [file join $system_root ..]]
set project_dir [file join $system_root vx ps_dma_loopback]
set project_name rk_ps_dma_loopback
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

if {[llength [get_projects -quiet]] > 0} {
    close_project
}
create_project $project_name $project_dir -part $part_name -force
set_property target_language Verilog [current_project]

set loopback_files [list \
    [file join $system_root rtl axis_dma_loopback.sv] \
    [file join $system_root rtl axis_dma_loopback_bd.v]]
foreach loopback_file $loopback_files {
    if {![file isfile $loopback_file]} {
        error "Missing loopback RTL: $loopback_file"
    }
}
add_files -norecurse $loopback_files
set_property file_type SystemVerilog \
    [get_files [file tail [lindex $loopback_files 0]]]
update_compile_order -fileset sources_1

create_bd_design ps_dma_loopback
set ps [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:zynq_ultra_ps_e:* ps_0]
rk_apply_ps_config $ps

set required_ps_interfaces [list M_AXI_HPM0_FPD S_AXI_HPC0_FPD]
foreach interface_name $required_ps_interfaces {
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

set ctrl_ic [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:smartconnect:* ctrl_smc]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $ctrl_ic
set mem_ic [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:smartconnect:* mem_smc]
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] $mem_ic
set rst [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:proc_sys_reset:* rst_0]
set locked [create_bd_cell -type ip \
    -vlnv xilinx.com:ip:xlconstant:* locked_1]
set_property -dict [list CONFIG.CONST_VAL {1}] $locked
set loopback [create_bd_cell -type module \
    -reference axis_dma_loopback_bd loopback_0]

connect_bd_intf_net [get_bd_intf_pins ps_0/M_AXI_HPM0_FPD] \
    [get_bd_intf_pins ctrl_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins ctrl_smc/M00_AXI] \
    [get_bd_intf_pins dma_0/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins dma_0/M_AXI_MM2S] \
    [get_bd_intf_pins mem_smc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins dma_0/M_AXI_S2MM] \
    [get_bd_intf_pins mem_smc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins mem_smc/M00_AXI] \
    [get_bd_intf_pins ps_0/S_AXI_HPC0_FPD]
connect_bd_intf_net [get_bd_intf_pins dma_0/M_AXIS_MM2S] \
    [get_bd_intf_pins loopback_0/s_axis]
connect_bd_intf_net [get_bd_intf_pins loopback_0/m_axis] \
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
    [get_bd_pins loopback_0/aclk] \
    [get_bd_pins rst_0/slowest_sync_clk]
connect_bd_net [get_bd_pins ps_0/pl_resetn0] \
    [get_bd_pins rst_0/ext_reset_in]
connect_bd_net [get_bd_pins locked_1/dout] \
    [get_bd_pins rst_0/dcm_locked]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] \
    [get_bd_pins dma_0/axi_resetn] \
    [get_bd_pins ctrl_smc/aresetn] \
    [get_bd_pins mem_smc/aresetn] \
    [get_bd_pins loopback_0/aresetn]

assign_bd_address
validate_bd_design
save_bd_design
set bd_file [get_files ps_dma_loopback.bd]
generate_target all $bd_file
set wrapper [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper
set_property top ps_dma_loopback_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1
puts "RK_PS_DMA_LOOPBACK_PROJECT_READY=[file join $project_dir ${project_name}.xpr]"
puts "RK_PS_DMA_LOOPBACK_BUILD_SCOPE=PROJECT_AND_OUTPUT_PRODUCTS_ONLY"
close_project
