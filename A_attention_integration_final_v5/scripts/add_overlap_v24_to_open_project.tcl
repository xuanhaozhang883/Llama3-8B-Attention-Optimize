# Add corrected overlap-v24 RTL and unit TBs to the currently open Vivado
# project. Run this script after copying the package into
# A_attention_integration_final_v5.
#
# Tcl Console:
#   cd <repo>/A_attention_integration_final_v5
#   source scripts/add_overlap_v24_to_open_project.tcl

if {[llength [get_projects -quiet]] == 0} {
    error "No Vivado project is open. Open the working KV260 project first."
}

set script_dir [file dirname [info script]]
set a_root     [file dirname $script_dir]

set design_files [list \
    [file join $a_root rtl optimization_v24 \
        gqa_pingpong_buffer.sv] \
    [file join $a_root rtl optimization_v24 \
        gqa_overlap_scheduler.sv] \
    [file join $a_root rtl optimization_v24 \
        attention_overlap_perf_counters.sv] \
    [file join $a_root rtl top \
        attention_system_with_rope_pv_overlap_top.sv]]

set simulation_files [list \
    [file join $a_root tb optimization_v24 \
        tb_gqa_pingpong_buffer.sv] \
    [file join $a_root tb optimization_v24 \
        tb_gqa_overlap_scheduler.sv] \
    [file join $a_root tb optimization_v24 \
        tb_attention_overlap_perf_counters.sv]]

set missing_files [list]
foreach file_name [concat $design_files $simulation_files] {
    if {![file isfile $file_name]} {
        lappend missing_files $file_name
    }
}

if {[llength $missing_files] != 0} {
    puts "Missing corrected overlap files:"
    foreach file_name $missing_files {
        puts "  $file_name"
    }
    error "Corrected overlap-v24 installation is incomplete."
}

add_files -norecurse -fileset sources_1 $design_files
add_files -norecurse -fileset sim_1 $simulation_files

foreach file_name $design_files {
    set file_object [get_files -quiet $file_name]
    if {[llength $file_object] != 0} {
        set_property file_type SystemVerilog $file_object
    }
}

foreach file_name $simulation_files {
    set file_object [get_files -quiet $file_name]
    if {[llength $file_object] != 0} {
        set_property file_type SystemVerilog $file_object
    }
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "============================================================"
puts {[PASS] corrected overlap-v24 files added}
puts "The existing Design Top was intentionally not changed."
puts "OOC resource test top: attention_system_with_rope_pv_overlap_top"
puts "Board build top: keep the KV260 board wrapper that instantiates this core."
puts "Unit TBs are in sim_1; select one TB top before GUI simulation."
puts "For automatic tests, run:"
puts "  source scripts/run_vivado_overlap_unit_regression.tcl"
puts "For serial-vs-overlap full-chain comparison, run:"
puts "  source scripts/run_vivado_gqa_overlap_regression.tcl"
puts "============================================================"
