# A3 routed out-of-context implementation.  The invoking runner supplies all
# paths so generated projects and reports remain outside the Git worktree.
foreach required_var {
    a3_project_dir a3_part a3_top a3_clock_period a3_xdc a3_exp_lut_file a3_rtl_files
    a3_xci_files a3_synth_dcp a3_route_dcp a3_synth_utilization
    a3_synth_timing a3_utilization a3_timing a3_critical_paths
    a3_route_status a3_drc a3_methodology a3_power
    a3_check_timing
} {
    if {![info exists $required_var]} {
        error "A3 OOC missing required variable: $required_var"
    }
}

create_project a3_realip_ooc $a3_project_dir -part $a3_part -force
foreach xci $a3_xci_files { read_ip $xci }
generate_target all [get_ips floating_point_0 floating_point_1 floating_point_2]
set_property source_mgmt_mode None [current_project]
foreach rtl_file $a3_rtl_files {
    if {[string match "*.sv" $rtl_file]} {
        read_verilog -sv $rtl_file
    } else {
        read_verilog $rtl_file
    }
}
read_xdc $a3_xdc
set_property top $a3_top [current_fileset]
synth_design -mode out_of_context -flatten_hierarchy none \
    -generic "EXP_LUT_FILE=$a3_exp_lut_file" -top $a3_top -part $a3_part
write_checkpoint -force $a3_synth_dcp
report_utilization -hierarchical -file $a3_synth_utilization
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
    -file $a3_synth_timing

set synth_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $synth_paths] == 0} {
    error "CATS_R4_A3_OOC: synthesis returned no constrained timing path"
}

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $a3_route_dcp
report_utilization -hierarchical -file $a3_utilization
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
    -file $a3_timing
report_timing -delay_type max -max_paths 20 -file $a3_critical_paths
report_route_status -file $a3_route_status
report_drc -file $a3_drc
report_methodology -file $a3_methodology
report_power -file $a3_power
check_timing -verbose -file $a3_check_timing

set no_clock_registers [all_registers -no_clock]
if {[llength $no_clock_registers] != 0} {
    error "CATS_R4_A3_OOC: [llength $no_clock_registers] internal registers have no clock"
}
set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $drc_errors] != 0} {
    error "CATS_R4_A3_OOC: [llength $drc_errors] DRC errors"
}

set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $timing_paths] == 0} {
    error "CATS_R4_A3_OOC: routed design returned no constrained timing path"
}
set worst_path [lindex $timing_paths 0]
set worst_slack [get_property SLACK $worst_path]
set total_negative_slack 0.0
foreach failing_path [get_timing_paths -delay_type max -slack_lesser_than 0.0 -max_paths 100000] {
    set total_negative_slack [expr {$total_negative_slack + [get_property SLACK $failing_path]}]
}
puts "CATS_R4_A3_REALIP_OOC_WNS=$worst_slack"
puts "CATS_R4_A3_REALIP_OOC_TNS=$total_negative_slack"
if {$worst_slack < 0.0} {
    error "CATS_R4_A3_OOC: negative routed WNS=$worst_slack"
}
set route_report [report_route_status -return_string]
if {![regexp -nocase {fully routed|routing is complete} $route_report]} {
    error "CATS_R4_A3_OOC: route-status report does not confirm complete routing"
}
puts "CATS_R4_A3_REALIP_OOC_ROUTE_COMPLETE=1"
puts "CATS_R4_A3_REALIP_OOC_PASS"
close_project
