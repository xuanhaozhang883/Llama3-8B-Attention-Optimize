create_project b4_realip_ooc {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/ooc_project} -part xczu15eg-ffvb1156-2-i
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_1e1e6e0b/ip_project/b4_fp32_ip_gen.srcs/sources_1/ip/floating_point_0/floating_point_0.xci}
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_1e1e6e0b/ip_project/b4_fp32_ip_gen.srcs/sources_1/ip/floating_point_1/floating_point_1.xci}
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_1e1e6e0b/ip_project/b4_fp32_ip_gen.srcs/sources_1/ip/floating_point_2/floating_point_2.xci}
generate_target all [get_ips floating_point_0 floating_point_1 floating_point_2]
add_files -norecurse {{C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/qk/fp32_mul_ip.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/qk/fp32_add_ip.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/qk/fp32_to_bf16.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/softmax/exp_lut.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/softmax/unsigned_restoring_divider.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/softmax/cats_r4_row_softmax_compatibility.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/softmax/cats_r4_b2_compatibility_core_adapter.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/softmax/cats_r4_accuracy_exp_fixed.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/softmax/cats_r4_fp32_positive_add.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/softmax/cats_r4_fp32_row_reciprocal.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/softmax/cats_r4_row_softmax_accuracy.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/softmax/cats_r4_b2_locking_arbiter.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/softmax/cats_r4_b2_weight_stager.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/softmax/cats_r4_b2_shared_stager_v3_wrapper.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/pv/cats_r4_b3_pv_controller.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/pv/cats_r4_b3_pv_mac_32lane.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/pv/cats_r4_b3_pv_normalize_32lane.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/pv/cats_r4_b3_pv_32lane.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/rtl/core/bc/integration/cats_r4_b4_softmax_pv_cluster.sv}}
add_files -norecurse {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/mem/exp_lut_q15.mem}
set_property file_type {Memory File} [get_files -all {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/src/mem/exp_lut_q15.mem}]
read_xdc {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/ooc_results/cats_r4_b4_cluster_ooc.xdc}
set_property top cats_r4_b4_softmax_pv_cluster [current_fileset]
update_compile_order -fileset sources_1
synth_design -mode out_of_context -flatten_hierarchy none -top cats_r4_b4_softmax_pv_cluster -part xczu15eg-ffvb1156-2-i
write_checkpoint -force {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/ooc_results/cats_r4_b4_softmax_pv_cluster_ooc.dcp}
report_utilization -hierarchical -file {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/ooc_results/utilization.rpt}
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained -file {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/ooc_results/timing_summary.rpt}
report_timing -delay_type max -max_paths 20 -file {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/ooc_results/critical_paths.rpt}
report_power -file {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/ooc_results/power.rpt}
report_methodology -file {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_cd0582d4/ooc_results/methodology.rpt}
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