# Build and run the v2.3 A53 profiling benchmark.
# Usage in XSCT 2024.2:
#   cd <project root>
#   set argv [list <full path to current psu_init.tcl>]
#   source scripts/build_and_run_v23_profile_xsct.tcl
set script_dir [file normalize [file dirname [info script]]]
set board_root [file normalize [file join $script_dir ..]]
if {[llength $argv] < 1} {
    error "Usage: set argv [list <psu_init.tcl>]; source scripts/build_and_run_v23_profile_xsct.tcl"
}
set psu_init [file normalize [lindex $argv 0]]
if {![file isfile $psu_init]} { error "psu_init.tcl not found: $psu_init" }
puts "============================================================"
puts "Building v2.3 hardware profiling benchmark"
puts "Project root: $board_root"
puts "PSU init   : $psu_init"
puts "============================================================"
set argv {}
source [file join $script_dir create_vitis_app_xsct.tcl]
set app_elf [file normalize [file join $board_root vitis workspace \
    fpt_attention_test Debug fpt_attention_test.elf]]
if {![file isfile $app_elf]} { error "Built ELF not found: $app_elf" }
set argv [list $psu_init $app_elf]
source [file join $script_dir run_on_board_no_gtr_xsct.tcl]
