set script_dir [file dirname [file normalize [info script]]]
set project_root [file dirname $script_dir]
set part_name xczu15eg-ffvb1156-2-i

if {$argc >= 1} {
    set build_root [file normalize [lindex $argv 0]]
} else {
    set build_root [file normalize [file join $project_root .. _fpt_v31_score_fifo_ooc]]
}

file mkdir $build_root
create_project v31_flash_score_fifo_ooc $build_root -part $part_name -force
set_property target_language Verilog [current_project]
add_files -norecurse [file join $project_root rtl core online flash_score_tile_fifo.sv]
set_property top flash_score_tile_fifo [get_filesets sources_1]
update_compile_order -fileset sources_1

synth_design -top flash_score_tile_fifo -part $part_name -mode out_of_context
create_clock -name score_fifo_clk -period 6.667 [get_ports clk]
report_utilization -file [file join $build_root score_fifo_utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 -report_unconstrained \
    -file [file join $build_root score_fifo_timing_summary.rpt]
write_checkpoint -force [file join $build_root score_fifo_synth.dcp]

puts "============================================================"
puts {[PASS] Fused v3.1 multi-group Score Tile FIFO OOC synthesis completed}
puts "Vivado : [version -short]"
puts "Output : $build_root"
puts "Reports: score_fifo_utilization.rpt, score_fifo_timing_summary.rpt"
puts "============================================================"
close_project
