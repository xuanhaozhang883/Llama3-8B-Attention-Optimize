# Elaborate the current v3.1.3 design with the imported BD in global mode.
# This avoids missing-module errors from OOC child checkpoints when using
# synth_design -rtl.
set script_dir [file normalize [file dirname [info script]]]
source [file join $script_dir project_config.tcl]

# Rebuild the short generated project and its staged block design.
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

# The project creator generated the BD once in its default OOC mode. Force a
# fresh set of global-synthesis output products before RTL elaboration.
reset_target all $bd_obj
generate_target all $bd_obj
set wrapper [file normalize [lindex [make_wrapper -files $bd_obj -top] 0]]
add_files -norecurse $wrapper

set_property top attention_board_top [get_filesets sources_1]
update_compile_order -fileset sources_1
synth_design -rtl -name rtl_profile_contract_check \
    -top attention_board_top -part $fpt_target_part
close_design
close_project

puts "============================================================"
puts "\[PASS\] Current Attention RTL elaborated with Vivado [version -short]"
puts "Generated project: $fpt_project_file"
puts "BD mode: Global synthesis"
puts "============================================================"
