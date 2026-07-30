# Corrected A + B+C v5 TILE2 + real TILE4 PV simulation.
#
# Expected sibling directories:
#   <parent>/
#     A_attention_with_real_pv_v2_corrected/
#     FPT_BC_QK_Softmax_PV_Delivery_v5/
#     PV_module/
#
# Run:
#   cd <A_attention_with_real_pv_v2_corrected>
#   source scripts/run_vivado_attention_with_pv_smoke.tcl

set a_root [file normalize [file join [file dirname [info script]] ..]]

if {[info exists argv] && [llength $argv] >= 2} {
    set bc_root [file normalize [lindex $argv 0]]
    set pv_root [file normalize [lindex $argv 1]]
} else {
    set bc_root [file normalize \
        [file join $a_root .. FPT_BC_QK_Softmax_PV_Delivery_v5]]
    set pv_root [file normalize \
        [file join $a_root .. PV_module]]
}

if {![file exists \
    [file join $bc_root rtl integration qk_softmax_pv_pipeline_top.sv]]} {
    error "B+C v5 root is wrong: $bc_root"
}

if {![file exists \
    [file join $pv_root rtl pv_systolic_gqa_top.sv]]} {
    error "PV module root is wrong: $pv_root"
}

set project_dir [file join $a_root vivado_attention_with_pv_smoke]
set part_name "xc7a35tcpg236-1"

catch {close_sim}
if {[llength [get_projects -quiet]] > 0} {
    close_project
}

create_project fpt_attention_with_real_pv_corrected $project_dir \
    -part $part_name -force

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set a_rtl [list \
    [file join $a_root rtl top attention_with_pv_config_guard.sv] \
    [file join $a_root rtl controller attention_group_pv_controller.sv] \
    [file join $a_root rtl adapter pv_tile2_to_tile4_buffer_adapter.sv] \
    [file join $a_root rtl top attention_system_with_pv_top.sv]]

set bc_rtl [concat \
    [glob -nocomplain [file join $bc_root rtl adapter *.sv]] \
    [glob -nocomplain [file join $bc_root rtl softmax *.sv]] \
    [glob -nocomplain [file join $bc_root rtl qk *.sv]] \
    [glob -nocomplain [file join $bc_root rtl qk *.v]] \
    [glob -nocomplain [file join $bc_root rtl backend *.sv]] \
    [glob -nocomplain [file join $bc_root rtl integration *.sv]]]

set pv_rtl [concat \
    [glob -nocomplain [file join $pv_root rtl *.sv]] \
    [glob -nocomplain [file join $pv_root rtl *.v]]]

foreach file_name [concat $a_rtl $bc_rtl $pv_rtl] {
    if {![file exists $file_name]} {
        error "Required Design Source missing: $file_name"
    }
}

add_files -norecurse [concat $a_rtl $bc_rtl $pv_rtl]

set sim_files [list \
    [file join $a_root tb tb_attention_system_with_pv_small.sv] \
    [file join $bc_root sim_models floating_point_behavioral.sv] \
    [file join $bc_root rtl softmax exp_lut_q15.mem]]

foreach file_name $sim_files {
    if {![file exists $file_name]} {
        error "Required Simulation Source missing: $file_name"
    }
}

add_files -fileset sim_1 -norecurse $sim_files

set_property file_type SystemVerilog [get_files -quiet *.sv]
set_property file_type {Memory Initialization Files} \
    [get_files -quiet *exp_lut_q15.mem]

set_property top tb_attention_system_with_pv_small \
    [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "============================================================"
puts "CORRECTED A + B+C TILE2 + REAL TILE4 PV TEST"
puts "A root : $a_root"
puts "BC root: $bc_root"
puts "PV root: $pv_root"
puts "Config : QK_TILE=4 BC_PV_TILE=2 REAL_PV_TILE=4"
puts "Small  : SEQ_LEN=4 HEAD_DIM=4 GROUPS=8"
puts "============================================================"

launch_simulation -simset sim_1 -mode behavioral
run all

puts "============================================================"
puts "Simulation ended."
puts {Required final line: [PASS] Corrected A+B+C+real-PV full-path smoke test}
puts "There must be no FATAL, protocol_error, or TIMEOUT."
puts "============================================================"
