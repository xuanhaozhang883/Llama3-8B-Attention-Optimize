# FlashAttention Stage 3A XSim qualification, compatible with Vivado 2018.3.

set script_path [file normalize [info script]]
set tests_dir [file dirname $script_path]
set project_root [file normalize [file join $tests_dir ..]]

if {[info exists ::env(FPT_V34_STAGE3A_BUILD_ROOT)] &&
    [string trim $::env(FPT_V34_STAGE3A_BUILD_ROOT)] ne ""} {
    set build_root [file normalize $::env(FPT_V34_STAGE3A_BUILD_ROOT)]
} else {
    set build_root [file normalize [file join \
        [file dirname $project_root] _fpt_v34_stage3a_xsim]]
}
file mkdir $build_root

set project_name v34_flash_stage3a_xsim
set project_dir [file join $build_root $project_name]
catch {close_sim}
if {[llength [get_projects -quiet]] > 0} {
    close_project
}

create_project -force $project_name $project_dir \
    -part xczu15eg-ffvb1156-2-i
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl [file join $project_root rtl core flash \
    flash_pv_o_tile_update.sv]
set testbench [file join $project_root tb \
    tb_v34_flash_pv_o_tile_update.sv]
set vector_file [file join $project_root tests data \
    v34_pv_o_vectors.txt]

foreach source_file [list $rtl $testbench $vector_file] {
    if {![file isfile $source_file]} {
        error "Missing Stage 3A XSim input: $source_file"
    }
}

add_files -fileset sim_1 -norecurse [list $rtl $testbench]
set_property top tb_v34_flash_pv_o_tile_update [get_filesets sim_1]
update_compile_order -fileset sim_1

set xsim_dir [file join $project_dir \
    ${project_name}.sim sim_1 behav xsim]
file mkdir $xsim_dir
file copy -force $vector_file \
    [file join $xsim_dir v34_pv_o_vectors.txt]

set marker_path [file join $xsim_dir v34_pv_o_tile_pass.txt]
if {[file exists $marker_path]} {
    file delete -force $marker_path
}

launch_simulation
run all
close_sim

if {![file isfile $marker_path]} {
    error "Stage 3A did not create PASS marker: $marker_path"
}

set summary_path [file join $build_root V34_STAGE3A_XSIM_PASS.txt]
set summary [open $summary_path w]
puts $summary "V3.4 FlashAttention Stage 3A: XSIM_PASS"
puts $summary "Vivado: [version -short]"
puts $summary "Part: xczu15eg-ffvb1156-2-i"
puts $summary "Vectors: 133 bit-exact 4x8 P/V/O updates"
puts $summary "Backpressure: randomized and long output stalls"
close $summary

puts "============================================================"
puts {[PASS] V3.4 FLASHATTENTION STAGE 3A XSIM}
puts "Vivado : [version -short]"
puts "Evidence: $summary_path"
puts "============================================================"
close_project
