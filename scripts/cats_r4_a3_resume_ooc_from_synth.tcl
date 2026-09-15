# Resume the A3 routed OOC implementation from a synthesized checkpoint.
# Usage: vivado -mode batch -source <this-file> -tclargs <synth-dcp> <output-dir>
if {$argc != 2} {
    error "expected <synth-dcp> <output-dir>"
}

set synth_dcp [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
if {![file isfile $synth_dcp]} {
    error "synthesis checkpoint does not exist: $synth_dcp"
}
file mkdir $output_dir

open_checkpoint $synth_dcp
set constrained_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $constrained_paths] == 0} {
    error "CATS_R4_A3_RESUME: checkpoint has no constrained timing path"
}

opt_design
place_design
phys_opt_design
route_design

set route_dcp [file join $output_dir cats_r4_a3_compute_cluster_ooc.dcp]
write_checkpoint -force $route_dcp
report_utilization -hierarchical -file [file join $output_dir utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
    -file [file join $output_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 20 \
    -file [file join $output_dir critical_paths.rpt]
report_route_status -file [file join $output_dir route_status.rpt]
report_drc -file [file join $output_dir drc.rpt]
report_methodology -file [file join $output_dir methodology.rpt]
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
        error "CATS_R4_A3_RESUME: check_timing $required_zero_check is missing or nonzero"
    }
}
set drc_errors [get_drc_violations -quiet -filter {SEVERITY == Error}]
if {[llength $drc_errors] != 0} {
    error "CATS_R4_A3_RESUME: [llength $drc_errors] DRC errors"
}
set unrouted_nets [get_nets -hierarchical -quiet -filter {ROUTE_STATUS == UNROUTED}]
set partial_nets [get_nets -hierarchical -quiet -filter {ROUTE_STATUS == PARTIALLY_ROUTED}]
if {[llength $unrouted_nets] != 0 || [llength $partial_nets] != 0} {
    error "CATS_R4_A3_RESUME: unrouted=[llength $unrouted_nets] partially_routed=[llength $partial_nets]"
}

set worst_path [lindex [get_timing_paths -delay_type max -max_paths 1] 0]
set worst_slack [get_property SLACK $worst_path]
set failing_paths [get_timing_paths -delay_type max -slack_lesser_than 0.0 -max_paths 100000]
set total_negative_slack 0.0
foreach path $failing_paths {
    set total_negative_slack [expr {$total_negative_slack + [get_property SLACK $path]}]
}
puts "CATS_R4_A3_RESUME_WNS=$worst_slack"
puts "CATS_R4_A3_RESUME_TNS=$total_negative_slack"
puts "CATS_R4_A3_RESUME_ROUTE_COMPLETE=1"
if {$worst_slack < 0.0} {
    error "CATS_R4_A3_RESUME: negative routed WNS=$worst_slack"
}
puts "CATS_R4_A3_RESUME_PASS"
close_design
