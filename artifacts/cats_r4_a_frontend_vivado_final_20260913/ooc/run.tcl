create_project a_frontend_realip_ooc {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/ooc_project} -part xczu15eg-ffvb1156-2-i
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_754158a5/ip_project/a_frontend_fp32_ip_gen.srcs/sources_1/ip/floating_point_0/floating_point_0.xci}
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_754158a5/ip_project/a_frontend_fp32_ip_gen.srcs/sources_1/ip/floating_point_1/floating_point_1.xci}
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_754158a5/ip_project/a_frontend_fp32_ip_gen.srcs/sources_1/ip/floating_point_2/floating_point_2.xci}
generate_target all [get_ips floating_point_0 floating_point_1 floating_point_2]
add_files -norecurse {{C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/bf16_to_fp32.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/fp32_to_bf16.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/fp32_mul_ip.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/fp32_add_ip.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/cats_r4_qk_score_formatter.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/cats_r4_qk_row_assembler.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/cats_r4_qk_ab_handoff.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/cats_r4_qk_slot_lifecycle.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/cats_r4_qk_row_abort_arbiter.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/cats_r4_qk_row_handoff_wrapper.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/cats_r4_qk_a2_row_pipeline.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/cats_r4_qk_q_slab_client.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/cats_r4_qk_32lane_scheduler.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/cats_r4_qk_32lane_fp32_service.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/bc/qk/cats_r4_qk_32lane_engine.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/src/rtl/core/cluster/cats_r4_compute_frontend.sv}}
read_xdc {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/ooc_results/cats_r4_compute_frontend_ooc.xdc}
set_property top cats_r4_compute_frontend [current_fileset]
update_compile_order -fileset sources_1
synth_design -mode out_of_context -flatten_hierarchy none -top cats_r4_compute_frontend -part xczu15eg-ffvb1156-2-i
write_checkpoint -force {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/ooc_results/cats_r4_compute_frontend_ooc.dcp}
report_utilization -hierarchical -file {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/ooc_results/utilization.rpt}
report_timing_summary -delay_type min_max -max_paths 20 -report_unconstrained -file {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/ooc_results/timing_summary.rpt}
report_cdc -details -file {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/ooc_results/cdc.rpt}
report_clock_interaction -delay_type min_max -file {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/ooc_results/clock_interaction.rpt}
set check_timing_text [check_timing -verbose -return_string]
set check_timing_file [open {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/ooc_results/check_timing.rpt} w]
puts $check_timing_file $check_timing_text
close $check_timing_file
report_methodology -file {C:/Users/zhangxuanhao/AppData/Local/Temp/a_frontend_vivado_853f7cee/ooc_results/methodology.rpt}
set timing_paths [get_timing_paths -delay_type max -max_paths 1]
if {[llength $timing_paths] == 0} {
    error "frontend OOC returned no timing path"
}
set worst_slack [get_property SLACK [lindex $timing_paths 0]]
puts "CATS_R4_A_FRONTEND_REALIP_OOC_WNS=$worst_slack"
if {$worst_slack < 0.0} {
    error "CATS_R4_A_FRONTEND_REALIP_OOC_NEGATIVE_WNS"
}
puts "CATS_R4_A_FRONTEND_REALIP_OOC_PASS"
close_project