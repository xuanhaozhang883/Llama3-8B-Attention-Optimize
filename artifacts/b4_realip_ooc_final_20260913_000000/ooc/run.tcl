set ooc_project_dir {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_project}
set ooc_project_xpr [file join $ooc_project_dir b4_realip_ooc.xpr]
if {[catch {create_project b4_realip_ooc $ooc_project_dir -part xczu15eg-ffvb1156-2-i} create_error]} {
    if {![file exists $ooc_project_xpr]} {
        error "create_project failed without a project: $create_error"
    }
    puts "CATS_R4_B4_OOC_CREATE_PROJECT_RECOVERED $create_error"
    if {[llength [get_projects -quiet b4_realip_ooc]] == 0} {
        open_project $ooc_project_xpr
    }
}
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_1e1e6e0b/ip_project/b4_fp32_ip_gen.srcs/sources_1/ip/floating_point_0/floating_point_0.xci}
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_1e1e6e0b/ip_project/b4_fp32_ip_gen.srcs/sources_1/ip/floating_point_1/floating_point_1.xci}
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_1e1e6e0b/ip_project/b4_fp32_ip_gen.srcs/sources_1/ip/floating_point_2/floating_point_2.xci}
generate_target all [get_ips floating_point_0 floating_point_1 floating_point_2]
# The Active-HDL tclapp on this machine can make a partially-created project
# mark every add_files entry AutoDisabled.  Read the RTL directly into the
# current fileset so the HDL objects remain enabled even when create_project
# returned that recoverable tclapp error.
set_property source_mgmt_mode None [current_project]
foreach rtl_file [list {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/qk/fp32_mul_ip.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/qk/fp32_add_ip.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/qk/fp32_to_bf16.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/softmax/exp_lut.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/softmax/unsigned_restoring_divider.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/softmax/cats_r4_row_softmax_compatibility.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/softmax/cats_r4_b2_compatibility_core_adapter.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/softmax/cats_r4_accuracy_exp_fixed.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/softmax/cats_r4_fp32_positive_add.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/softmax/cats_r4_fp32_row_reciprocal.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/softmax/cats_r4_row_softmax_accuracy.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/softmax/cats_r4_b2_locking_arbiter.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/softmax/cats_r4_b2_weight_stager.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/softmax/cats_r4_b2_shared_stager_v3_wrapper.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/pv/cats_r4_b3_pv_controller.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/pv/cats_r4_b3_pv_mac_32lane.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/pv/cats_r4_b3_pv_normalize_32lane.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/pv/cats_r4_b3_pv_32lane.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/rtl/core/bc/integration/cats_r4_b4_softmax_pv_cluster.sv}] {
    if {[string match "*.sv" $rtl_file]} {
        read_verilog -sv $rtl_file
    } else {
        read_verilog $rtl_file
    }
}
if {[llength [get_files -quiet *exp_lut_q15.mem]] == 0} {
    add_files -norecurse {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/src/mem/exp_lut_q15.mem}
    set mem_file [lindex [get_files -quiet *exp_lut_q15.mem] 0]
}
if {[llength [get_files -quiet *exp_lut_q15.mem]] != 0} {
    set_property file_type {Memory File} [get_files -quiet *exp_lut_q15.mem]
}
read_xdc {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/cats_r4_b4_cluster_ooc.xdc}
set_property top cats_r4_b4_softmax_pv_cluster [current_fileset]
update_compile_order -fileset sources_1
synth_design -mode out_of_context -flatten_hierarchy none -top cats_r4_b4_softmax_pv_cluster -part xczu15eg-ffvb1156-2-i
write_checkpoint -force {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/cats_r4_b4_softmax_pv_cluster_synth.dcp}
report_utilization -hierarchical -file {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/synthesis_utilization.rpt}
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained -file {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/synthesis_timing_summary.rpt}
set synthesis_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $synthesis_paths] == 0} {
    error "CATS-R4 B4 OOC synthesis returned no timing path"
}
set synthesis_worst_slack [get_property SLACK [lindex $synthesis_paths 0]]
puts "CATS_R4_B4_REALIP_OOC_SYNTH_WNS=$synthesis_worst_slack"
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/cats_r4_b4_softmax_pv_cluster_ooc.dcp}
report_utilization -hierarchical -file {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/utilization.rpt}
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained -file {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/timing_summary.rpt}
report_timing -delay_type max -max_paths 20 -file {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/critical_paths.rpt}
report_route_status -file {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/route_status.rpt}
report_drc -file {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/drc.rpt}
report_power -file {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/power.rpt}
report_methodology -file {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_5d455469/ooc_results/methodology.rpt}
set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $timing_paths] == 0} {
    error "CATS-R4 B4 OOC returned no timing path"
}
set worst_slack [get_property SLACK [lindex $timing_paths 0]]
puts "CATS_R4_B4_REALIP_OOC_WNS=$worst_slack"
if {$worst_slack < 0.0} {
    puts "CATS_R4_B4_REALIP_OOC_FAIL_NEGATIVE_WNS"
} else {
    puts "CATS_R4_B4_REALIP_OOC_PASS"
}
close_project