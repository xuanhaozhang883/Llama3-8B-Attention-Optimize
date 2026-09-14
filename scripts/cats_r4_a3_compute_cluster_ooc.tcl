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
set route_report [report_route_status -return_string]
set route_fh [open $a3_route_status w]
puts $route_fh $route_report
close $route_fh
proc a3_route_count {route_report label_pattern} {
    set count_pattern [format {(?im)^\s*#\s+of\s+%s[.\s]*:\s*([0-9]+)\s*:?\s*$} $label_pattern]
    if {![regexp -nocase -- $count_pattern $route_report -> count]} {
        error "CATS_R4_A3_OOC: route-status report is missing count: $label_pattern"
    }
    return $count
}
set routable_count [a3_route_count $route_report {routable\s+nets}]
set fully_routed_count [a3_route_count $route_report {fully\s+routed\s+nets}]
set routing_error_count [a3_route_count $route_report {nets\s+with\s+routing\s+errors}]
report_drc -file $a3_drc
report_methodology -file $a3_methodology
report_power -file $a3_power
set check_timing_report [check_timing -verbose -return_string]
set check_timing_fh [open $a3_check_timing w]
puts $check_timing_fh $check_timing_report
close $check_timing_fh

set no_clock_registers [all_registers -no_clock]
if {[llength $no_clock_registers] != 0} {
    error "CATS_R4_A3_OOC: [llength $no_clock_registers] internal registers have no clock"
}
set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $drc_errors] != 0} {
    error "CATS_R4_A3_OOC: [llength $drc_errors] DRC errors"
}
if {[regexp -nocase {checking\s+\S+\s+\([1-9][0-9]*\)} $check_timing_report]} {
    error "CATS_R4_A3_OOC: check_timing contains nonzero findings"
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
set unrouted_nets [get_nets -hierarchical -quiet -filter {ROUTE_STATUS == UNROUTED}]
set partial_nets [get_nets -hierarchical -quiet -filter {ROUTE_STATUS == PARTIALLY_ROUTED}]
if {[llength $unrouted_nets] != 0 || [llength $partial_nets] != 0} {
    error "CATS_R4_A3_OOC: unrouted=[llength $unrouted_nets] partially_routed=[llength $partial_nets]"
}
if {$routable_count != $fully_routed_count || $routing_error_count != 0} {
    error "CATS_R4_A3_OOC: route-status counts routable=$routable_count fully_routed=$fully_routed_count routing_errors=$routing_error_count"
}
puts "CATS_R4_A3_REALIP_OOC_ROUTE_COMPLETE=1"
if {$worst_slack < 0.0} {
    error "CATS_R4_A3_OOC: negative routed WNS=$worst_slack"
}
puts "CATS_R4_A3_REALIP_OOC_PASS"
close_project
