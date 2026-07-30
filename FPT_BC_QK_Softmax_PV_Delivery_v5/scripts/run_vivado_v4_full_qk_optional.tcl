set origin_dir [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $origin_dir vivado_v4_full_qk_optional]
set part_name "xc7a35tcpg236-1"

catch {close_sim}
if {[llength [get_projects -quiet]] > 0} { close_project }
create_project fpt_b_v4_full_qk_optional $project_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

add_files -norecurse [concat \
    [glob -nocomplain [file join $origin_dir rtl adapter *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl qk *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl qk *.v]]]
add_files -fileset sim_1 -norecurse [concat \
    [glob -nocomplain [file join $origin_dir sim_models *.sv]] \
    [list [file join $origin_dir tb tb_qk_adapter_integration_full_optional.sv]] \
    [glob -nocomplain [file join $origin_dir data full_qk_optional *.hex]]]
set_property file_type SystemVerilog [get_files -quiet *.sv]
foreach f [get_files -quiet *.hex] {
    set_property file_type {Memory Initialization Files} $f
}
set_property top tb_qk_adapter_integration_full_optional [get_filesets sim_1]
set_property xsim.simulate.runtime {1ns} [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "WARNING: this full real-QK behavioral test can be much slower than the default suite."
launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
