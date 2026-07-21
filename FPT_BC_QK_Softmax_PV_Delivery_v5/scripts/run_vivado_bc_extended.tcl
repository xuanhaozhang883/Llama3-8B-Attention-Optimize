# Extended B+C regression for Vivado/XSim 2019.2 or newer.
set origin_dir [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $origin_dir vivado_bc_extended_sim]
set part_name "xc7a35tcpg236-1"

catch {close_sim}
if {[llength [get_projects -quiet]] > 0} { close_project }
create_project fpt_bc_extended_sim $project_dir -part $part_name -force
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
    [list [file join $origin_dir tb tb_bc_robustness.sv]] \
    [list [file join $origin_dir tb tb_qk_softmax_pv_all_groups.sv]] \
    [list [file join $origin_dir rtl softmax exp_lut_q15.mem]]]
add_files -fileset sim_1 -norecurse $sim_files
set_property file_type SystemVerilog [get_files -quiet *.sv]
set_property file_type {Memory Initialization Files} \
    [get_files -quiet *exp_lut_q15.mem]
set_property xsim.simulate.runtime {1ns} [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

proc run_bc_test {top_name title} {
    puts "============================================================"
    puts "RUNNING: $title"
    puts "============================================================"
    set_property top $top_name [get_filesets sim_1]
    update_compile_order -fileset sim_1
    launch_simulation -simset sim_1 -mode behavioral
    run all
    close_sim
}

run_bc_test tb_bc_invalid_group_id \
    "illegal Group ID rejection"
run_bc_test tb_bc_reset_and_busy \
    "busy-start guard and three B+C reset points"
run_bc_test tb_qk_softmax_pv_all_groups \
    "Groups 0..7 with controller and synthesizable V-cache"

puts "PASS: all extended B+C regressions completed"
