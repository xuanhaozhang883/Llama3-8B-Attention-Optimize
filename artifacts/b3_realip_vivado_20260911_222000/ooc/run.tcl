create_project b3_realip_ooc {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_dba79f6c45a5444e99cf62d974608f18/ooc_project} -part xczu15eg-ffvb1156-2-i
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_dba79f6c45a5444e99cf62d974608f18/ip_project/b3_fp32_ip_gen.srcs/sources_1/ip/floating_point_0/floating_point_0.xci}
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_dba79f6c45a5444e99cf62d974608f18/ip_project/b3_fp32_ip_gen.srcs/sources_1/ip/floating_point_1/floating_point_1.xci}
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_dba79f6c45a5444e99cf62d974608f18/ip_project/b3_fp32_ip_gen.srcs/sources_1/ip/floating_point_2/floating_point_2.xci}
generate_target all [get_ips floating_point_0 floating_point_1 floating_point_2]
add_files -norecurse {{C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_dba79f6c45a5444e99cf62d974608f18/src/rtl/core/bc/qk/fp32_mul_ip.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_dba79f6c45a5444e99cf62d974608f18/src/rtl/core/bc/qk/fp32_add_ip.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_dba79f6c45a5444e99cf62d974608f18/src/rtl/core/bc/qk/fp32_to_bf16.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_dba79f6c45a5444e99cf62d974608f18/src/rtl/core/bc/pv/cats_r4_b3_pv_controller.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_dba79f6c45a5444e99cf62d974608f18/src/rtl/core/bc/pv/cats_r4_b3_pv_mac_32lane.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_dba79f6c45a5444e99cf62d974608f18/src/rtl/core/bc/pv/cats_r4_b3_pv_normalize_32lane.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_dba79f6c45a5444e99cf62d974608f18/src/rtl/core/bc/pv/cats_r4_b3_pv_32lane.sv}}
read_xdc {D:/学习/FPT/artifacts/b3_realip_vivado_20260911_222000/ooc/cats_r4_b3_pv_ooc.xdc}
set_property top cats_r4_b3_pv_32lane [current_fileset]
update_compile_order -fileset sources_1
synth_design -mode out_of_context -top cats_r4_b3_pv_32lane -part xczu15eg-ffvb1156-2-i
write_checkpoint -force {D:/学习/FPT/artifacts/b3_realip_vivado_20260911_222000/ooc/cats_r4_b3_pv_32lane_ooc.dcp}
report_utilization -hierarchical -file {D:/学习/FPT/artifacts/b3_realip_vivado_20260911_222000/ooc/utilization.rpt}
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained -file {D:/学习/FPT/artifacts/b3_realip_vivado_20260911_222000/ooc/timing_summary.rpt}
report_methodology -file {D:/学习/FPT/artifacts/b3_realip_vivado_20260911_222000/ooc/methodology.rpt}
set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $timing_paths] == 0} {
    error "CATS-R4 B3 OOC returned no timing path"
}
set worst_slack [get_property SLACK [lindex $timing_paths 0]]
puts "CATS_R4_B3_REALIP_OOC_WNS=$worst_slack"
if {$worst_slack < 0.0} {
    error "CATS-R4 B3 OOC WNS is negative: $worst_slack"
}
puts "CATS_R4_B3_REALIP_OOC_PASS"
close_project