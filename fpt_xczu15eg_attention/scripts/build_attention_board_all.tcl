set script_dir [file normalize [file dirname [info script]]]
set board_root [file normalize [file join $script_dir ..]]
source [file join $script_dir project_config.tcl]
set project_file $fpt_project_file
if {![file isfile $project_file]} {
    source [file join $script_dir create_attention_board_project.tcl]
} else {
    if {[llength [get_projects -quiet]] > 0} { close_project }
    open_project $project_file
}

set jobs 8
if {[info exists argv] && [llength $argv] >= 1 &&
    [string is integer -strict [lindex $argv 0]]} {
    set jobs [lindex $argv 0]
}

reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
set synth_status [get_property STATUS [get_runs synth_1]]
if {![string match {*Complete*} $synth_status]} {
    error "Synthesis did not complete successfully: $synth_status"
}

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
if {![string match {*Complete*} $impl_status]} {
    error "Implementation/bitstream did not complete successfully: $impl_status"
}

set report_dir [file join $board_root reports]
set export_dir [file join $board_root export]
file mkdir $report_dir
file mkdir $export_dir

open_run impl_1
report_utilization -hierarchical -file [file join $report_dir utilization_impl.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir timing_summary_impl.rpt]
report_drc -file [file join $report_dir drc_impl.rpt]
report_power -file [file join $report_dir power_impl.rpt]

write_hw_platform -fixed -include_bit -force \
    [file join $export_dir $fpt_xsa_name]

set bit_candidates [glob -nocomplain \
    [file join $fpt_project_dir \
     ${fpt_project_name}.runs impl_1 *.bit]]
if {[llength $bit_candidates] != 1} {
    error "Expected exactly one bitstream, found [llength $bit_candidates]: $bit_candidates"
}
set bit_file [lindex $bit_candidates 0]
puts "============================================================"
puts {[PASS] Attention board bitstream and XSA generated}
puts "BIT : $bit_file"
puts "XSA : [file join $export_dir $fpt_xsa_name]"
puts "Reports: $report_dir"
puts "============================================================"
