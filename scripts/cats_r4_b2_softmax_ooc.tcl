# Vivado 2025.2 OOC synthesis for the CATS-R4 B2 common V3 wrapper.
# Compatibility and Accuracy arithmetic arbitrate into one 3x128x32-bit
# scheme-A stager, as frozen by the shared-stager integration decision.
# This does not add the candidate to scripts/source_manifest.tcl.
# Usage:
#   vivado -mode batch -source scripts/cats_r4_b2_softmax_ooc.tcl \
#          -tclargs <source-root> <fresh-output-root> ?clock-period-ns?

if {($argc < 2) || ($argc > 3)} {
    error "expected <source-root> <fresh-output-root> ?clock-period-ns?"
}

set source_root [file normalize [lindex $argv 0]]
set output_root [file normalize [lindex $argv 1]]
set clock_period 6.666
if {$argc == 3} {
    set clock_period [lindex $argv 2]
}
if {[file exists $output_root]} {
    error "output root must be fresh: $output_root"
}

file mkdir $output_root
set generated_xdc [file join $output_root cats_r4_b2_softmax_ooc.xdc]
set xdc_handle [open $generated_xdc w]
puts $xdc_handle "create_clock -name core_clk -period $clock_period \[get_ports clk\]"
puts $xdc_handle {set_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports clk]}
puts $xdc_handle {set_input_delay -clock core_clk -max 1.000 [get_ports -filter {DIRECTION == IN && NAME != clk}]}
puts $xdc_handle {set_input_delay -clock core_clk -min 0.200 [get_ports -filter {DIRECTION == IN && NAME != clk}]}
puts $xdc_handle {set_output_delay -clock core_clk -max 1.000 [get_ports -filter {DIRECTION == OUT}]}
puts $xdc_handle {set_output_delay -clock core_clk -min -0.200 [get_ports -filter {DIRECTION == OUT}]}
close $xdc_handle

cd $source_root
read_verilog -sv [file join $source_root rtl core bc softmax exp_lut.sv]
read_verilog -sv [file join $source_root rtl core bc softmax unsigned_restoring_divider.sv]
read_verilog -sv [file join $source_root rtl core bc softmax \
    cats_r4_row_softmax_compatibility.sv]
read_verilog -sv [file join $source_root rtl core bc softmax \
    cats_r4_b2_compatibility_core_adapter.sv]
read_verilog -sv [file join $source_root rtl core bc softmax \
    cats_r4_accuracy_exp_fixed.sv]
read_verilog -sv [file join $source_root rtl core bc softmax \
    cats_r4_fp32_positive_add.sv]
read_verilog -sv [file join $source_root rtl core bc softmax \
    cats_r4_fp32_row_reciprocal.sv]
read_verilog -sv [file join $source_root rtl core bc softmax \
    cats_r4_row_softmax_accuracy.sv]
read_verilog -sv [file join $source_root rtl core bc softmax \
    cats_r4_b2_locking_arbiter.sv]
read_verilog -sv [file join $source_root rtl core bc softmax \
    cats_r4_b2_weight_stager.sv]
read_verilog -sv [file join $source_root rtl core bc softmax \
    cats_r4_b2_shared_stager_v3_wrapper.sv]
read_xdc $generated_xdc

synth_design -mode out_of_context \
    -top cats_r4_b2_shared_stager_v3_wrapper \
    -part xczu15eg-ffvb1156-2-i

write_checkpoint -force [file join $output_root cats_r4_b2_shared_softmax_ooc.dcp]
report_utilization -file [file join $output_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
    -file [file join $output_root timing_summary.rpt]
report_methodology -file [file join $output_root methodology.rpt]

set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $timing_paths] == 0} {
    puts "CATS_R4_B2_SOFTMAX_OOC: no timing path returned"
} else {
    set worst_slack [get_property SLACK [lindex $timing_paths 0]]
    puts "CATS_R4_B2_SOFTMAX_OOC: worst_slack=$worst_slack"
    if {$worst_slack < 0.0} {
        error "CATS-R4 B2 Softmax OOC WNS is negative: $worst_slack"
    }
}
puts "CATS_R4_B2_SOFTMAX_OOC: synthesis Complete"
