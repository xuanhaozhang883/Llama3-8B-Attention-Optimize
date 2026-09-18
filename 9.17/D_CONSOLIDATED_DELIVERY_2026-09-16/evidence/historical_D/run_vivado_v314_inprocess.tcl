# Build the v3.1.4 board image entirely in the active Vivado process.
# This avoids Windows child-run termination seen with launch_runs/runme.bat.

set repo_root {C:/Users/23858/xwechat_files/wxid_704fehcdj58l22_8fda/msg/file/2026-09/03_work_v314_causal_bypass/workspace/Llama3-8B-Attention-Optimize-ABL-v314}
set build_root {D:/fpt_build/v314_inprocess}
set status_dir {C:/Users/23858/xwechat_files/wxid_704fehcdj58l22_8fda/msg/file/2026-09/03_work_v314_causal_bypass/workspace/D/board_build_status}
set project_name {fpt_attention_board_v314_qk4_causal_bypass}
set project_dir [file join $build_root $project_name]
set project_file [file join $project_dir ${project_name}.xpr]
set bit_file [file join $project_dir ${project_name}.bit]
set export_dir [file join $repo_root export]
set report_dir [file join $repo_root reports]
set xsa_file [file join $export_dir ${project_name}.xsa]
set marker [file join $status_dir vivado_inprocess_build_result.txt]

set ::env(FPT_VIVADO_BUILD_ROOT) $build_root
set ::env(XILINXD_LICENSE_FILE) {C:/Users/23858/AppData/Roaming/XilinxLicense/Xilinx_Enterprise_2026.lic}
file mkdir $status_dir
file mkdir $export_dir
file mkdir $report_dir
set fh [open $marker w]
puts $fh "RUNNING"
close $fh

set_param general.maxThreads 1

if {[catch {
    if {[llength [get_projects -quiet]] > 0} {
        close_project
    }
    if {![file isfile $project_file]} {
        source [file join $repo_root scripts create_attention_board_project.tcl]
    } else {
        open_project $project_file
    }

    update_compile_order -fileset sources_1
    foreach ip_file [get_files -quiet *.xci] {
        catch {set_property GENERATE_SYNTH_CHECKPOINT false $ip_file}
    }
    foreach bd_file [get_files -quiet *.bd] {
        catch {set_property SYNTH_CHECKPOINT_MODE None $bd_file}
        generate_target all $bd_file
    }
    update_compile_order -fileset sources_1

    synth_design -top attention_board_top -part xczu15eg-ffvb1156-2-i -flatten_hierarchy rebuilt
    write_checkpoint -force [file join $project_dir post_synth.dcp]
    report_utilization -file [file join $report_dir utilization_synth_inprocess.rpt]

    opt_design
    place_design
    phys_opt_design
    route_design
    write_checkpoint -force [file join $project_dir post_route.dcp]
    report_utilization -hierarchical -file [file join $report_dir utilization_impl.rpt]
    report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -max_paths 20 -file [file join $report_dir timing_summary_impl.rpt]
    report_drc -file [file join $report_dir drc_impl.rpt]
    report_power -file [file join $report_dir power_impl.rpt]

    write_bitstream -force $bit_file
    write_hw_platform -fixed -include_bit -force $xsa_file
} build_result build_options]} {
    set fh [open $marker w]
    puts $fh "FAIL"
    puts $fh $build_result
    if {[dict exists $build_options -errorinfo]} {
        puts $fh [dict get $build_options -errorinfo]
    }
    close $fh
    puts stderr "FPT_INPROCESS_BUILD_FAIL: $build_result"
    return -options $build_options $build_result
}

set fh [open $marker w]
puts $fh "PASS"
puts $fh "BIT=$bit_file"
puts $fh "XSA=$xsa_file"
close $fh
puts "FPT_INPROCESS_BUILD_PASS"
