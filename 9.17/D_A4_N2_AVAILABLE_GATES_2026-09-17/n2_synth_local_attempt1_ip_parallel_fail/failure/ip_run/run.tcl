create_project a3_fp32_ip_gen {C:/Users/23858/AppData/Local/Temp/a3v_f1d817fbe2dd453583af22bc8a4c4e3d/ip_project} -part xczu15eg-ffvb1156-2-i
set ::FPT_FP_IP_SYNTH_CHECKPOINT true
source {C:/Users/23858/AppData/Local/Temp/a3v_f1d817fbe2dd453583af22bc8a4c4e3d/src/scripts/create_fp32_ips.tcl}
set ip_runs {}
foreach ip_obj [get_ips floating_point_0 floating_point_1 floating_point_2] { set xci [get_files -quiet $ip_obj.xci]; lappend ip_runs [create_ip_run $xci] }
launch_runs $ip_runs -jobs 3
foreach ip_run $ip_runs { wait_on_run $ip_run; if {[get_property PROGRESS [get_runs $ip_run]] ne "100%"} { error "IP synthesis incomplete: $ip_run" } }
puts "CATS_R4_A3_FP32_IP_GENERATION_PASS"
close_project