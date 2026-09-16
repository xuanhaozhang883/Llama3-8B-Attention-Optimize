create_project b4_fp32_ip_gen {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_9b5868cf/ip_project} -part xczu15eg-ffvb1156-2-i
set ::FPT_FP_IP_SYNTH_CHECKPOINT true
source {C:/Users/zhangxuanhao/AppData/Local/Temp/b4v_9b5868cf/src/scripts/create_fp32_ips.tcl}
set ip_runs {}
foreach ip_obj [get_ips floating_point_0 floating_point_1 floating_point_2] {
    set xci_file [get_files -quiet $ip_obj.xci]
    if {[llength $xci_file] != 1} {
        error "Expected one XCI for $ip_obj, got [llength $xci_file]"
    }
    lappend ip_runs [create_ip_run $xci_file]
}
launch_runs $ip_runs -jobs 3
foreach ip_run $ip_runs {
    wait_on_run $ip_run
    if {[get_property PROGRESS [get_runs $ip_run]] ne "100%"} {
        error "IP synthesis did not complete: $ip_run"
    }
}
puts "CATS_R4_B4_FP32_IP_GENERATION_PASS"
close_project