# Vivado 2025.2 OOC synthesis for the CATS-R4 system counter closure gate.
# Usage: vivado -mode batch -source scripts/cats_r4_c_counter_gate_ooc.tcl -tclargs <source-root> <output-root> ?clock-period-ns?
if {($argc < 2) || ($argc > 3)} {
    error "expected <source-root> <output-root> ?clock-period-ns?"
}
set source_root [file normalize [lindex $argv 0]]
set output_root [file normalize [lindex $argv 1]]
set clock_period 6.666
if {$argc == 3} { set clock_period [lindex $argv 2] }
file mkdir $output_root
create_project -force cats_r4_c_counter_gate_ooc [file join $output_root proj] -part xczu15eg-ffvb1156-2-i
set xdc [file join $output_root cats_r4_c_counter_gate_ooc.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name clk -period $clock_period \[get_ports clk\]"
puts $fh {set_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports clk]}
puts $fh {set_input_delay -clock clk -max 1.000 [get_ports -filter {DIRECTION == IN && NAME != "clk"}]}
puts $fh {set_input_delay -clock clk -min 0.200 [get_ports -filter {DIRECTION == IN && NAME != "clk"}]}
puts $fh {set_output_delay -clock clk -max 1.000 [get_ports -filter {DIRECTION == OUT}]}
puts $fh {set_output_delay -clock clk -min -0.200 [get_ports -filter {DIRECTION == OUT}]}
close $fh
add_files -norecurse [file join $source_root rtl core cluster cats_r4_c_counter_gate.sv]
add_files -fileset constrs_1 -norecurse $xdc
set_property top cats_r4_c_counter_gate [current_fileset]
update_compile_order -fileset sources_1
synth_design -mode out_of_context -top cats_r4_c_counter_gate -part xczu15eg-ffvb1156-2-i
write_checkpoint -force [file join $output_root cats_r4_c_counter_gate_ooc.dcp]
report_utilization -file [file join $output_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained -file [file join $output_root timing_summary.rpt]
check_timing -verbose -file [file join $output_root check_timing.rpt]
report_methodology -file [file join $output_root methodology.rpt]
set paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $paths] == 0} {
    error "CATS_R4_C_COUNTER_GATE_OOC: no constrained timing path returned"
}
set worst_slack [get_property SLACK [lindex $paths 0]]
puts "CATS_R4_C_COUNTER_GATE_OOC: worst_slack=$worst_slack"
if {$worst_slack < 0.0} {
    error "CATS_R4_C_COUNTER_GATE_OOC: timing failed, worst_slack=$worst_slack"
}
close_project
