# Elaborate the current source tree with the existing Vivado project/IP set.
# This is intentionally faster than implementation and catches port/interface
# errors before launching a full synthesis run.
set script_dir [file normalize [file dirname [info script]]]
set board_root [file normalize [file join $script_dir ..]]
source [file join $script_dir project_config.tcl]

# Always rebuild the generated project for this check. This discards only the
# short external build directory, never RTL or the v2.3 baseline, and prevents
# a failed older run from reusing a stale wrapper.
source [file join $script_dir create_attention_board_project.tcl]

# synth_design -rtl does not consume per-IP OOC checkpoints.  Regenerate the
# imported Block Design in global-synthesis mode so every BD child IP (notably
# the AXI GPIO mailbox) is present during this source-level elaboration.
set bd_obj [get_files -quiet */design_1.bd]
if {[llength $bd_obj] != 1} {
    error "Expected exactly one active design_1.bd, found [llength $bd_obj]"
}
set_property SYNTH_CHECKPOINT_MODE None $bd_obj
if {[string toupper [get_property SYNTH_CHECKPOINT_MODE $bd_obj]] ne "NONE"} {
    error "Failed to select global synthesis mode for design_1.bd"
}
reset_target all $bd_obj
generate_target all $bd_obj
set wrapper [file normalize [lindex [make_wrapper -files $bd_obj -top] 0]]
add_files -norecurse $wrapper

set_property top attention_board_top [get_filesets sources_1]
update_compile_order -fileset sources_1

# Vivado stages $readmemh inputs in the current directory during elaboration.
# Run from the generated build root so ROM copies never dirty the source tree.
set rtl_check_original_cwd [pwd]
file mkdir $fpt_build_root
if {[catch {
    cd $fpt_build_root
    synth_design -rtl -name rtl_profile_contract_check \
        -top attention_board_top -part $fpt_target_part
} rtl_check_message rtl_check_options]} {
    cd $rtl_check_original_cwd
    return -options $rtl_check_options $rtl_check_message
}
cd $rtl_check_original_cwd
close_design
close_project

puts "============================================================"
puts [format {[PASS] Current Attention RTL elaborated with Vivado %s} \
    [version -short]]
puts "Generated project: $fpt_project_file"
puts "BD mode: Global synthesis (SYNTH_CHECKPOINT_MODE=None)"
puts "============================================================"
