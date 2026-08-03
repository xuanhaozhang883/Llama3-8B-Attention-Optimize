# Place-and-route a standalone Softmax synthesis checkpoint.
# Usage:
#   vivado -mode batch -source scripts/implement_softmax_ooc.tcl -tclargs \
#       <synth_checkpoint> <output_dir>

if {$argc != 2} {
    error "Usage: implement_softmax_ooc.tcl <synth_checkpoint> <output_dir>"
}

set synth_checkpoint [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
if {![file isfile $synth_checkpoint]} {
    error "Synthesis checkpoint not found: $synth_checkpoint"
}

file mkdir $output_dir
set_param general.maxThreads 8
open_checkpoint $synth_checkpoint
opt_design
place_design
phys_opt_design
route_design

report_utilization -file [file join $output_dir utilization_route.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -max_paths 20 -file [file join $output_dir timing_summary_route.rpt]
report_drc -file [file join $output_dir drc_route.rpt]
write_checkpoint -force [file join $output_dir softmax_route.dcp]

set worst_path [get_timing_paths -delay_type max -max_paths 1]
if {[llength $worst_path] == 0} {
    error "No maximum-delay timing path was reported"
}
set wns [get_property SLACK $worst_path]
puts "SOFTMAX_OOC_IMPLEMENTATION=PASS"
puts "ROUTE_WNS_NS=$wns"
puts "OUTPUT_DIR=$output_dir"
