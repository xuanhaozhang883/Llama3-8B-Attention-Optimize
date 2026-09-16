create_project b3_realip_xsim {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_169fac5f513d469698e7709e6cc1b558/xsim_project} -part xczu15eg-ffvb1156-2-i
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_169fac5f513d469698e7709e6cc1b558/ip_project/b3_fp32_ip_gen.srcs/sources_1/ip/floating_point_0/floating_point_0.xci}
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_169fac5f513d469698e7709e6cc1b558/ip_project/b3_fp32_ip_gen.srcs/sources_1/ip/floating_point_1/floating_point_1.xci}
read_ip {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_169fac5f513d469698e7709e6cc1b558/ip_project/b3_fp32_ip_gen.srcs/sources_1/ip/floating_point_2/floating_point_2.xci}
generate_target simulation [get_ips floating_point_0 floating_point_1 floating_point_2]
add_files -norecurse {{C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_169fac5f513d469698e7709e6cc1b558/src/rtl/core/bc/qk/fp32_mul_ip.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_169fac5f513d469698e7709e6cc1b558/src/rtl/core/bc/qk/fp32_add_ip.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_169fac5f513d469698e7709e6cc1b558/src/rtl/core/bc/qk/fp32_to_bf16.v} {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_169fac5f513d469698e7709e6cc1b558/src/rtl/core/bc/pv/cats_r4_b3_pv_controller.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_169fac5f513d469698e7709e6cc1b558/src/rtl/core/bc/pv/cats_r4_b3_pv_mac_32lane.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_169fac5f513d469698e7709e6cc1b558/src/rtl/core/bc/pv/cats_r4_b3_pv_normalize_32lane.sv} {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_169fac5f513d469698e7709e6cc1b558/src/rtl/core/bc/pv/cats_r4_b3_pv_32lane.sv}}
add_files -fileset sim_1 -norecurse {C:/Users/zhangxuanhao/AppData/Local/Temp/cats_r4_b3_vivado_169fac5f513d469698e7709e6cc1b558/src/tb/tb_cats_r4_b3_pv_32lane.sv}
set_property top tb_cats_r4_b3_pv_32lane [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
puts "CATS_R4_B3_REALIP_XSIM_PASS"
close_project