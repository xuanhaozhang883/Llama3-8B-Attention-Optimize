# Out-of-context synthesis for the default 4x4, depth-8 Score Tile FIFO.
# Run with Vivado 2024.2 from the project root.

set script_path [file normalize [info script]]
set project_root [file normalize [file join [file dirname $script_path] ..]]

if {[info exists ::env(FPT_V31_STAGE1_BUILD_ROOT)] &&
    [string trim $::env(FPT_V31_STAGE1_BUILD_ROOT)] ne ""} {
    set build_root [file normalize $::env(FPT_V31_STAGE1_BUILD_ROOT)]
} else {
    set build_root [file normalize [file join \
        [file dirname $project_root] _fpt_v31_stage1_ooc]]
}
file mkdir $build_root

set fifo_rtl [file join $project_root rtl core flash \
    flash_score_tile_fifo.sv]
if {![file isfile $fifo_rtl]} {
    error "Missing FIFO RTL: $fifo_rtl"
}

create_project -in_memory -part xczu15eg-ffvb1156-2-i
set_property target_language Verilog [current_project]
read_verilog -sv $fifo_rtl
synth_design -mode out_of_context -top flash_score_tile_fifo \
    -part xczu15eg-ffvb1156-2-i

create_clock -name fifo_clk -period 6.667 [get_ports clk]
report_utilization -hierarchical -file \
    [file join $build_root score_fifo_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -max_paths 20 -file \
    [file join $build_root score_fifo_timing_summary.rpt]
write_checkpoint -force [file join $build_root score_fifo_synth.dcp]

puts "============================================================"
puts {[PASS] V3.1 Score Tile FIFO OOC synthesis completed}
puts "Vivado : [version -short]"
puts "Output : $build_root"
puts "Reports: score_fifo_utilization.rpt, score_fifo_timing_summary.rpt"
puts "Note   : use report files, not the Tcl convenience query, for sign-off"
puts "============================================================"
close_project
