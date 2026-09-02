# Central project settings. All Tcl/XSCT scripts source this file.
set fpt_project_name "fpt_attention_board_v314_qk4_causal_bypass"
set fpt_xsa_name "fpt_attention_board_v314_qk4_causal_bypass.xsa"
set fpt_run_groups 8
set fpt_target_part "xczu15eg-ffvb1156-2-i"

# Keep Vivado's generated project, IP output products and BD staging tree out
# of the (potentially long) source directory. The default is a short sibling
# directory, for example C:/fpt_build/v314/.
#
# Advanced users may override it before launching Vivado:
#   set ::env(FPT_VIVADO_BUILD_ROOT) C:/fpt_build/v314
set fpt_source_root [file normalize [file join [file dirname [info script]] ..]]
if {[info exists ::env(FPT_VIVADO_BUILD_ROOT)] &&
    [string trim $::env(FPT_VIVADO_BUILD_ROOT)] ne ""} {
    set fpt_build_root [file normalize $::env(FPT_VIVADO_BUILD_ROOT)]
} else {
    set fpt_build_root [file normalize \
        [file join [file dirname $fpt_source_root] _fpt_v314_build]]
}
set fpt_project_dir [file join $fpt_build_root $fpt_project_name]
set fpt_project_file [file join $fpt_project_dir ${fpt_project_name}.xpr]
