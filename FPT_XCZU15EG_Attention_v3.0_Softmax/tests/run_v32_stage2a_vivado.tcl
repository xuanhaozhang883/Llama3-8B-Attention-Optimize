# FlashAttention Stage 2A XSim qualification, compatible with Vivado 2018.3.

set script_path [file normalize [info script]]
set tests_dir [file dirname $script_path]
set project_root [file normalize [file join $tests_dir ..]]

if {[info exists ::env(FPT_V32_STAGE2A_BUILD_ROOT)] &&
    [string trim $::env(FPT_V32_STAGE2A_BUILD_ROOT)] ne ""} {
    set build_root [file normalize $::env(FPT_V32_STAGE2A_BUILD_ROOT)]
} else {
    set build_root [file normalize [file join \
        [file dirname $project_root] _fpt_v32_stage2a_xsim]]
}
file mkdir $build_root

set project_name v32_flash_stage2a_xsim
set project_dir [file join $build_root $project_name]
catch {close_sim}
if {[llength [get_projects -quiet]] > 0} {
    close_project
}

create_project -force $project_name $project_dir \
    -part xczu15eg-ffvb1156-2-i
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set exp_lut_rtl [file join $project_root rtl core flash \
    flash_exp_approx_q23.sv]
set update_rtl [file join $project_root rtl core flash \
    flash_online_row_update.sv]
set testbench [file join $project_root tb \
    tb_v32_flash_online_row_update.sv]
set lut_file [file join $project_root mem exp_lut_q23.mem]
set vector_file [file join $project_root tests data \
    v32_online_row_vectors.txt]

set sources [list $exp_lut_rtl $update_rtl $testbench]
foreach source_file [concat $sources [list $lut_file $vector_file]] {
    if {![file isfile $source_file]} {
        error "Missing Stage 2A XSim input: $source_file"
    }
}

add_files -fileset sim_1 -norecurse $sources
set_property top tb_v32_flash_online_row_update [get_filesets sim_1]
update_compile_order -fileset sim_1

set xsim_dir [file join $project_dir \
    ${project_name}.sim sim_1 behav xsim]
file mkdir $xsim_dir
file copy -force $lut_file [file join $xsim_dir exp_lut_q23.mem]
file copy -force $vector_file \
    [file join $xsim_dir v32_online_row_vectors.txt]

set marker_path [file join $xsim_dir v32_online_row_update_pass.txt]
if {[file exists $marker_path]} {
    file delete -force $marker_path
}

launch_simulation
run all
close_sim

if {![file isfile $marker_path]} {
    error "Stage 2A did not create PASS marker: $marker_path"
}

set summary_path [file join $build_root V32_STAGE2A_XSIM_PASS.txt]
set summary [open $summary_path w]
puts $summary "V3.2 FlashAttention Stage 2A: XSIM_PASS"
puts $summary "Vivado: [version -short]"
puts $summary "Part: xczu15eg-ffvb1156-2-i"
puts $summary "Vectors: 512 bit-exact online row updates"
puts $summary "Backpressure: output payload stability checked"
close $summary

puts "============================================================"
puts {[PASS] V3.2 FLASHATTENTION STAGE 2A XSIM}
puts "Vivado : [version -short]"
puts "Evidence: $summary_path"
puts "============================================================"
close_project
