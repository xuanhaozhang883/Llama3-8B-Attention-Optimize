set script_dir [file normalize [file dirname [info script]]]
set root_dir [file normalize [file join $script_dir ..]]
set project_dir [file join $root_dir vivado_v25_pingpong_unit]

catch {close_sim}
if {[llength [get_projects -quiet]] > 0} {
    close_project
}

create_project v25_pingpong_unit $project_dir \
    -part xczu15eg-ffvb1156-2-i -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -norecurse [list \
    [file join $root_dir rtl core a attention_group_pingpong_controller.sv] \
    [file join $root_dir rtl core a pv_tile2_to_tile4_pingpong_adapter.sv] \
    [file join $root_dir tb tb_v25_pingpong_integration.sv]]

set_property top tb_v25_pingpong_integration [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation
run all
close_sim



set log_file [file join $project_dir \
    v25_pingpong_unit.sim sim_1 behav xsim simulate.log]
if {![file isfile $log_file]} {
    error "Simulation log was not generated: $log_file"
}
set fh [open $log_file r]
set log_text [read $fh]
close $fh

if {[string first "V25_PINGPONG_INTEGRATION_TEST: PASS" $log_text] < 0} {
    error "v2.5 Ping-Pong unit simulation did not report PASS"
}

puts "============================================================"
puts {[PASS] v2.5 Ping-Pong unit simulation passed}
puts "Log: $log_file"
puts "============================================================"

close_project
exit 0
