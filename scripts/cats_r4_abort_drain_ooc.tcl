if {($argc < 2) || ($argc > 3)} {
    error "expected <source-root> <output-root> ?clock-period-ns?"
}
set source_root [file normalize [lindex $argv 0]]
set output_root [file normalize [lindex $argv 1]]
set clock_period 6.666
if {$argc == 3} { set clock_period [lindex $argv 2] }
file mkdir $output_root

set xdc [file join $output_root abort_drain_ooc.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name gpio_clk -period $clock_period \[get_ports gpio_clk\]"
puts $fh "create_clock -name core_clk -period $clock_period \[get_ports core_clk\]"
puts $fh "create_clock -name axi_clk -period $clock_period \[get_ports axi_clk\]"
puts $fh {set_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports gpio_clk]}
puts $fh {set_property HD.CLK_SRC BUFGCE_X0Y1 [get_ports core_clk]}
puts $fh {set_property HD.CLK_SRC BUFGCE_X0Y2 [get_ports axi_clk]}
puts $fh {set_clock_groups -asynchronous -group [get_clocks gpio_clk] -group [get_clocks core_clk] -group [get_clocks axi_clk]}
puts $fh {set_input_delay -clock gpio_clk -max 1.000 [get_ports {arst_n abort_valid abort_done_ready}]}
puts $fh {set_input_delay -clock gpio_clk -min 0.200 [get_ports {arst_n abort_valid abort_done_ready}]}
puts $fh {set_input_delay -clock core_clk -max 1.000 [get_ports {core_outstanding_zero}]}
puts $fh {set_input_delay -clock core_clk -min 0.200 [get_ports {core_outstanding_zero}]}
puts $fh {set_input_delay -clock axi_clk -max 1.000 [get_ports {axi_outstanding_zero}]}
puts $fh {set_input_delay -clock axi_clk -min 0.200 [get_ports {axi_outstanding_zero}]}
puts $fh {set_output_delay -clock gpio_clk -max 1.000 [get_ports {abort_ready abort_done_valid abort_done_epoch[*] current_epoch[*] drain_active abort_count[*] drain_cycles[*] epoch_wrap_count[*]}]}
puts $fh {set_output_delay -clock gpio_clk -min -0.200 [get_ports {abort_ready abort_done_valid abort_done_epoch[*] current_epoch[*] drain_active abort_count[*] drain_cycles[*] epoch_wrap_count[*]}]}
puts $fh {set_output_delay -clock core_clk -max 1.000 [get_ports {core_accept_enable core_clear}]}
puts $fh {set_output_delay -clock core_clk -min -0.200 [get_ports {core_accept_enable core_clear}]}
puts $fh {set_output_delay -clock axi_clk -max 1.000 [get_ports {axi_accept_enable axi_clear}]}
puts $fh {set_output_delay -clock axi_clk -min -0.200 [get_ports {axi_accept_enable axi_clear}]}
puts $fh {set_false_path -from [get_ports arst_n]}
close $fh

read_verilog -sv [file join $source_root rtl core cluster cats_r4_abort_drain_controller.sv]
read_xdc $xdc
synth_design -mode out_of_context -top cats_r4_abort_drain_controller -part xczu15eg-ffvb1156-2-i
write_checkpoint -force [file join $output_root abort_drain_ooc.dcp]
report_utilization -file [file join $output_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained -file [file join $output_root timing_summary.rpt]
check_timing -verbose -file [file join $output_root check_timing.rpt]
# Analyze functional CDC with the asynchronous reset held inactive.  Reset
# assertion is handled by the external reset controller and is not a data CDC.
set_case_analysis 1 [get_ports arst_n]
report_methodology -file [file join $output_root methodology.rpt]
report_cdc -details -file [file join $output_root cdc.rpt]
set paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $paths] == 0} { error "CATS_R4_ABORT_DRAIN_OOC: no constrained path" }
set wns [get_property SLACK [lindex $paths 0]]
puts "CATS_R4_ABORT_DRAIN_OOC: worst_slack=$wns"
if {$wns < 0.0} { error "CATS_R4_ABORT_DRAIN_OOC: timing failed" }
