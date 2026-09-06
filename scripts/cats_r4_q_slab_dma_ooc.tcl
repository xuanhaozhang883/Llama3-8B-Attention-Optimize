# Vivado 2025.2 OOC synthesis for the CATS-R4 IF_V2 Q-slab DMA adapter.
# Usage:
#   vivado -mode batch -source cats_r4_q_slab_dma_ooc.tcl \
#          -tclargs <source-root> <output-root> ?clock-period-ns?

if {($argc < 2) || ($argc > 3)} {
    error "expected <source-root> <output-root> ?clock-period-ns?"
}

set source_root [file normalize [lindex $argv 0]]
set output_root [file normalize [lindex $argv 1]]
set clock_period 6.666
if {$argc == 3} {
    set clock_period [lindex $argv 2]
}

file mkdir $output_root
set generated_xdc [file join $output_root q_slab_dma_ooc.xdc]
set xdc_handle [open $generated_xdc w]
puts $xdc_handle "create_clock -name core_clk -period $clock_period \[get_ports clk\]"
puts $xdc_handle {set_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports clk]}
puts $xdc_handle {set_input_delay -clock core_clk -max 1.000 [get_ports -filter {DIRECTION == IN && NAME != clk}]}
puts $xdc_handle {set_input_delay -clock core_clk -min 0.200 [get_ports -filter {DIRECTION == IN && NAME != clk}]}
puts $xdc_handle {set_output_delay -clock core_clk -max 1.000 [get_ports -filter {DIRECTION == OUT}]}
puts $xdc_handle {set_output_delay -clock core_clk -min -0.200 [get_ports -filter {DIRECTION == OUT}]}
close $xdc_handle

read_verilog -sv [file join $source_root rtl core cluster \
    cats_r4_q_slab_dma_controller.sv]
read_xdc $generated_xdc

synth_design -mode out_of_context \
    -top cats_r4_q_slab_dma_controller \
    -part xczu15eg-ffvb1156-2-i

write_checkpoint -force [file join $output_root q_slab_dma_ooc.dcp]
report_utilization -file [file join $output_root utilization.rpt]
# Synthesis-only OOC evidence reports setup. Hold is intentionally reserved
# for placed/routed full-board implementation, where clock insertion is real.
report_timing_summary -delay_type max -max_paths 20 \
    -report_unconstrained -file [file join $output_root timing_summary.rpt]
report_methodology -file [file join $output_root methodology.rpt]

set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $timing_paths] == 0} {
    puts "CATS_R4_Q_SLAB_DMA_OOC: no timing path returned"
} else {
    puts "CATS_R4_Q_SLAB_DMA_OOC: worst_slack=[get_property SLACK [lindex $timing_paths 0]]"
}
