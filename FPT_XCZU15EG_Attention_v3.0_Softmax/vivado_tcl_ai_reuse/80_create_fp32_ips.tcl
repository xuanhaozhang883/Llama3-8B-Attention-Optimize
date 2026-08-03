set fpt_ai_wrapper_dir [file normalize [file dirname [info script]]]
source [file join $fpt_ai_wrapper_dir _bootstrap.tcl]
::fpt_ai_tcl::require_vivado

if {[llength [get_projects -quiet]] != 1} {
    error "Open exactly one target Vivado project before creating FP32 IPs"
}

set fpt_ai_ip_script [file join $::fpt_ai_tcl::delivery_root scripts create_fp32_ips.tcl]
if {![file isfile $fpt_ai_ip_script]} {
    error "Missing canonical FP32 IP script: $fpt_ai_ip_script"
}
source $fpt_ai_ip_script
puts "\[PASS\] FP32 IP definitions generated in [current_project]"

