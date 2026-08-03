# FlashAttention Stage 1 XSim qualification for Vivado 2024.2.
# This test uses deterministic QK/Frontend models around the production
# qk_softmax_pipeline_top. Run scripts/check_rtl_elaboration.tcl afterwards to
# elaborate the same top against the real QK, Softmax and board hierarchy.

set script_path [file normalize [info script]]
set tests_dir [file dirname $script_path]
set project_root [file normalize [file join $tests_dir ..]]

if {[info exists ::env(FPT_V31_STAGE1_BUILD_ROOT)] &&
    [string trim $::env(FPT_V31_STAGE1_BUILD_ROOT)] ne ""} {
    set build_root [file normalize $::env(FPT_V31_STAGE1_BUILD_ROOT)]
} else {
    set build_root [file normalize [file join \
        [file dirname $project_root] _fpt_v31_stage1_xsim]]
}
file mkdir $build_root

set project_name v31_flash_stage1_xsim
set project_dir [file join $build_root $project_name]
catch {close_sim}
if {[llength [get_projects -quiet]] > 0} {
    close_project
}

create_project -force $project_name $project_dir \
    -part xczu15eg-ffvb1156-2-i
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set sources [list \
    [file join $project_root rtl core flash flash_score_tile_fifo.sv] \
    [file join $project_root rtl core bc integration \
        qk_softmax_pipeline_top.sv] \
    [file join $project_root tb tb_v31_flash_score_tile_fifo.sv] \
    [file join $project_root tb \
        tb_v31_qk_softmax_fifo_integration.sv]]

foreach source_file $sources {
    if {![file isfile $source_file]} {
        error "Missing Stage 1 XSim input: $source_file"
    }
}
add_files -fileset sim_1 -norecurse $sources

set xsim_dir [file join $project_dir \
    ${project_name}.sim sim_1 behav xsim]

proc run_stage1_test {top_name marker_name xsim_dir} {
    set marker_path [file join $xsim_dir $marker_name]
    if {[file exists $marker_path]} {
        file delete -force $marker_path
    }

    set_property top $top_name [get_filesets sim_1]
    update_compile_order -fileset sim_1
    launch_simulation
    run all
    close_sim

    if {![file isfile $marker_path]} {
        error "$top_name did not create PASS marker: $marker_path"
    }
    puts [format {[PASS] %s} $top_name]
}

run_stage1_test tb_v31_flash_score_tile_fifo \
    v31_flash_score_fifo_pass.txt $xsim_dir
run_stage1_test tb_v31_qk_softmax_fifo_integration \
    v31_qk_softmax_fifo_integration_pass.txt $xsim_dir

set summary_path [file join $build_root V31_FLASH_STAGE1_XSIM_PASS.txt]
set summary [open $summary_path w]
puts $summary "V3.1 FlashAttention Stage 1: XSIM_PASS"
puts $summary "Vivado: [version -short]"
puts $summary "Part: xczu15eg-ffvb1156-2-i"
puts $summary "FIFO: complete 4x4 tile, random backpressure, no forced tile bubble"
puts $summary "Integration: QK -> FIFO -> current qk_softmax_frontend boundary"
puts $summary "Production RTL elaboration: RUN_SEPARATELY"
close $summary

puts "============================================================"
puts {[PASS] V3.1 FLASHATTENTION STAGE 1 XSIM}
puts "Evidence: $summary_path"
puts "Next: vivado -mode batch -source scripts/check_rtl_elaboration.tcl"
puts "============================================================"
close_project
