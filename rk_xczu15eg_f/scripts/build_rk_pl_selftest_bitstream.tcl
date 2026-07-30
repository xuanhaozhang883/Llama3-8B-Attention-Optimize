set script_dir [file normalize [file dirname [info script]]]
set rk_root [file normalize [file join $script_dir ..]]
set project_name rk_pl_selftest
set top_name rk_xczu15eg_f_attention_selftest_top
set project_file \
    [file join $rk_root vx ${project_name}.xpr]
set synth_report_dir [file join $rk_root reports 11_rk_pl_selftest_synth]
set impl_report_dir [file join $rk_root reports 12_rk_pl_selftest_bitstream]
set bit_report_dir $impl_report_dir
set artifact_dir [file join $rk_root artifacts]
foreach path [list $synth_report_dir $impl_report_dir \
                   $bit_report_dir $artifact_dir] {
    file mkdir $path
}

if {![file isfile $project_file]} {
    error "Create the RK project first: $project_file"
}
open_project $project_file
set_property top $top_name [get_filesets sources_1]
set board_xdc [get_files -quiet *rk_xczu15eg_f_pl_clock.xdc]
if {[llength $board_xdc] != 1} {
    error "Expected one RK board XDC in the project"
}
# Package pins and I/O standard are implementation-only. Keeping this XDC
# outside synthesis also permits a pin-property correction to reuse a proven
# synthesis DCP when RK_REUSE_SYNTH=1.
set_property used_in_synthesis false $board_xdc
update_compile_order -fileset sources_1

set reuse_synth [expr {
    [info exists ::env(RK_REUSE_SYNTH)] &&
    $::env(RK_REUSE_SYNTH) eq "1"
}]
if {$reuse_synth} {
    puts "RK_REUSE_SYNTH=1"
} else {
    reset_run synth_1
    launch_runs synth_1 -jobs 8
    wait_on_run synth_1
}
set synth_status [get_property STATUS [get_runs synth_1]]
puts "RK_SYNTH_STATUS=$synth_status"
set synth_dcp [file join \
    [get_property DIRECTORY [get_runs synth_1]] ${top_name}.dcp]
set reusable_synth [expr {
    $reuse_synth &&
    [file isfile $synth_dcp] &&
    ($synth_status eq "Out-of-date")
}]
if {![string match "synth_design Complete*" $synth_status] &&
    !$reusable_synth} {
    error "RK synthesis failed: $synth_status"
}
if {!$reusable_synth} {
    set synth_result_status $synth_status
    open_run synth_1
    report_utilization -file \
        [file join $synth_report_dir post_synth_utilization.rpt]
    report_timing_summary -file \
        [file join $synth_report_dir post_synth_timing_summary.rpt]
    report_clock_utilization -file \
        [file join $synth_report_dir post_synth_clock_utilization.rpt]
    close_design
} else {
    set synth_result_status \
        "synth_design Complete! (reused proven DCP after implementation-only XDC correction)"
    puts "RK_REUSING_SYNTH_DCP=$synth_dcp"
}

reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set impl_status [get_property STATUS [get_runs impl_1]]
puts "RK_IMPL_STATUS=$impl_status"
if {![string match "write_bitstream Complete*" $impl_status]} {
    error "RK implementation/bitstream failed: $impl_status"
}
open_run impl_1

report_utilization -file \
    [file join $impl_report_dir post_route_utilization.rpt]
report_timing_summary -file \
    [file join $impl_report_dir post_route_timing_summary.rpt]
report_drc -file \
    [file join $impl_report_dir post_route_drc.rpt]
report_clock_interaction -file \
    [file join $impl_report_dir post_route_clock_interaction.rpt]
report_power -file \
    [file join $impl_report_dir post_route_power.rpt]
check_timing -verbose -file \
    [file join $impl_report_dir post_route_check_timing.rpt]
report_cdc -details -file \
    [file join $impl_report_dir post_route_cdc.rpt]
report_route_status -file \
    [file join $impl_report_dir post_route_status.rpt]
report_bus_skew -warn_on_violation -file \
    [file join $impl_report_dir post_route_bus_skew.rpt]

set setup_paths [get_timing_paths -quiet -max_paths 1 -nworst 1 -setup]
if {[llength $setup_paths] > 0} {
    set wns [get_property SLACK [lindex $setup_paths 0]]
} else {
    set wns "N/A"
}
set hold_paths [get_timing_paths -quiet -max_paths 1 -nworst 1 -hold]
if {[llength $hold_paths] > 0} {
    set whs [get_property SLACK [lindex $hold_paths 0]]
} else {
    set whs "N/A"
}

set impl_dir [get_property DIRECTORY [get_runs impl_1]]
set generated_bit [file join $impl_dir ${top_name}.bit]
if {![file isfile $generated_bit]} {
    error "Bitstream was not created at expected path: $generated_bit"
}
set stable_bit \
    [file join $artifact_dir rk_xczu15eg_f_pl_selftest.bit]
set stable_ltx \
    [file join $artifact_dir rk_xczu15eg_f_pl_selftest.ltx]
file copy -force $generated_bit $stable_bit
write_debug_probes -force $stable_ltx
write_checkpoint -force \
    [file join $bit_report_dir rk_xczu15eg_f_single_gqa_post_route.dcp]

set fh [open [file join $bit_report_dir status.json] w]
puts $fh "{"
puts $fh "  \"stage\": \"synthesis_implementation_bitstream\","
puts $fh "  \"status\": \"PASS\","
puts $fh "  \"synthesis_status\": \"$synth_result_status\","
puts $fh "  \"implementation_status\": \"$impl_status\","
puts $fh "  \"setup_wns_ns\": \"$wns\","
puts $fh "  \"hold_whs_ns\": \"$whs\","
puts $fh "  \"bitstream\": \"rk_xczu15eg_f/artifacts/rk_xczu15eg_f_pl_selftest.bit\","
puts $fh "  \"debug_probes\": \"rk_xczu15eg_f/artifacts/rk_xczu15eg_f_pl_selftest.ltx\","
puts $fh "  \"write_bitstream_license_gate\": \"CLEARED\""
puts $fh "}"
close $fh

puts "RK_BITSTREAM_PASS"
puts "RK_SETUP_WNS_NS=$wns"
puts "RK_HOLD_WHS_NS=$whs"
puts "RK_XPR=$project_file"
puts "RK_BIT=$stable_bit"
puts "RK_LTX=$stable_ltx"
close_project
