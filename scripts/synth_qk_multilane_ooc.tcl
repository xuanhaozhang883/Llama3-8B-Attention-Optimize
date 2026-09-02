if {$argc < 4} {
    error "usage: synth_qk_multilane_ooc.tcl <source_root> <build_root> <report_root> <qk_lanes>"
}
set source_root [file normalize [lindex $argv 0]]
set build_root [file normalize [lindex $argv 1]]
set report_root [file normalize [lindex $argv 2]]
set qk_lanes [lindex $argv 3]
if {[lsearch -exact {1 2 4 8} $qk_lanes] < 0} {
    error "qk_lanes must be 1, 2, 4, or 8"
}

set part_name xczu15eg-ffvb1156-2-i
file mkdir $build_root
file mkdir $report_root
create_project qk_multilane_ooc_lanes${qk_lanes} $build_root \
    -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl_files [list \
    [file join $source_root rtl core bc qk bf16_to_fp32.v] \
    [file join $source_root rtl core bc qk fp32_to_bf16.v] \
    [file join $source_root rtl core bc qk fp32_mul_ip.v] \
    [file join $source_root rtl core bc qk fp32_add_ip.v] \
    [file join $source_root rtl core bc qk qk_systolic_pe.sv] \
    [file join $source_root rtl core bc qk qk_result_scaler.sv] \
    [file join $source_root rtl core bc qk qk_systolic_tile.sv] \
    [file join $source_root rtl core bc qk qk_parallel_systolic_gqa_top.sv]]
add_files -norecurse $rtl_files
set_property top qk_parallel_systolic_gqa_top [get_filesets sources_1]
set_property generic "QK_LANES=$qk_lanes" [get_filesets sources_1]
set ::FPT_FP_IP_SYNTH_CHECKPOINT true
source [file join $source_root scripts create_fp32_ips.tcl]
update_compile_order -fileset sources_1

set xdc_path [file join $build_root qk_multilane_ooc.xdc]
set xdc_file [open $xdc_path w]
puts $xdc_file {create_clock -name qk_clk -period 6.667 [get_ports clk]}
close $xdc_file
add_files -fileset constrs_1 -norecurse $xdc_path

set synth_run [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none $synth_run
launch_runs $synth_run -jobs 1
wait_on_run $synth_run
if {[get_property PROGRESS $synth_run] ne "100%"} {
    error "synth_1 did not complete: [get_property STATUS $synth_run]"
}
open_run $synth_run

report_utilization -hierarchical -file \
    [file join $report_root utilization_hierarchical.rpt]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
    -file [file join $report_root timing_summary.rpt]
report_methodology -file [file join $report_root methodology.rpt]
write_checkpoint -force [file join $build_root qk_lanes${qk_lanes}_synth.dcp]

set timing_path [get_timing_paths -delay_type max -max_paths 1 -quiet]
set wns "NA"
if {[llength $timing_path] > 0} {
    set wns [get_property SLACK [lindex $timing_path 0]]
}
set summary [open [file join $report_root summary.txt] w]
puts $summary "vivado=[version -short]"
puts $summary "part=$part_name"
puts $summary "qk_lanes=$qk_lanes"
puts $summary "target_mhz=150"
puts $summary "wns_ns=$wns"
close $summary
puts "QK_MULTILANE_OOC_PASS lanes=$qk_lanes wns_ns=$wns"
close_project
