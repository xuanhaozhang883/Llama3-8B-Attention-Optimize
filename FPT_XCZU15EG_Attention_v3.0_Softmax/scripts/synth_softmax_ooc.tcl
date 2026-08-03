# Standalone Softmax synthesis helper. This does not alter the board project.
# Usage:
#   vivado -mode batch -source scripts/synth_softmax_ooc.tcl -tclargs \
#       <source_root> <output_dir> ?part?

if {$argc < 2 || $argc > 3} {
    error "Usage: synth_softmax_ooc.tcl <source_root> <output_dir> ?part?"
}

set source_root [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
set target_part "xc7a35tcsg324-1"
if {$argc == 3} {
    set target_part [lindex $argv 2]
}

set required_sources [list \
    [file join $source_root rtl core bc softmax exp_lut.sv] \
    [file join $source_root rtl core bc softmax unsigned_restoring_divider.sv] \
    [file join $source_root rtl core bc softmax softmax_bf16.sv]]
foreach source $required_sources {
    if {![file isfile $source]} {
        error "Missing Softmax source: $source"
    }
}
if {[llength [get_parts -quiet $target_part]] == 0} {
    error "Target part is not installed: $target_part"
}

file mkdir $output_dir
set_param general.maxThreads 8
read_verilog -sv $required_sources
synth_design -mode out_of_context -flatten_hierarchy rebuilt \
    -top softmax_bf16 -part $target_part
create_clock -name softmax_clk -period 6.666 [get_ports clk]

report_utilization -file [file join $output_dir utilization.rpt]
report_timing_summary -delay_type min_max -max_paths 10 \
    -file [file join $output_dir timing_summary.rpt]
write_checkpoint -force [file join $output_dir softmax_synth.dcp]

puts "SOFTMAX_OOC_SYNTHESIS=PASS"
puts "SOURCE_ROOT=$source_root"
puts "TARGET_PART=$target_part"
puts "OUTPUT_DIR=$output_dir"
