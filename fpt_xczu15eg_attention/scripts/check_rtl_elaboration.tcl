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
set_property top attention_board_top [get_filesets sources_1]
update_compile_order -fileset sources_1
synth_design -rtl -name rtl_profile_contract_check \
    -top attention_board_top -part $fpt_target_part
close_design
close_project

puts "============================================================"
puts {[PASS] Current Attention RTL elaborated with Vivado 2024.2}
puts "Generated project: $fpt_project_file"
puts "============================================================"
