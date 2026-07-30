# Synthesize / implement the Adapter + Softmax frontend only.
# Default target is the same provisional Artix-7 part used by the team tests.
set origin_dir  [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $origin_dir vivado_synth_frontend]
set report_dir  [file join $origin_dir reports frontend_only]
set part_name   "xc7a35tcpg236-1"
set jobs        4
file mkdir $report_dir

if {[llength [get_projects -quiet]] > 0} { close_project }
create_project fpt_b_frontend_synth $project_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl_files [concat \
    [glob -nocomplain [file join $origin_dir rtl adapter *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl softmax *.sv]] \
    [list [file join $origin_dir rtl integration qk_softmax_frontend.sv]]]
add_files -norecurse $rtl_files
add_files -norecurse [file join $origin_dir rtl softmax exp_lut_q15.mem]
add_files -fileset constrs_1 -norecurse [file join $origin_dir constraints qk_softmax_100mhz.xdc]
set_property file_type SystemVerilog [get_files -quiet *.sv]
set_property file_type {Memory Initialization Files} [get_files -quiet *exp_lut_q15.mem]
set_property top qk_softmax_frontend [get_filesets sources_1]
update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Frontend synthesis did not complete: [get_property STATUS [get_runs synth_1]]"
}
open_run synth_1
report_utilization -hierarchical -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type max -report_unconstrained -file [file join $report_dir post_synth_timing.rpt]
write_checkpoint -force [file join $report_dir frontend_post_synth.dcp]

reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Frontend implementation did not complete: [get_property STATUS [get_runs impl_1]]"
}
open_run impl_1
report_utilization -hierarchical -file [file join $report_dir post_route_utilization.rpt]
report_timing_summary -delay_type max -report_unconstrained -file [file join $report_dir post_route_timing.rpt]
report_drc -file [file join $report_dir post_route_drc.rpt]
catch {report_methodology -file [file join $report_dir post_route_methodology.rpt]}
catch {report_power -file [file join $report_dir post_route_power.rpt]}
write_checkpoint -force [file join $report_dir frontend_post_route.dcp]
puts "PASS: frontend synthesis and implementation completed"
puts "Reports: $report_dir"
