# Vivado XSim qualification for the v3.0 fused Online Softmax + Context core.
# Source this file from the Vivado GUI Tcl Console, or pass it to Vivado with
# `-mode batch -source`. Generated files stay outside the source tree by
# default.

set v30_script [file normalize [info script]]
set v30_tests  [file dirname $v30_script]
set v30_root   [file normalize [file join $v30_tests ..]]
set v30_repo   [file normalize [file join $v30_root ..]]

if {[info exists ::env(FPT_V30_BUILD_ROOT)] &&
    [string trim $::env(FPT_V30_BUILD_ROOT)] ne ""} {
    set v30_build [file normalize $::env(FPT_V30_BUILD_ROOT)]
} else {
    set v30_build [file normalize [file join $v30_root build rtl_gates v30_online]]
}
file mkdir $v30_build

set v30_project_dir [file join $v30_build v30_xsim]
create_project -force v30_online_xsim $v30_project_dir \
    -part xczu15eg-ffvb1156-2-i
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

proc v30_collect_hdl {directory} {
    set files {}
    foreach item [glob -nocomplain -directory $directory *] {
        if {[file isdirectory $item]} {
            set files [concat $files [v30_collect_hdl $item]]
        } elseif {[regexp -nocase {\.(v|sv)$} $item]} {
            lappend files [file normalize $item]
        }
    }
    return $files
}
set v30_design [v30_collect_hdl [file join $v30_root rtl core]]
set v30_sim [list \
    [file join $v30_root tb sim_models floating_point_behavioral.sv] \
    [file join $v30_root tb tb_v30_online_softmax_context.sv] \
    [file join $v30_root tb tb_v30_online_attention_system.sv]]
set v30_mem [list \
    [file join $v30_root mem exp_lut_q15.mem] \
    [file join $v30_root mem sin_bf16.hex] \
    [file join $v30_root mem cos_bf16.hex] \
    [file join $v30_root tests data v30_online_scores_s8.hex] \
    [file join $v30_root tests data v30_online_v_s8.hex] \
    [file join $v30_root tests data v30_online_context_s8.hex]]

foreach v30_file [concat $v30_design $v30_sim $v30_mem] {
    if {![file isfile $v30_file]} { error "Missing v3.0 test input: $v30_file" }
}
add_files -fileset sim_1 -norecurse $v30_design
add_files -fileset sim_1 -norecurse $v30_sim
add_files -fileset sim_1 -norecurse $v30_mem
foreach v30_file $v30_mem {
    set_property file_type {Memory Initialization Files} [get_files $v30_file]
}

set_property top tb_v30_online_softmax_context [get_filesets sim_1]
set_property verilog_define {V30_XSIM} [get_filesets sim_1]
update_compile_order -fileset sim_1

set v30_marker_glob [file join $v30_project_dir \
    v30_online_xsim.sim sim_1 behav xsim v30_xsim_pass.txt]
set v30_e2e_marker [file join $v30_project_dir \
    v30_online_xsim.sim sim_1 behav xsim v30_e2e_xsim_pass.txt]
if {[file exists $v30_marker_glob]} { file delete -force $v30_marker_glob }
if {[file exists $v30_e2e_marker]} { file delete -force $v30_e2e_marker }

launch_simulation
run all
close_sim

if {![file isfile $v30_marker_glob]} {
    error "v3.0 XSim regression did not publish its SIM_PASS marker"
}

set_property top tb_v30_online_attention_system [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation
run all
close_sim
if {![file isfile $v30_e2e_marker]} {
    error "v3.0 end-to-end XSim regression did not publish SIM_PASS"
}

set v30_summary [file join $v30_build V30_ONLINE_XSIM_PASS.txt]
set v30_out [open $v30_summary w]
puts $v30_out "V3.0 Online Softmax + Context: SIM_PASS"
puts $v30_out "Vivado: [version -short]"
puts $v30_out "Part: xczu15eg-ffvb1156-2-i"
puts $v30_out "Coverage: fused-unit Golden + RoPE/QK/V-cache end-to-end"
puts $v30_out "Stress: causal skip, online rescale, random latency/backpressure"
puts $v30_out "Board execution: NOT_RUN"
close $v30_out

puts "============================================================"
puts {[PASS] V3.0 ONLINE SOFTMAX + STREAMING CONTEXT XSIM}
puts "Evidence: $v30_summary"
puts "Project : [file join $v30_project_dir v30_online_xsim.xpr]"
puts "============================================================"
close_project
