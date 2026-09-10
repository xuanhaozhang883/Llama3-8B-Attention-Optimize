lappend auto_path {C:/Software/AMD/vivado25.2/2025.2/Vivado/data/XilinxTclStore/support/appinit}
foreach app_dir [glob -nocomplain -types d {C:/Software/AMD/vivado25.2/2025.2/Vivado/data/XilinxTclStore/tclapp/*/*}] {
    lappend auto_path $app_dir
}
create_project realip_ooc {C:/lhm/2_Work/Llama3-8B-Attention-Optimize/a2ooc_both_env_0909/ooc/project} -part xczu15eg-ffvb1156-2-i
read_ip {C:/lhm/2_Work/Llama3-8B-Attention-Optimize/a2ooc_both_env_0909/ip_gen/project/fp32_ip_gen.srcs/sources_1/ip/floating_point_0/floating_point_0.xci}
read_ip {C:/lhm/2_Work/Llama3-8B-Attention-Optimize/a2ooc_both_env_0909/ip_gen/project/fp32_ip_gen.srcs/sources_1/ip/floating_point_1/floating_point_1.xci}
read_ip {C:/lhm/2_Work/Llama3-8B-Attention-Optimize/a2ooc_both_env_0909/ip_gen/project/fp32_ip_gen.srcs/sources_1/ip/floating_point_2/floating_point_2.xci}
generate_target all [get_ips floating_point_0 floating_point_1 floating_point_2]
add_files -norecurse {C:/lhm/2_Work/Llama3-8B-Attention-Optimize-a2/rtl/core/bc/qk/bf16_to_fp32.v}
add_files -norecurse {C:/lhm/2_Work/Llama3-8B-Attention-Optimize-a2/rtl/core/bc/qk/fp32_mul_ip.v}
add_files -norecurse {C:/lhm/2_Work/Llama3-8B-Attention-Optimize-a2/rtl/core/bc/qk/fp32_add_ip.v}
add_files -norecurse {C:/lhm/2_Work/Llama3-8B-Attention-Optimize-a2/rtl/core/bc/qk/cats_r4_qk_32lane_scheduler.sv}
add_files -norecurse {C:/lhm/2_Work/Llama3-8B-Attention-Optimize-a2/rtl/core/bc/qk/cats_r4_qk_32lane_fp32_service.sv}
add_files -norecurse {C:/lhm/2_Work/Llama3-8B-Attention-Optimize-a2/rtl/core/bc/qk/cats_r4_qk_32lane_engine.sv}
set_property top cats_r4_qk_32lane_engine [current_fileset]
update_compile_order -fileset sources_1
synth_design -mode out_of_context -top cats_r4_qk_32lane_engine -part xczu15eg-ffvb1156-2-i
create_clock -name core_clk -period 6.666 [get_ports clk]
report_timing_summary -delay_type max -max_paths 10 -file {C:/lhm/2_Work/Llama3-8B-Attention-Optimize/a2ooc_both_env_0909/ooc/timing_summary.rpt}
report_utilization -file {C:/lhm/2_Work/Llama3-8B-Attention-Optimize/a2ooc_both_env_0909/ooc/utilization.rpt}
puts "OOC_ENGINE_REALIP_SYNTH_PASS"