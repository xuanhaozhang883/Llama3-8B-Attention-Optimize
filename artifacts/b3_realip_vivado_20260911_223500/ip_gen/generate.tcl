create_project b3_fp32_ip_gen {C:/Users/zhangxuanhao/AppData/Local/Temp/b3v_257158c6/ip_project} -part xczu15eg-ffvb1156-2-i
set ::FPT_FP_IP_SYNTH_CHECKPOINT true
source {C:/Users/zhangxuanhao/AppData/Local/Temp/b3v_257158c6/src/scripts/create_fp32_ips.tcl}
set ip_runs {}
foreach ip_obj [get_ips floating_point_0 floating_point_1 floating_point_2] {
    lappend ip_runs [create_ip_run [get_files -of_objects $ip_obj]]
}
launch_runs $ip_runs -jobs 3
foreach ip_run $ip_runs {
    wait_on_run $ip_run
    if {[get_property PROGRESS [get_runs $ip_run]] ne "100%"} {
        error "IP synthesis did not complete: $ip_run"
    }
}
puts "CATS_R4_B3_FP32_IP_GENERATION_PASS"
close_project