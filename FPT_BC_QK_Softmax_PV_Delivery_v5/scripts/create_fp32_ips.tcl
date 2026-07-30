# Create the three Floating Point Operator IP modules expected by fp32_*_ip.v.
# Run inside an open Vivado project. The helper only sets properties that exist
# in the installed IP version, which makes the script more tolerant of Vivado
# point-release differences.
proc set_ip_cfg_if_available {ip_name key value} {
    set ip_obj [get_ips $ip_name]
    set prop_name "CONFIG.$key"
    if {[lsearch -exact [list_property $ip_obj] $prop_name] >= 0} {
        set_property $prop_name $value $ip_obj
    } else {
        puts "WARNING: $ip_name does not expose $prop_name in this Vivado version"
    }
}

proc create_fp_binary_ip {module_name operation} {
    if {[llength [get_ips -quiet $module_name]] == 0} {
        create_ip -name floating_point -vendor xilinx.com -library ip -module_name $module_name
    }
    set_ip_cfg_if_available $module_name Operation_Type $operation
    if {$operation eq "Add_Subtract"} {
        set_ip_cfg_if_available $module_name Add_Sub_Value Add
    }
    set_ip_cfg_if_available $module_name A_Precision_Type Single
    set_ip_cfg_if_available $module_name B_Precision_Type Single
    set_ip_cfg_if_available $module_name Result_Precision_Type Single
    set_ip_cfg_if_available $module_name Flow_Control Blocking
    set_ip_cfg_if_available $module_name Has_ACLKEN true
    set_ip_cfg_if_available $module_name Has_ARESETn true
    set_ip_cfg_if_available $module_name Has_A_TREADY true
    set_ip_cfg_if_available $module_name Has_B_TREADY true
    set_ip_cfg_if_available $module_name Has_RESULT_TREADY true
    set_ip_cfg_if_available $module_name C_Rate 1
    # Include the floating-point implementation in the top-level synthesis.
    # The default per-IP OOC flow leaves black boxes in the top synthesis
    # report, which omits their resources and timing paths.
    set ip_obj [get_ips $module_name]
    if {[lsearch -exact [list_property $ip_obj] GENERATE_SYNTH_CHECKPOINT] >= 0} {
        set_property GENERATE_SYNTH_CHECKPOINT false $ip_obj
    } else {
        set ip_file [get_files -quiet ${module_name}.xci]
        if {[llength $ip_file] == 0} {
            error "Cannot locate the XCI file for $module_name"
        }
        set_property GENERATE_SYNTH_CHECKPOINT false $ip_file
    }
    # Fixed latency is not assumed by the RTL; ready/valid handshakes absorb it.
    generate_target all [get_ips $module_name]
}

create_fp_binary_ip floating_point_0 Multiply
create_fp_binary_ip floating_point_1 Add_Subtract
create_fp_binary_ip floating_point_2 Multiply
