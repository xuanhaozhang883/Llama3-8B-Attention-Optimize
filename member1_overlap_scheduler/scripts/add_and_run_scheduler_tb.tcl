# Run this script from the Tcl Console of an already opened Vivado project:
#
#   source D:/path/to/member1_overlap_scheduler/scripts/add_and_run_scheduler_tb.tcl
#
# The script adds only the standalone scheduler and its simulation testbench.
# It does not modify the synthesis top of the existing Attention project.

set script_dir [file dirname [file normalize [info script]]]
set pkg_dir    [file normalize [file join $script_dir ..]]

set rtl_file [file join $pkg_dir rtl gqa_overlap_scheduler.sv]
set tb_file  [file join $pkg_dir tb  tb_gqa_overlap_scheduler.sv]

if {![file exists $rtl_file]} {
    error "Missing RTL file: $rtl_file"
}

if {![file exists $tb_file]} {
    error "Missing testbench file: $tb_file"
}

if {[llength [get_files -quiet $rtl_file]] == 0} {
    add_files -fileset sources_1 -norecurse $rtl_file
}

if {[llength [get_files -quiet $tb_file]] == 0} {
    add_files -fileset sim_1 -norecurse $tb_file
}

set_property file_type SystemVerilog [get_files $rtl_file]
set_property file_type SystemVerilog [get_files $tb_file]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set_property top tb_gqa_overlap_scheduler [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]

launch_simulation
run all
