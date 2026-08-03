# Out-of-context synthesis for the Stage 2A online row update kernel.

set script_path [file normalize [info script]]
set project_root [file normalize [file join [file dirname $script_path] ..]]

if {[info exists ::env(FPT_V32_STAGE2A_BUILD_ROOT)] &&
    [string trim $::env(FPT_V32_STAGE2A_BUILD_ROOT)] ne ""} {
    set build_root [file normalize $::env(FPT_V32_STAGE2A_BUILD_ROOT)]
} else {
    set build_root [file normalize [file join \
        [file dirname $project_root] _fpt_v32_stage2a_ooc]]
}
file mkdir $build_root

set exp_lut_rtl [file join $project_root rtl core flash \
    flash_exp_approx_q23.sv]
set update_rtl [file join $project_root rtl core flash \
    flash_online_row_update.sv]
set lut_file [file join $project_root mem exp_lut_q23.mem]

foreach source_file [list $exp_lut_rtl $update_rtl $lut_file] {
    if {![file isfile $source_file]} {
        error "Missing Stage 2A OOC input: $source_file"
    }
}

set original_dir [pwd]
cd $project_root
create_project -in_memory -part xczu15eg-ffvb1156-2-i
set_property target_language Verilog [current_project]
set_msg_config -id {Synth 8-2898} -new_severity ERROR
set_msg_config -id {Synth 8-3848} -new_severity ERROR
read_verilog -sv [list $exp_lut_rtl $update_rtl]
synth_design -mode out_of_context -top flash_online_row_update \
    -part xczu15eg-ffvb1156-2-i

create_clock -name online_row_clk -period 6.667 [get_ports clk]
report_utilization -hierarchical -file \
    [file join $build_root online_row_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -max_paths 20 -file \
    [file join $build_root online_row_timing_summary.rpt]
set worst_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
if {[llength $worst_paths] == 0} {
    error "No constrained setup path was found for Stage 2A"
}
set worst_slack [get_property SLACK [lindex $worst_paths 0]]
if {$worst_slack < 0.0} {
    error "Stage 2A misses the 150 MHz target: WNS=$worst_slack ns"
}
write_checkpoint -force \
    [file join $build_root online_row_update_synth.dcp]

puts "============================================================"
puts {[PASS] V3.2 Online Row Update OOC synthesis completed}
puts "Vivado : [version -short]"
puts "Output : $build_root"
puts "WNS    : $worst_slack ns at 150 MHz"
puts "Reports: online_row_utilization.rpt, online_row_timing_summary.rpt"
puts "============================================================"
close_project
cd $original_dir
