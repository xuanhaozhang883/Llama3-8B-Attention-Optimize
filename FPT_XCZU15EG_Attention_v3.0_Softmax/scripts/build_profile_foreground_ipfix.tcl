# Run the v2.6 Causal Dual-Tile foreground build with the block design in global
# synthesis mode.
set script_dir [file normalize [file dirname [info script]]]
source [file join $script_dir project_config.tcl]

# Rebuild so this script never reuses products from the failed OOC elaboration.
source [file join $script_dir create_attention_board_project.tcl]

set bd_obj [get_files -quiet */design_1.bd]
if {[llength $bd_obj] != 1} {
    error "Expected exactly one active design_1.bd, found [llength $bd_obj]"
}
set_property SYNTH_CHECKPOINT_MODE None $bd_obj
if {[string toupper [get_property SYNTH_CHECKPOINT_MODE $bd_obj]] ne "NONE"} {
    error "Failed to select global synthesis mode for design_1.bd"
}
puts "BD synthesis mode: Global (SYNTH_CHECKPOINT_MODE=None)"

reset_target all $bd_obj
generate_target all $bd_obj
set wrapper [file normalize [lindex [make_wrapper -files $bd_obj -top] 0]]
add_files -norecurse $wrapper
update_compile_order -fileset sources_1

source [file join $script_dir build_profile_foreground.tcl]
