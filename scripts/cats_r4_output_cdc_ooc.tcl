if {($argc < 2) || ($argc > 3)} {
    error "expected <source-root> <output-root> ?clock-period-ns?"
}

set source_root [file normalize [lindex $argv 0]]
set output_root [file normalize [lindex $argv 1]]
set clock_period 6.666
if {$argc == 3} { set clock_period [lindex $argv 2] }
file mkdir $output_root

set generated_xdc [file join $output_root output_cdc_ooc.xdc]
set xdc_handle [open $generated_xdc w]
puts $xdc_handle "create_clock -name core_clk -period $clock_period \[get_ports core_clk\]"
puts $xdc_handle "create_clock -name axi_clk -period $clock_period \[get_ports axi_clk\]"
puts $xdc_handle {set_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports core_clk]}
puts $xdc_handle {set_property HD.CLK_SRC BUFGCE_X0Y1 [get_ports axi_clk]}
puts $xdc_handle {set_clock_groups -asynchronous -group [get_clocks core_clk] -group [get_clocks axi_clk]}
puts $xdc_handle {set_false_path -from [get_ports {core_rst_n axi_rst_n}]}
puts $xdc_handle {set_input_delay -clock core_clk -max 1.000 [get_ports core_rst_n]}
puts $xdc_handle {set_input_delay -clock core_clk -min 0.200 [get_ports core_rst_n]}
puts $xdc_handle {set_input_delay -clock axi_clk -max 1.000 [get_ports axi_rst_n]}
puts $xdc_handle {set_input_delay -clock axi_clk -min 0.200 [get_ports axi_rst_n]}
puts $xdc_handle {set_input_delay -clock core_clk -max 1.000 [get_ports {core_counter_clear in_valid in_epoch[*] in_global_q_head[*] in_row[*] in_feature_block[*] in_data_bf16[*] in_row_last in_tensor_last}]}
puts $xdc_handle {set_input_delay -clock core_clk -min 0.200 [get_ports {core_counter_clear in_valid in_epoch[*] in_global_q_head[*] in_row[*] in_feature_block[*] in_data_bf16[*] in_row_last in_tensor_last}]}
puts $xdc_handle {set_input_delay -clock axi_clk -max 1.000 [get_ports {axi_counter_clear out_ready}]}
puts $xdc_handle {set_input_delay -clock axi_clk -min 0.200 [get_ports {axi_counter_clear out_ready}]}
puts $xdc_handle {set_output_delay -clock core_clk -max 1.000 [get_ports {in_ready payload_push_count[*] tag_push_count[*] full_stall_count[*] max_payload_occupancy[*] max_tag_occupancy[*] overflow_count[*] seq_error_count[*] epoch_error_count[*] core_protocol_error}]}
puts $xdc_handle {set_output_delay -clock core_clk -min -0.200 [get_ports {in_ready payload_push_count[*] tag_push_count[*] full_stall_count[*] max_payload_occupancy[*] max_tag_occupancy[*] overflow_count[*] seq_error_count[*] epoch_error_count[*] core_protocol_error}]}
puts $xdc_handle {set_output_delay -clock axi_clk -max 1.000 [get_ports {out_valid out_data[*] out_epoch[*] out_seq[*] out_global_q_head[*] out_row[*] out_beat_in_row[*] out_row_last out_tensor_last payload_pop_count[*] tag_pop_count[*] empty_stall_count[*] underflow_count[*] axi_protocol_error}]}
puts $xdc_handle {set_output_delay -clock axi_clk -min -0.200 [get_ports {out_valid out_data[*] out_epoch[*] out_seq[*] out_global_q_head[*] out_row[*] out_beat_in_row[*] out_row_last out_tensor_last payload_pop_count[*] tag_pop_count[*] empty_stall_count[*] underflow_count[*] axi_protocol_error}]}
close $xdc_handle

read_verilog -sv [file join $source_root rtl core cluster cats_r4_async_fifo.sv]
read_verilog -sv [file join $source_root rtl core cluster cats_r4_output_cdc.sv]
read_xdc $generated_xdc
synth_design -mode out_of_context -top cats_r4_output_cdc \
    -part xczu15eg-ffvb1156-2-i
write_checkpoint -force [file join $output_root output_cdc_ooc.dcp]
report_utilization -file [file join $output_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
    -file [file join $output_root timing_summary.rpt]
check_timing -verbose -file [file join $output_root check_timing.rpt]
report_methodology -file [file join $output_root methodology.rpt]
# Reset assertion is intentionally asynchronous and reset release is supplied
# by the external per-domain synchronizer.  Analyze functional CDC with both
# resets inactive so report_cdc does not classify reset pins as data crossings.
set_case_analysis 1 [get_ports {core_rst_n axi_rst_n}]
report_cdc -details -file [file join $output_root cdc.rpt]

set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $timing_paths] == 0} {
    error "CATS_R4_OUTPUT_CDC_OOC: no constrained timing path returned"
}
set worst_slack [get_property SLACK [lindex $timing_paths 0]]
puts "CATS_R4_OUTPUT_CDC_OOC: worst_slack=$worst_slack"
if {$worst_slack < 0.0} {
    error "CATS_R4_OUTPUT_CDC_OOC: timing failed, worst_slack=$worst_slack"
}
