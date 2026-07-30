# Foreground Vivado build for environments where launch_runs cannot start its
# Windows CScript helper. All synthesis/implementation steps run in this
# Vivado process, so failures are returned directly to the caller.
set script_dir [file normalize [file dirname [info script]]]
set board_root [file normalize [file join $script_dir ..]]
source [file join $script_dir project_config.tcl]

# The build intentionally does not inject a machine-specific license path.
# Vivado must already be able to resolve a valid XCZU15EG synthesis license
# through its normal License Manager/environment configuration.

set project_file $fpt_project_file
if {![file isfile $project_file]} {
    source [file join $script_dir create_attention_board_project.tcl]
}

set report_dir [file join $board_root reports profile_v2.4]
set checkpoint_dir [file join $board_root .Xil profile_v2.4]
set export_dir [file join $board_root export]
file mkdir $report_dir
file mkdir $checkpoint_dir
file mkdir $export_dir

set_param general.maxThreads 8
if {[llength [get_projects -quiet]] == 0} {
    open_project $project_file
}
set_property top attention_board_top [get_filesets sources_1]
update_compile_order -fileset sources_1

puts "============================================================"
puts "Foreground build: v2.4 fine-grained profiling"
puts "Source root: $board_root"
puts "Build root : $fpt_build_root"
puts "============================================================"

synth_design -top attention_board_top -part $fpt_target_part \
    -flatten_hierarchy rebuilt
write_checkpoint -force [file join $checkpoint_dir post_synth.dcp]
report_utilization -file [file join $report_dir utilization_synth.rpt]

opt_design
place_design
phys_opt_design
write_checkpoint -force [file join $checkpoint_dir post_place.dcp]

route_design
write_checkpoint -force [file join $checkpoint_dir post_route.dcp]

report_utilization -hierarchical \
    -file [file join $report_dir utilization_impl.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -max_paths 20 \
    -file [file join $report_dir timing_summary_impl.rpt]
report_drc -file [file join $report_dir drc_impl.rpt]
report_power -file [file join $report_dir power_impl.rpt]

set setup_path [get_timing_paths -delay_type max -max_paths 1]
if {[llength $setup_path] == 0} {
    error "No setup timing path found after route"
}
set wns [get_property SLACK [lindex $setup_path 0]]
if {$wns < 0.0} {
    error [format "Post-route setup timing failed: WNS %.3f ns" $wns]
}

set bit_file [file join $export_dir \
    fpt_attention_board_v2_8group_v2.4_profile.bit]
set xsa_file [file join $export_dir $fpt_xsa_name]
write_bitstream -force $bit_file
write_hw_platform -fixed -include_bit -force $xsa_file

puts "============================================================"
puts {[PASS] Foreground synthesis, implementation and export complete}
puts [format "WNS : %.3f ns" $wns]
puts "BIT : $bit_file"
puts "XSA : $xsa_file"
puts "Reports: $report_dir"
puts "============================================================"

close_design
close_project
