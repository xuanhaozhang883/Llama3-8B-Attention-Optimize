if {$argc < 3} {
    error "usage: collect_qk_multilane_ooc.tcl <project_path> <report_root> <qk_lanes>"
}

set project_path [file normalize [lindex $argv 0]]
set report_root [file normalize [lindex $argv 1]]
set qk_lanes [lindex $argv 2]
file mkdir $report_root

open_project $project_path
open_run synth_1

report_utilization -hierarchical -file \
    [file join $report_root utilization_hierarchical.rpt]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
    -file [file join $report_root timing_summary.rpt]
report_methodology -file [file join $report_root methodology.rpt]

set timing_path [get_timing_paths -delay_type max -max_paths 1 -quiet]
set wns "NA"
if {[llength $timing_path] > 0} {
    set wns [get_property SLACK [lindex $timing_path 0]]
}
set summary [open [file join $report_root summary.txt] w]
puts $summary "vivado=[version -short]"
puts $summary "part=[get_property PART [current_project]]"
puts $summary "qk_lanes=$qk_lanes"
puts $summary "target_mhz=150"
puts $summary "wns_ns=$wns"
close $summary

puts "QK_MULTILANE_OOC_REPORT_PASS lanes=$qk_lanes wns_ns=$wns"
close_project
