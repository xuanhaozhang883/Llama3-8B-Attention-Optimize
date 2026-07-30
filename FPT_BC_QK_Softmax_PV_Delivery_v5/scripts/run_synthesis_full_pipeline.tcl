# Synthesize / implement real QK + Adapter + Softmax.
# WARNING: TILE=4 FP32 QK can exceed the provisional xc7a35t device resources.
set origin_dir  [file normalize [file join [file dirname [info script]] ..]]
set project_dir [file join $origin_dir vivado_synth_full]
set report_dir  [file join $origin_dir reports full_qk_frontend]
set part_name   "xc7a35tcpg236-1"
set jobs        4
file mkdir $report_dir

if {[llength [get_projects -quiet]] > 0} { close_project }
create_project fpt_b_full_synth $project_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl_files [concat \
    [glob -nocomplain [file join $origin_dir rtl adapter *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl softmax *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl qk *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl qk *.v]] \
    [glob -nocomplain [file join $origin_dir rtl integration *.sv]]]
add_files -norecurse $rtl_files
add_files -norecurse [file join $origin_dir rtl softmax exp_lut_q15.mem]
add_files -fileset constrs_1 -norecurse [file join $origin_dir constraints qk_softmax_100mhz.xdc]
set_property file_type SystemVerilog [get_files -quiet *.sv]
set_property file_type {Memory Initialization Files} [get_files -quiet *exp_lut_q15.mem]

# Creates floating_point_0/1/2 with AXI-stream ready/valid interfaces.
source [file join $origin_dir scripts create_fp32_ips.tcl]
set_property top qk_softmax_pipeline_top [get_filesets sources_1]
update_compile_order -fileset sources_1

reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "Full-pipeline synthesis did not complete: [get_property STATUS [get_runs synth_1]]"
}
open_run synth_1
report_utilization -hierarchical -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type max -report_unconstrained -file [file join $report_dir post_synth_timing.rpt]
write_checkpoint -force [file join $report_dir full_post_synth.dcp]

reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "Full-pipeline implementation did not complete: [get_property STATUS [get_runs impl_1]]"
}
open_run impl_1
report_utilization -hierarchical -file [file join $report_dir post_route_utilization.rpt]
report_timing_summary -delay_type max -report_unconstrained -file [file join $report_dir post_route_timing.rpt]
report_drc -file [file join $report_dir post_route_drc.rpt]
catch {report_methodology -file [file join $report_dir post_route_methodology.rpt]}
catch {report_power -file [file join $report_dir post_route_power.rpt]}
write_checkpoint -force [file join $report_dir full_post_route.dcp]
puts "PASS: full-pipeline synthesis and implementation completed"
puts "Reports: $report_dir"
