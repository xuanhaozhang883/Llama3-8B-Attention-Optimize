if {$argc < 2} {
    error "usage: synth_flash_consumer_ooc.tcl <source_root> <build_root> ?report_root?"
}
set source_root [file normalize [lindex $argv 0]]
set build_root [file normalize [lindex $argv 1]]
if {$argc >= 3} {
    set report_root [file normalize [lindex $argv 2]]
} else {
    set report_root [file join $source_root reports v31_flash_consumer_ooc_latest]
}
set part_name xczu15eg-ffvb1156-2-i
file mkdir $build_root
create_project fpt_flash_consumer_ooc $build_root -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl_files [list \
    [file join $source_root rtl core bc softmax exp_lut.sv] \
    [file join $source_root rtl core bc softmax unsigned_restoring_divider.sv] \
    [file join $source_root rtl core bc backend bf16_v_cache.sv] \
    [file join $source_root rtl core pv pv_fp32_mul_ip.sv] \
    [file join $source_root rtl core pv pv_fp32_add_ip.sv] \
    [file join $source_root rtl core online flash_score_tile_fifo.sv] \
    [file join $source_root rtl core online flash_online_softmax_frontend.sv] \
    [file join $source_root rtl core online flash_context_update_pe.sv] \
    [file join $source_root rtl core online flash_context_fusion_backend.sv] \
    [file join $source_root rtl core online flash_attention_consumer_top.sv]]
add_files -norecurse $rtl_files
add_files -norecurse [file join $source_root mem exp_lut_q15.mem]
set_property top flash_attention_consumer_top [get_filesets sources_1]

source [file join $source_root scripts create_fp32_ips.tcl]
update_compile_order -fileset sources_1
synth_design -top flash_attention_consumer_top -part $part_name \
    -mode out_of_context -flatten_hierarchy rebuilt
create_clock -name consumer_clk -period 6.667 [get_ports clk]

file mkdir $report_root
report_utilization -hierarchical -file \
    [file join $report_root utilization_hierarchical.rpt]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
    -file [file join $report_root timing_summary.rpt]
report_methodology -file [file join $report_root methodology.rpt]
write_checkpoint -force [file join $build_root flash_consumer_ooc_synth.dcp]

set util [report_utilization -return_string]
set timing [report_timing_summary -delay_type max -max_paths 1 -return_string]
puts "FPT_FLASH_CONSUMER_OOC_UTIL_BEGIN"
puts $util
puts "FPT_FLASH_CONSUMER_OOC_UTIL_END"
puts "FPT_FLASH_CONSUMER_OOC_TIMING_BEGIN"
puts $timing
puts "FPT_FLASH_CONSUMER_OOC_TIMING_END"
puts "\[PASS\] FlashAttention consumer OOC synthesis completed"
close_project
