if {$argc < 2} {
    error "usage: report_v31_route_status.tcl <post_route.dcp> <report.rpt>"
}
set checkpoint [file normalize [lindex $argv 0]]
set report_file [file normalize [lindex $argv 1]]
if {![file isfile $checkpoint]} {
    error "post-route checkpoint not found: $checkpoint"
}
file mkdir [file dirname $report_file]
open_checkpoint $checkpoint
report_route_status -file $report_file
puts "\[PASS\] Route-status report: $report_file"
close_design
