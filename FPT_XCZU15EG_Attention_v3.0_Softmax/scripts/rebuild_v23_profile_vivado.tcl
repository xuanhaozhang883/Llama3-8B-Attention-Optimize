# Rebuild the existing v2.0 project after applying the v2.3 RTL files.
# Run in Vivado 2024.2 Tcl Console from any directory:
#   cd <project root>
#   set argv [list 8]
#   source scripts/rebuild_v23_profile_vivado.tcl
set script_dir [file normalize [file dirname [info script]]]
set board_root [file normalize [file join $script_dir ..]]
cd $board_root
if {![info exists argv] || [llength $argv] == 0} {
    set argv [list 8]
}
puts "============================================================"
puts "Rebuilding v2.3 hardware profiling bitstream"
puts "Project root: $board_root"
puts "============================================================"
source [file join $script_dir build_attention_board_all.tcl]
