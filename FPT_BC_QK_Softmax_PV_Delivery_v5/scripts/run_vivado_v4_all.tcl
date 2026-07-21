set origin_dir [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $origin_dir vivado_v4_sim]
set part_name "xc7a35tcpg236-1"

catch {close_sim}
if {[llength [get_projects -quiet]] > 0} { close_project }
create_project fpt_b_v4_sim $project_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl_files [concat \
    [glob -nocomplain [file join $origin_dir rtl adapter *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl softmax *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl qk *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl qk *.v]] \
    [glob -nocomplain [file join $origin_dir rtl integration *.sv]]]
add_files -norecurse $rtl_files

set sim_files [concat \
    [glob -nocomplain [file join $origin_dir sim_models *.sv]] \
    [glob -nocomplain [file join $origin_dir tb *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl softmax *.mem]] \
    [glob -nocomplain [file join $origin_dir data adapter_regression *.mem]] \
    [glob -nocomplain [file join $origin_dir data full_frontend *.mem]] \
    [glob -nocomplain [file join $origin_dir data real_qk_small *.mem]]]
add_files -fileset sim_1 -norecurse $sim_files

set_property file_type SystemVerilog [get_files -quiet *.sv]
foreach f [get_files -quiet *.mem] {
    set_property file_type {Memory Initialization Files} $f
}
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

# Prevent launch_simulation from running a test before the explicit run all.
set_property xsim.simulate.runtime {1ns} [get_filesets sim_1]

set tests [list \
    tb_causal_mask_stream \
    tb_score_rowtile_buffer \
    tb_qk_softmax_adapter \
    tb_softmax_metadata \
    tb_qk_softmax_adapter_file \
    tb_qk_softmax_frontend_small \
    tb_qk_softmax_reset_recovery \
    tb_qk_adapter_integration \
    tb_qk_softmax_pipeline_small \
    tb_qk_softmax_group_control \
    tb_qk_softmax_frontend_golden]

foreach test_name $tests {
    puts "============================================================"
    puts "RUNNING $test_name"
    puts "============================================================"
    set_property top $test_name [get_filesets sim_1]
    update_compile_order -fileset sim_1
    launch_simulation -simset sim_1 -mode behavioral
    run all
    close_sim
}
puts "============================================================"
puts "All v4 simulations finished. All eleven tests must print PASS."
puts "============================================================"
