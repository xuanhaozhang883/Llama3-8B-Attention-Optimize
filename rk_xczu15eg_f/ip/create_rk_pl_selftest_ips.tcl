# Create every Xilinx IP instance required by the RK PL-only self-test.
# Run inside an open project targeting xczu15eg-ffvb1156-2-i.

set ip_script_dir [file normalize [file dirname [info script]]]
set ip_repo_root  [file normalize [file join $ip_script_dir .. ..]]
set ip_bc_root    [file join $ip_repo_root FPT_BC_QK_Softmax_PV_Delivery_v5]

proc rk_set_ip_cfg_if_available {ip_name key value} {
    set ip_obj [get_ips $ip_name]
    set prop_name "CONFIG.$key"
    if {[lsearch -exact [list_property $ip_obj] $prop_name] >= 0} {
        set_property $prop_name $value $ip_obj
    } else {
        puts "WARNING: $ip_name does not expose $prop_name"
    }
}

proc rk_disable_ip_synth_checkpoint {ip_name} {
    set ip_obj [get_ips $ip_name]
    if {[lsearch -exact [list_property $ip_obj] \
        GENERATE_SYNTH_CHECKPOINT] >= 0} {
        set_property GENERATE_SYNTH_CHECKPOINT false $ip_obj
    } else {
        set ip_file [get_files -quiet ${ip_name}.xci]
        if {[llength $ip_file] != 1} {
            error "Cannot locate the XCI file for $ip_name"
        }
        set_property GENERATE_SYNTH_CHECKPOINT false $ip_file
    }
}

update_ip_catalog

# The production arithmetic wrappers instantiate these exact module names.
source [file join $ip_bc_root scripts create_fp32_ips.tcl]

if {[llength [get_ips -quiet rk_pl_clk_wiz]] == 0} {
    create_ip -name clk_wiz -vendor xilinx.com -library ip \
        -module_name rk_pl_clk_wiz
}
rk_set_ip_cfg_if_available rk_pl_clk_wiz PRIM_SOURCE Differential_clock_capable_pin
rk_set_ip_cfg_if_available rk_pl_clk_wiz PRIM_IN_FREQ 200.000
rk_set_ip_cfg_if_available rk_pl_clk_wiz CLKOUT1_REQUESTED_OUT_FREQ 100.000
rk_set_ip_cfg_if_available rk_pl_clk_wiz USE_LOCKED true
rk_set_ip_cfg_if_available rk_pl_clk_wiz USE_RESET true
rk_set_ip_cfg_if_available rk_pl_clk_wiz RESET_TYPE ACTIVE_HIGH
rk_disable_ip_synth_checkpoint rk_pl_clk_wiz
generate_target all [get_ips rk_pl_clk_wiz]

if {[llength [get_ips -quiet rk_selftest_vio]] == 0} {
    create_ip -name vio -vendor xilinx.com -library ip \
        -module_name rk_selftest_vio
}
rk_set_ip_cfg_if_available rk_selftest_vio C_NUM_PROBE_IN 7
rk_set_ip_cfg_if_available rk_selftest_vio C_NUM_PROBE_OUT 1
rk_set_ip_cfg_if_available rk_selftest_vio C_PROBE_IN0_WIDTH 1
rk_set_ip_cfg_if_available rk_selftest_vio C_PROBE_IN1_WIDTH 1
rk_set_ip_cfg_if_available rk_selftest_vio C_PROBE_IN2_WIDTH 1
rk_set_ip_cfg_if_available rk_selftest_vio C_PROBE_IN3_WIDTH 1
rk_set_ip_cfg_if_available rk_selftest_vio C_PROBE_IN4_WIDTH 64
rk_set_ip_cfg_if_available rk_selftest_vio C_PROBE_IN5_WIDTH 17
rk_set_ip_cfg_if_available rk_selftest_vio C_PROBE_IN6_WIDTH 17
rk_set_ip_cfg_if_available rk_selftest_vio C_PROBE_OUT0_WIDTH 1
rk_set_ip_cfg_if_available rk_selftest_vio C_PROBE_OUT0_INIT_VAL 0x0
rk_disable_ip_synth_checkpoint rk_selftest_vio
generate_target all [get_ips rk_selftest_vio]

if {[llength [get_ips -quiet rk_selftest_ila]] == 0} {
    create_ip -name ila -vendor xilinx.com -library ip \
        -module_name rk_selftest_ila
}
rk_set_ip_cfg_if_available rk_selftest_ila C_NUM_OF_PROBES 9
rk_set_ip_cfg_if_available rk_selftest_ila C_DATA_DEPTH 1024
rk_set_ip_cfg_if_available rk_selftest_ila C_PROBE0_WIDTH 1
rk_set_ip_cfg_if_available rk_selftest_ila C_PROBE1_WIDTH 1
rk_set_ip_cfg_if_available rk_selftest_ila C_PROBE2_WIDTH 1
rk_set_ip_cfg_if_available rk_selftest_ila C_PROBE3_WIDTH 1
rk_set_ip_cfg_if_available rk_selftest_ila C_PROBE4_WIDTH 1
rk_set_ip_cfg_if_available rk_selftest_ila C_PROBE5_WIDTH 1
rk_set_ip_cfg_if_available rk_selftest_ila C_PROBE6_WIDTH 1
rk_set_ip_cfg_if_available rk_selftest_ila C_PROBE7_WIDTH 1
rk_set_ip_cfg_if_available rk_selftest_ila C_PROBE8_WIDTH 1
rk_disable_ip_synth_checkpoint rk_selftest_ila
generate_target all [get_ips rk_selftest_ila]

puts "RK_SELFTEST_IP_READY=1"
