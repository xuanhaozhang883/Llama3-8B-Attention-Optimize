# Full synthesis qualification for the XCZU15EG v3.0 online-fused board top.
set v30_synth_script [file normalize [info script]]
set v30_synth_tests [file dirname $v30_synth_script]
set v30_synth_root [file normalize [file join $v30_synth_tests ..]]
set v30_synth_scripts [file join $v30_synth_root scripts]

source [file join $v30_synth_scripts project_config.tcl]
if {![file isfile $fpt_project_file]} {
    source [file join $v30_synth_scripts create_attention_board_project.tcl]
} elseif {[llength [get_projects -quiet]] == 0} {
    open_project $fpt_project_file
}

set v30_synth_out [file join $fpt_build_root v30_synthesis]
file mkdir $v30_synth_out
set_property top attention_board_top [get_filesets sources_1]
update_compile_order -fileset sources_1

set v30_original_cwd [pwd]
if {[catch {
    cd $fpt_build_root
    synth_design -top attention_board_top -part $fpt_target_part \
        -flatten_hierarchy rebuilt
} v30_synth_message v30_synth_options]} {
    cd $v30_original_cwd
    return -options $v30_synth_options $v30_synth_message
}
cd $v30_original_cwd

set v30_online_cells [get_cells -hier -quiet \
    -filter {ORIG_REF_NAME == online_softmax_context_tile || REF_NAME == online_softmax_context_tile}]
if {[llength $v30_online_cells] == 0} {
    error "Synthesized design does not contain the v3.0 online core"
}

foreach v30_forbidden_ref {
    score_rowtile_buffer
    softmax_output_buffer
    pv_tile4_pingpong_buffer
    pv_parallel_systolic_gqa_top
} {
    set v30_forbidden_cells [get_cells -hier -quiet \
        -filter "ORIG_REF_NAME == $v30_forbidden_ref || REF_NAME == $v30_forbidden_ref"]
    if {[llength $v30_forbidden_cells] != 0} {
        error "Legacy P capture/replay block survived ONLINE_MODE: $v30_forbidden_ref"
    }
}

report_utilization -hierarchical \
    -file [file join $v30_synth_out utilization_v30_synth.rpt]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $v30_synth_out timing_v30_synth.rpt]
write_checkpoint -force [file join $v30_synth_out v30_post_synth.dcp]

set v30_marker [file join $v30_synth_out V30_BOARD_SYNTH_PASS.txt]
set v30_stream [open $v30_marker w]
puts $v30_stream "V3.0 XCZU15EG online-fused board top: SYNTH_PASS"
puts $v30_stream "Vivado: [version -short]"
puts $v30_stream "Part: $fpt_target_part"
puts $v30_stream "ONLINE_MODE: 1"
puts $v30_stream "Board execution: NOT_RUN"
close $v30_stream

puts "============================================================"
puts {[PASS] V3.0 XCZU15EG ONLINE-FUSED BOARD SYNTHESIS}
puts "Evidence: $v30_marker"
puts "Project : $fpt_project_file"
puts "============================================================"
close_design
close_project
