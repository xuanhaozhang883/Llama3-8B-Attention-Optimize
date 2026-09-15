# Validate an already-routed A3 OOC checkpoint without repeating implementation.
# Usage: vivado -mode batch -source <this-file> -tclargs <route-dcp> <output-dir>
if {$argc != 2} {
    error "expected <route-dcp> <output-dir>"
}

set route_dcp [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
if {![file isfile $route_dcp]} {
    error "routed checkpoint does not exist: $route_dcp"
}
file mkdir $output_dir

open_checkpoint $route_dcp
report_timing_summary -delay_type min_max -max_paths 20 -report_unconstrained \
    -file [file join $output_dir timing_summary.rpt]
report_route_status -file [file join $output_dir route_status.rpt]
report_drc -file [file join $output_dir drc.rpt]
set check_report [check_timing -verbose -return_string]
set check_handle [open [file join $output_dir check_timing.rpt] w]
puts $check_handle $check_report
close $check_handle

foreach required_zero_check {
    no_clock constant_clock pulse_width_clock unconstrained_internal_endpoints
    multiple_clock generated_clocks loops partial_input_delay
    partial_output_delay latch_loops
} {
    if {![regexp -nocase -- "checking\\s+$required_zero_check\\s+\\(0\\)" $check_report]} {
        error "CATS_R4_A3_VALIDATE: check_timing $required_zero_check is missing or nonzero"
    }
}

set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $drc_errors] != 0} {
    error "CATS_R4_A3_VALIDATE: [llength $drc_errors] DRC errors"
}
set unrouted_nets [get_nets -hierarchical -quiet -filter {ROUTE_STATUS == UNROUTED}]
set partial_nets [get_nets -hierarchical -quiet -filter {ROUTE_STATUS == PARTIALLY_ROUTED}]
if {[llength $unrouted_nets] != 0 || [llength $partial_nets] != 0} {
    error "CATS_R4_A3_VALIDATE: unrouted=[llength $unrouted_nets] partially_routed=[llength $partial_nets]"
}

set worst_path [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
if {$worst_path eq ""} {
    error "CATS_R4_A3_VALIDATE: no constrained timing path"
}
set worst_slack [get_property SLACK $worst_path]
set failing_paths [get_timing_paths -delay_type max -slack_lesser_than 0.0 -max_paths 100000]
set total_negative_slack 0.0
foreach path $failing_paths {
    set total_negative_slack [expr {$total_negative_slack + [get_property SLACK $path]}]
}
if {$worst_slack < 0.0} {
    error "CATS_R4_A3_VALIDATE: negative routed WNS=$worst_slack"
}

set worst_hold_path [lindex [get_timing_paths -delay_type min -max_paths 1] 0]
if {$worst_hold_path eq ""} {
    error "CATS_R4_A3_VALIDATE: no constrained hold timing path"
}
set worst_hold_slack [get_property SLACK $worst_hold_path]
set failing_hold_paths [get_timing_paths -delay_type min -slack_lesser_than 0.0 -max_paths 100000]
set total_hold_slack 0.0
foreach path $failing_hold_paths {
    set total_hold_slack [expr {$total_hold_slack + [get_property SLACK $path]}]
}
if {$worst_hold_slack < 0.0} {
    error "CATS_R4_A3_VALIDATE: negative routed WHS=$worst_hold_slack"
}

puts "CATS_R4_A3_REALIP_OOC_WNS=$worst_slack"
puts "CATS_R4_A3_REALIP_OOC_TNS=$total_negative_slack"
puts "CATS_R4_A3_REALIP_OOC_WHS=$worst_hold_slack"
puts "CATS_R4_A3_REALIP_OOC_THS=$total_hold_slack"
puts "CATS_R4_A3_REALIP_OOC_ROUTE_COMPLETE=1"
puts "CATS_R4_A3_REALIP_OOC_DRC_COMPLETE=1"
puts "CATS_R4_A3_REALIP_OOC_PASS"
close_design
