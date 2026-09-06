# Vivado 2025.2 OOC synthesis for the CATS-R4 IF_V2 AXI/core bank bridge.
# Usage: vivado -mode batch -source scripts/cats_r4_qkv_axi_bank_bridge_ooc.tcl -tclargs <source-root> <output-root> ?clock-period-ns?
if {($argc < 2) || ($argc > 3)} {
    error "expected <source-root> <output-root> ?clock-period-ns?"
}
set source_root [file normalize [lindex $argv 0]]
set output_root [file normalize [lindex $argv 1]]
set clock_period 6.666
if {$argc == 3} { set clock_period [lindex $argv 2] }
file mkdir $output_root
create_project -force cats_r4_qkv_axi_bank_bridge_ooc [file join $output_root proj] -part xczu15eg-ffvb1156-2-i
set xdc [file join $output_root cats_r4_qkv_axi_bank_bridge_ooc.xdc]
set fh [open $xdc w]
puts $fh "create_clock -name axi_clk -period $clock_period \[get_ports axi_clk\]"
puts $fh "create_clock -name core_clk -period $clock_period \[get_ports core_clk\]"
puts $fh {set_clock_groups -asynchronous -group [get_clocks axi_clk] -group [get_clocks core_clk]}
set axi_in {wr_valid wr_kind wr_buffer wr_epoch wr_group wr_global_q_head wr_row_window wr_beat_index wr_data wr_strb wr_last done_ready}
set axi_out {wr_ready done_valid done_kind done_buffer done_epoch done_group done_global_q_head done_row_window q_beats_accepted k_beats_accepted v_beats_accepted protocol_errors protocol_error_sticky}
set core_in {active_valid active_buffer q_req_valid q_req_context_tag q_req_d k_req_valid k_req_context_tag k_req_key_block k_req_d v_req_valid v_req_context_tag v_req_key v_req_feature_block}
set core_out {q_req_ready q_rsp_valid q_rsp_context_tag q_rsp_bf16 k_req_ready k_rsp_valid k_rsp_context_tag k_rsp_vec v_req_ready v_rsp_valid v_rsp_context_tag v_rsp_vec}
foreach p $axi_in {
    puts $fh "set_input_delay -clock axi_clk -max 1.000 \[get_ports $p\]"
    puts $fh "set_input_delay -clock axi_clk -min 0.200 \[get_ports $p\]"
}
foreach p $axi_out {
    puts $fh "set_output_delay -clock axi_clk -max 1.000 \[get_ports $p\]"
    puts $fh "set_output_delay -clock axi_clk -min -0.200 \[get_ports $p\]"
}
foreach p $core_in {
    puts $fh "set_input_delay -clock core_clk -max 1.000 \[get_ports $p\]"
    puts $fh "set_input_delay -clock core_clk -min 0.200 \[get_ports $p\]"
}
foreach p $core_out {
    puts $fh "set_output_delay -clock core_clk -max 1.000 \[get_ports $p\]"
    puts $fh "set_output_delay -clock core_clk -min -0.200 \[get_ports $p\]"
}
close $fh
add_files -norecurse [file join $source_root rtl core cluster cats_r4_qkv_axi_bank_bridge.sv]
add_files -fileset constrs_1 -norecurse $xdc
set_property top cats_r4_qkv_axi_bank_bridge [current_fileset]
update_compile_order -fileset sources_1
synth_design -mode out_of_context -top cats_r4_qkv_axi_bank_bridge -part xczu15eg-ffvb1156-2-i
write_checkpoint -force [file join $output_root cats_r4_qkv_axi_bank_bridge_ooc.dcp]
report_utilization -file [file join $output_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained -file [file join $output_root timing_summary.rpt]
report_methodology -file [file join $output_root methodology.rpt]
report_cdc -file [file join $output_root cdc.rpt]
set paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $paths] > 0} { puts "CATS_R4_QKV_AXI_BANK_BRIDGE_OOC: worst_slack=[get_property SLACK [lindex $paths 0]]" }
close_project