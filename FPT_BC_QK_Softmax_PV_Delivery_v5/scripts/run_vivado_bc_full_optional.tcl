# Optional long B+C direct integration run at the target dimensions.
set origin_dir [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $origin_dir vivado_bc_full_optional]
set part_name "xc7a35tcpg236-1"

catch {close_sim}
if {[llength [get_projects -quiet]] > 0} { close_project }
create_project fpt_bc_full_optional $project_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl_files [concat \
    [glob -nocomplain [file join $origin_dir rtl adapter *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl softmax *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl qk *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl qk *.v]] \
    [glob -nocomplain [file join $origin_dir rtl backend *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl integration *.sv]]]
add_files -norecurse $rtl_files

set sim_files [concat \
    [glob -nocomplain [file join $origin_dir sim_models *.sv]] \
    [list [file join $origin_dir tb tb_qk_softmax_pv_pipeline.sv]] \
    [list [file join $origin_dir rtl softmax exp_lut_q15.mem]]]
add_files -fileset sim_1 -norecurse $sim_files

set_property file_type SystemVerilog [get_files -quiet *.sv]
set_property file_type {Memory Initialization Files} \
    [get_files -quiet *exp_lut_q15.mem]
set_property top tb_qk_softmax_pv_pipeline_full_optional [get_filesets sim_1]
set_property xsim.simulate.runtime {1ns} [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "============================================================"
puts "RUNNING optional full B+C integration: Group 6"
puts "Expected: 65,536 probabilities and 2,097,152 PV input vectors"
puts "This test is substantially longer than the B-only full pipeline."
puts "============================================================"
launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
