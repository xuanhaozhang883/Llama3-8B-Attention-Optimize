# One-shot GUI build wrapper for the CATS-R4 v3.14 board image.
# It is intended to be launched from Vivado via Tools > Run Tcl Script.

set repo_root {C:/Users/23858/xwechat_files/wxid_704fehcdj58l22_8fda/msg/file/2026-09/03_work_v314_causal_bypass/workspace/Llama3-8B-Attention-Optimize-ABL-v314}
set status_dir {C:/Users/23858/xwechat_files/wxid_704fehcdj58l22_8fda/msg/file/2026-09/03_work_v314_causal_bypass/workspace/D/board_build_status}

set ::env(FPT_VIVADO_BUILD_ROOT) {D:/fpt_build/v314_gui}
set ::env(XILINXD_LICENSE_FILE) {C:/Users/23858/AppData/Roaming/XilinxLicense/Xilinx_Enterprise_2026.lic}
file mkdir $status_dir

# The four OOC IP runs each peak near 2 GB and Vivado also spawns helper
# processes.  Serialize the runs to stay below the machine's commit limit.
set_param general.maxThreads 1
set argv [list 1]
set argc [llength $argv]
set build_script [file join $repo_root scripts build_attention_board_all.tcl]

set marker [file join $status_dir vivado_gui_build_result.txt]
set fh [open $marker w]
puts $fh "RUNNING"
close $fh
if {[catch {source $build_script} build_result build_options]} {
    set fh [open $marker w]
    puts $fh "FAIL"
    puts $fh $build_result
    close $fh
    puts stderr "FPT_GUI_BUILD_FAIL: $build_result"
    return -options $build_options $build_result
}

set fh [open $marker w]
puts $fh "PASS"
puts $fh $build_result
close $fh
puts "FPT_GUI_BUILD_PASS"
