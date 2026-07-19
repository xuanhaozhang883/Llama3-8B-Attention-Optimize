set origin_dir [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $origin_dir vivado_v4_full_pipeline_optional]
set part_name "xc7a35tcpg236-1"

catch {close_sim}
if {[llength [get_projects -quiet]] > 0} { close_project }
create_project fpt_b_v4_full_pipeline_optional $project_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -norecurse [concat \
    [glob -nocomplain [file join $origin_dir rtl adapter *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl softmax *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl qk *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl qk *.v]] \
    [list [file join $origin_dir rtl integration qk_softmax_frontend.sv]] \
    [list [file join $origin_dir rtl integration qk_softmax_pipeline_top.sv]]]

add_files -fileset sim_1 -norecurse [concat \
    [glob -nocomplain [file join $origin_dir sim_models *.sv]] \
    [list [file join $origin_dir tb tb_qk_softmax_pipeline_full_optional.sv]] \
    [glob -nocomplain [file join $origin_dir data full_qk_optional *.hex]] \
    [list [file join $origin_dir data full_frontend full_expected_probs_fp32.mem]] \
    [list [file join $origin_dir rtl softmax exp_lut_q15.mem]]]

set_property file_type SystemVerilog [get_files -quiet *.sv]
foreach f [concat [get_files -quiet *.hex] [get_files -quiet *.mem]] {
    set_property file_type {Memory Initialization Files} $f
}

set_property top tb_qk_softmax_pipeline_full_optional [get_filesets sim_1]
set_property xsim.simulate.runtime {1ns} [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "============================================================"
puts "RUNNING full selected-group real QK -> Causal Mask -> Row Tile Buffer -> Softmax"
puts "This is a long behavioral simulation. The test prints progress every 8192 probabilities."
puts "Expected final count: 65536 QK scores, 65536 probabilities, 512 rows."
puts "============================================================"

launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
