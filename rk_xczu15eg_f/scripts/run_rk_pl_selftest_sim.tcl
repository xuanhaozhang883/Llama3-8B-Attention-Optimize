set script_dir [file normalize [file dirname [info script]]]
set rk_root [file normalize [file join $script_dir ..]]
set project_name rk_pl_selftest
set project_file \
    [file join $rk_root vx ${project_name}.xpr]
set report_dir [file join $rk_root reports 10_rk_pl_selftest_sim]
file mkdir $report_dir

if {![file isfile $project_file]} {
    error "Create the RK project first: $project_file"
}
open_project $project_file
set xci_files [get_files -quiet *.xci]
if {[llength $xci_files] > 0} {
    set_property used_in_simulation false $xci_files
}
set_property top tb_rk_xczu15eg_f_attention_selftest \
    [get_filesets sim_1]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run all

set tb /tb_rk_xczu15eg_f_attention_selftest
set done_value [get_value [get_objects ${tb}/done]]
set pass_value [get_value [get_objects ${tb}/pass]]
set fail_value [get_value [get_objects ${tb}/fail]]
set errors_value [get_value -radix unsigned \
    [get_objects ${tb}/error_count]]
set first_error_value [get_value -radix unsigned \
    [get_objects ${tb}/first_error_index]]
set cycles_value [get_value -radix unsigned \
    [get_objects ${tb}/cycle_count]]

set sim_pass [expr {$done_value eq "1" &&
                    $pass_value eq "1" &&
                    $fail_value eq "0" &&
                    $errors_value eq "0" &&
                    $first_error_value eq "131071"}]
set fh [open [file join $report_dir status.json] w]
puts $fh "{"
puts $fh "  \"stage\": \"behavioral_simulation\","
puts $fh "  \"status\": \"[expr {$sim_pass ? {PASS} : {FAIL}}]\","
puts $fh "  \"done\": \"$done_value\","
puts $fh "  \"pass\": \"$pass_value\","
puts $fh "  \"fail\": \"$fail_value\","
puts $fh "  \"mismatch_count\": $errors_value,"
puts $fh "  \"first_error_index\": $first_error_value,"
puts $fh "  \"cycles\": $cycles_value,"
puts $fh "  \"restart_regression\": \"executed_twice_in_testbench\""
puts $fh "}"
close $fh

if {!$sim_pass} {
    error "RK self-test failed: done=$done_value pass=$pass_value fail=$fail_value errors=$errors_value first_error=$first_error_value"
}
puts "RK_SELFTEST_BEHAVIORAL_SIM_PASS"
puts "RK_SELFTEST_CYCLES=$cycles_value"
close_sim
close_project
