create_project b4_realip_xsim {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/xsim_project} -part xczu15eg-ffvb1156-2-i
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_1e1e6e0b/ip_project/b4_fp32_ip_gen.srcs/sources_1/ip/floating_point_0/floating_point_0.xci}
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_1e1e6e0b/ip_project/b4_fp32_ip_gen.srcs/sources_1/ip/floating_point_1/floating_point_1.xci}
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_1e1e6e0b/ip_project/b4_fp32_ip_gen.srcs/sources_1/ip/floating_point_2/floating_point_2.xci}
generate_target simulation [get_ips floating_point_0 floating_point_1 floating_point_2]
add_files -norecurse {{C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/qk/fp32_mul_ip.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/qk/fp32_add_ip.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/qk/fp32_to_bf16.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/softmax/exp_lut.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/softmax/unsigned_restoring_divider.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/softmax/cats_r4_row_softmax_compatibility.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/softmax/cats_r4_b2_compatibility_core_adapter.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/softmax/cats_r4_accuracy_exp_fixed.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/softmax/cats_r4_fp32_positive_add.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/softmax/cats_r4_fp32_row_reciprocal.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/softmax/cats_r4_row_softmax_accuracy.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/softmax/cats_r4_b2_locking_arbiter.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/softmax/cats_r4_b2_weight_stager.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/softmax/cats_r4_b2_shared_stager_v3_wrapper.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/pv/cats_r4_b3_pv_controller.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/pv/cats_r4_b3_pv_mac_32lane.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/pv/cats_r4_b3_pv_normalize_32lane.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/pv/cats_r4_b3_pv_32lane.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/rtl/core/bc/integration/cats_r4_b4_softmax_pv_cluster.sv}}
add_files -fileset sim_1 -norecurse {{C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/tb/tb_cats_r4_b4_c_weight_model.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/tb/tb_cats_r4_b4_multicluster.sv}}
add_files -fileset sim_1 -norecurse {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/mem/exp_lut_q15.mem}
set_property file_type {Memory File} [get_files -all {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/mem/exp_lut_q15.mem}]
set_property top tb_cats_r4_b4_multicluster [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
foreach clusters {1 2 4} {
    foreach mode {0 1} {
        set_property generic "CLUSTERS=$clusters GLOBAL_HEADS=4 ROWS_PER_HEAD=2 MODE=$mode SEED=3019898881 EXP_LUT_FILE=C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_fb604019/src/mem/exp_lut_q15.mem" [get_filesets sim_1]
        launch_simulation -simset sim_1 -mode behavioral
        run all
        close_sim
        puts "CATS_R4_B4_REALIP_XSIM_CONFIG_COMPLETE clusters=$clusters mode=$mode"
    }
}
puts "CATS_R4_B4_REALIP_XSIM_COMPLETE"
close_project