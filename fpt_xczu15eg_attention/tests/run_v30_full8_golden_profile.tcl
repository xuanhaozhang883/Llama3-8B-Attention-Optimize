# Full S128/D128, 8-GQA Golden/profile qualification in Vivado XSim.
set script_path [file normalize [info script]]
set tests_dir [file dirname $script_path]
set root [file normalize [file join $tests_dir ..]]
if {[info exists ::env(FPT_V30_PROFILE_BUILD_ROOT)] &&
    [string trim $::env(FPT_V30_PROFILE_BUILD_ROOT)] ne ""} {
    set build [file normalize $::env(FPT_V30_PROFILE_BUILD_ROOT)]
} else {
    set build [file normalize [file join $root build rtl_gates v30_full8_profile]]
}
file mkdir $build
set project_dir [file join $build v30_full8_profile_xsim]
create_project -force v30_full8_profile_xsim $project_dir \
    -part xczu15eg-ffvb1156-2-i
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

proc collect_hdl {directory} {
    set files {}
    foreach item [glob -nocomplain -directory $directory *] {
        if {[file isdirectory $item]} {
            set files [concat $files [collect_hdl $item]]
        } elseif {[regexp -nocase {\.(v|sv)$} $item]} {
            lappend files [file normalize $item]
        }
    }
    return $files
}
set design [collect_hdl [file join $root rtl core]]
set sim [list \
    [file join $root tb sim_models floating_point_behavioral.sv] \
    [file join $root tb tb_v30_full8_golden_profile.sv]]
set memory [list \
    [file join $root mem exp_lut_q15.mem] \
    [file join $root mem sin_bf16.hex] \
    [file join $root mem cos_bf16.hex] \
    [file join $root vitis data q_before_rope_bf16.hex] \
    [file join $root vitis data k_before_rope_bf16.hex] \
    [file join $root vitis data v_bf16.hex] \
    [file join $root vitis data attn_out_online_fused_bf16.hex]]
foreach item [concat $design $sim $memory] {
    if {![file isfile $item]} { error "Missing full8 input: $item" }
}
add_files -fileset sim_1 -norecurse $design
add_files -fileset sim_1 -norecurse $sim
add_files -fileset sim_1 -norecurse $memory
foreach item $memory {
    set_property file_type {Memory Initialization Files} [get_files $item]
}
set_property top tb_v30_full8_golden_profile [get_filesets sim_1]
set_property verilog_define {V30_XSIM} [get_filesets sim_1]
update_compile_order -fileset sim_1

set run_dir [file join $project_dir v30_full8_profile_xsim.sim sim_1 behav xsim]
set marker [file join $run_dir v30_full8_profile_pass.txt]
if {[file exists $marker]} { file delete -force $marker }
puts "Full-size XSim may take a long time. Output directory: $run_dir"
launch_simulation
run all
close_sim
if {![file isfile $marker]} {
    error "Full8 profile did not publish SIM_PASS; inspect xsim.log"
}
set summary [file join $build V30_FULL8_PROFILE_XSIM_PASS.txt]
set fd [open $summary w]
puts $fd "V3.0 FULL8 Golden + baseline profile: SIM_PASS"
puts $fd "Vivado: [version -short]"
puts $fd "Profile: [file join $run_dir v30_full8_profile.csv]"
puts $fd "Actual: [file join $run_dir v30_full8_actual_bf16.hex]"
puts $fd "Board execution: NOT_RUN"
close $fd
puts "============================================================"
puts {[PASS] V3.0 FULL8 GOLDEN + BASELINE PROFILE XSIM}
puts "Evidence: $summary"
puts "Profile : [file join $run_dir v30_full8_profile.csv]"
puts "Actual  : [file join $run_dir v30_full8_actual_bf16.hex]"
puts "============================================================"
close_project
