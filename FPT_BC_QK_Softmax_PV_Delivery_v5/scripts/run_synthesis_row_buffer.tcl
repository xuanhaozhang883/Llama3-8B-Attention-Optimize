# Fast Vivado 2019.2 OOC check for the Row Tile Buffer BRAM template.

set origin_dir [file normalize [file join [file dirname [info script]] ..]]
source [file join $origin_dir scripts synthesis_bc_common.tcl]

set project_dir [file join $origin_dir vivado_synth_row_buffer]
set report_dir  [file join $origin_dir reports row_buffer_artix7]
file mkdir $report_dir

if {[llength [get_projects -quiet]] > 0} { close_project }
create_project fpt_row_buffer_ooc $project_dir -part xc7a35tcpg236-1 -force
set_property target_language Verilog [current_project]

add_files -norecurse [list \
    [file join $origin_dir rtl adapter score_rowtile_payload_bram.sv] \
    [file join $origin_dir rtl adapter score_rowtile_buffer.sv]]
add_files -fileset constrs_1 -norecurse \
    [file join $origin_dir constraints qk_softmax_100mhz.xdc]
set_property file_type SystemVerilog [get_files -quiet *.sv]
set_property top score_rowtile_buffer [get_filesets sources_1]
update_compile_order -fileset sources_1

set synth_run [get_runs synth_1]
configure_ooc_synthesis $synth_run
set_run_property_if_present $synth_run \
    STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Row Tile Buffer synthesis did not complete: [get_property STATUS [get_runs synth_1]]"
}
open_run synth_1

report_utilization -hierarchical \
    -file [file join $report_dir post_synth_utilization_hier.rpt]
catch {report_ram_utilization \
    -file [file join $report_dir post_synth_ram_utilization.rpt]}
write_checkpoint -force \
    [file join $report_dir score_rowtile_buffer_post_synth.dcp]

set ramb_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ "RAMB*"}]
set latch_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ "LD*"}]
set black_box_cells [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
set ff_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ "FD*"}]

puts "AUDIT: Row Tile Buffer RAMB count = [llength $ramb_cells]"
puts "AUDIT: Row Tile Buffer FF count = [llength $ff_cells]"
puts "AUDIT: latch/black-box counts = [llength $latch_cells]/[llength $black_box_cells]"

if {[llength $ramb_cells] != 1} {
    error "Expected exactly one Row Tile Buffer RAMB primitive, got [llength $ramb_cells]"
}
if {[llength $latch_cells] != 0} {
    error "Unexpected Row Tile Buffer latch primitives: [llength $latch_cells]"
}
if {[llength $black_box_cells] != 0} {
    error "Unexpected Row Tile Buffer black boxes: [llength $black_box_cells]"
}

puts "PASS: Row Tile Buffer inferred exactly one block-RAM primitive"
puts "PASS: Row Tile Buffer has no latch or black-box cell"
puts "Reports: $report_dir"
