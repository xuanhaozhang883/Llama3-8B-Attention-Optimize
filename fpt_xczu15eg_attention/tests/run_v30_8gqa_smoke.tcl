# Standalone Vivado XSim regression for the added S8/D8 8-GQA testbench.
# Source this script from Vivado Tcl Console. It does not edit design sources.

set gate_script [file normalize [info script]]
set gate_tests  [file dirname $gate_script]
set gate_root   [file normalize [file join $gate_tests ..]]

if {[info exists ::env(FPT_V30_8GQA_BUILD_ROOT)] &&
    [string trim $::env(FPT_V30_8GQA_BUILD_ROOT)] ne ""} {
    set gate_build [file normalize $::env(FPT_V30_8GQA_BUILD_ROOT)]
} else {
    set gate_build [file normalize [file join $gate_root build rtl_gates v30_8gqa]]
}
file mkdir $gate_build

set gate_project_dir [file join $gate_build v30_8gqa_xsim]
create_project -force v30_8gqa_xsim $gate_project_dir \
    -part xczu15eg-ffvb1156-2-i
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

proc gate_collect_hdl {directory} {
    set files {}
    foreach item [glob -nocomplain -directory $directory *] {
        if {[file isdirectory $item]} {
            set files [concat $files [gate_collect_hdl $item]]
        } elseif {[regexp -nocase {\.(v|sv)$} $item]} {
            lappend files [file normalize $item]
        }
    }
    return $files
}

set gate_design [gate_collect_hdl [file join $gate_root rtl core]]
set gate_sim [list \
    [file join $gate_root tb sim_models floating_point_behavioral.sv] \
    [file join $gate_root tb tb_v30_online_attention_system_8gqa.sv]]
set gate_mem [list \
    [file join $gate_root mem exp_lut_q15.mem] \
    [file join $gate_root mem sin_bf16.hex] \
    [file join $gate_root mem cos_bf16.hex]]

foreach gate_file [concat $gate_design $gate_sim $gate_mem] {
    if {![file isfile $gate_file]} {
        error "Missing 8-GQA regression input: $gate_file"
    }
}

add_files -fileset sim_1 -norecurse $gate_design
add_files -fileset sim_1 -norecurse $gate_sim
add_files -fileset sim_1 -norecurse $gate_mem
foreach gate_file $gate_mem {
    set_property file_type {Memory Initialization Files} [get_files $gate_file]
}

set_property top tb_v30_online_attention_system_8gqa [get_filesets sim_1]
set_property verilog_define {V30_XSIM} [get_filesets sim_1]
update_compile_order -fileset sim_1

set gate_marker [file join $gate_project_dir \
    v30_8gqa_xsim.sim sim_1 behav xsim v30_8gqa_xsim_pass.txt]
if {[file exists $gate_marker]} {
    file delete -force $gate_marker
}

launch_simulation
run all
close_sim

if {![file isfile $gate_marker]} {
    error "8-GQA XSim regression did not publish its SIM_PASS marker"
}

set gate_summary [file join $gate_build V30_8GQA_XSIM_PASS.txt]
set gate_out [open $gate_summary w]
puts $gate_out "V3.0 8-GQA S8/D8 end-to-end: SIM_PASS"
puts $gate_out "Vivado: [version -short]"
puts $gate_out "Part: xczu15eg-ffvb1156-2-i"
puts $gate_out "Groups: 8; Q heads/group: 4; sequence: 8; dimension: 8"
puts $gate_out "Board execution: NOT_RUN"
close $gate_out

puts "============================================================"
puts {[PASS] V3.0 8-GQA END-TO-END XSIM}
puts "Evidence: $gate_summary"
puts "Project : [file join $gate_project_dir v30_8gqa_xsim.xpr]"
puts "============================================================"
close_project
