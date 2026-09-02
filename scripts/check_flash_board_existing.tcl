# Fast repeat elaboration after create_attention_board_project.tcl has already
# generated the independent board project.  This does not replace the clean
# rebuild check; it is the short edit/verify loop for FlashAttention wiring.
set script_dir [file normalize [file dirname [info script]]]
source [file join $script_dir project_config.tcl]
if {![file isfile $fpt_project_file]} {
    error "Generated board project is missing: $fpt_project_file"
}
open_project $fpt_project_file
set_property top attention_board_top [get_filesets sources_1]
set qk_lanes 4
if {[info exists ::env(FPT_QK_LANES)] &&
    [string trim $::env(FPT_QK_LANES)] ne ""} {
    set qk_lanes [string trim $::env(FPT_QK_LANES)]
}
if {[lsearch -exact {1 2 4 8} $qk_lanes] < 0} {
    error "FPT_QK_LANES must be 1, 2, 4, or 8"
}
set_property generic \
    [list QK_LANES=$qk_lanes V_LANES=8 CAPTURE_TILE=4 PV_LANES=2] \
    [get_filesets sources_1]
update_compile_order -fileset sources_1
synth_design -rtl -name flash_board_rtl_check \
    -top attention_board_top -part $fpt_target_part
close_design
close_project
puts "\[PASS\] FlashAttention board RTL elaboration completed (QK${qk_lanes}/V8)"
