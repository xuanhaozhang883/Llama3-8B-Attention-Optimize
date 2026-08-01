# Rebuild the independent XCZU15EG Attention board project from sources.
# Vivado 2024.2 target: xczu15eg-ffvb1156-2-i

set script_dir [file normalize [file dirname [info script]]]
set board_root [file normalize [file join $script_dir ..]]
source [file join $script_dir project_config.tcl]
source [file join $script_dir source_manifest.tcl]

set part_name $fpt_target_part
if {[llength [get_parts -quiet $part_name]] != 1} {
    error "Required device is not installed: $part_name"
}

set project_name $fpt_project_name
set project_dir $fpt_project_dir
# Keep a clean staging copy beside the short generated project. The imported
# 2020.2 BD contains generation-path metadata from its original project; patch
# only this staging copy before Vivado opens it.
set bd_work_parent [file join $fpt_build_root bd_staging]
set bd_work_dir [file join $bd_work_parent design_1]
set bd_file [file join $bd_work_dir design_1.bd]

proc fpt_read_text {path} {
    set stream [open $path r]
    fconfigure $stream -translation binary
    set data [read $stream]
    close $stream
    return $data
}

proc fpt_write_text {path data} {
    set stream [open $path w]
    fconfigure $stream -translation binary
    puts -nonewline $stream $data
    close $stream
}

proc fpt_patch_bd_generation_paths {bd_file project_dir project_name} {
    set bd_gen_dir [file normalize [file join \
        $project_dir ${project_name}.gen sources_1 bd design_1]]

    set bd_text [fpt_read_text $bd_file]
    set count [regsub -all \
        {("gen_directory"[[:space:]]*:[[:space:]]*")[^"]*(")} \
        $bd_text "\\1$bd_gen_dir\\2" bd_text]
    if {$count != 1} {
        error "Expected exactly one gen_directory entry in $bd_file; found $count"
    }
    fpt_write_text $bd_file $bd_text

    set xci_files [glob -nocomplain -types f \
        [file join [file dirname $bd_file] ip * *.xci]]
    if {[llength $xci_files] == 0} {
        error "No imported BD XCI files found beside $bd_file"
    }
    foreach xci $xci_files {
        set ip_name [file rootname [file tail $xci]]
        set ip_output [file join $bd_gen_dir ip $ip_name]
        set xci_text [fpt_read_text $xci]
        set count [regsub -all \
            {(<spirit:configurableElementValue spirit:referenceId="RUNTIME_PARAM[.]OUTPUTDIR">)[^<]*(</spirit:configurableElementValue>)} \
            $xci_text "\\1$ip_output\\2" xci_text]
        if {$count != 1} {
            error "Expected one RUNTIME_PARAM.OUTPUTDIR entry in $xci; found $count"
        }
        fpt_write_text $xci $xci_text
    }

    foreach staged_file [concat [list $bd_file] $xci_files] {
        set staged_text [fpt_read_text $staged_file]
        if {[string first "pl_read_write_ps_ddr" $staged_text] >= 0} {
            error "Stale source-project path remains in $staged_file"
        }
    }
    puts "Patched imported BD generation root: $bd_gen_dir"
    return $bd_gen_dir
}

catch {close_design}
if {[llength [get_projects -quiet]] > 0} { close_project }
file mkdir [file dirname $project_dir]
# Remove only the generated project from a previous failed/repeated run.
if {[file exists $project_dir]} {
    file delete -force $project_dir
}
create_project $project_name $project_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

# Copy the vendor-verified PS configuration into this independent project.
file delete -force $bd_work_parent
file mkdir $bd_work_parent
file copy -force [file join $board_root bd_base design_1] $bd_work_parent
set bd_gen_dir [fpt_patch_bd_generation_paths \
    $bd_file $project_dir $project_name]
add_files -norecurse $bd_file
open_bd_design $bd_file

# Upgrade the two imported vendor IPs from Vivado 2020.2 to the local release.
# Vivado 2025.2 adds unused PS PCIe high-address blocks while moving the PS IP
# from 3.3 to 3.5 and reports Coretcl 2-1280.  The active HPM interface, clock,
# reset and AXI GPIO address are explicitly reapplied and validated below.
#
# Only that PS IP, only on Vivado 2025.2, receives the known diagnostic as a
# warning.  Other IPs are upgraded at normal severity, and any Tcl error from
# upgrade_ip remains fatal.  Restore normal severity immediately afterwards.
set old_ips [get_ips -quiet]
if {[llength $old_ips] > 0} {
    set fpt_ps_upgrade_ips [list]
    set fpt_other_upgrade_ips [list]
    foreach fpt_old_ip $old_ips {
        set fpt_ipdef [get_property IPDEF $fpt_old_ip]
        if {[string match *:zynq_ultra_ps_e:* $fpt_ipdef]} {
            lappend fpt_ps_upgrade_ips $fpt_old_ip
        } else {
            lappend fpt_other_upgrade_ips $fpt_old_ip
        }
    }

    if {[llength $fpt_other_upgrade_ips] > 0} {
        upgrade_ip $fpt_other_upgrade_ips
    }

    if {[llength $fpt_ps_upgrade_ips] != 1} {
        error "Expected exactly one zynq_ultra_ps_e IP; found [llength $fpt_ps_upgrade_ips]"
    }
    if {[llength $fpt_ps_upgrade_ips] == 1} {
        if {[string equal [version -short] "2025.2"]} {
            set fpt_known_upgrade_message {Coretcl 2-1280}
            set_msg_config -id $fpt_known_upgrade_message \
                -new_severity WARNING
            set fpt_upgrade_failed [catch {
                upgrade_ip $fpt_ps_upgrade_ips
            } fpt_upgrade_message fpt_upgrade_options]
            set_msg_config -id $fpt_known_upgrade_message \
                -new_severity {CRITICAL WARNING}
            if {$fpt_upgrade_failed} {
                return -options $fpt_upgrade_options $fpt_upgrade_message
            }
        } else {
            upgrade_ip $fpt_ps_upgrade_ips
        }
    }
}

set ps [get_bd_cells zynq_ultra_ps_e_0]
if {[llength $ps] != 1} { error "Vendor PS cell zynq_ultra_ps_e_0 not found" }

# Enable the PS -> PL control master used by the AXI GPIO mailbox.
# In Zynq UltraScale+ MPSoC configuration, the legacy GP2 property exposes
# M_AXI_HPM0_LPD (not M_AXI_HPM0_FPD).  Vivado 2024.2 reports the actual
# interface after the PS IP is upgraded, so resolve it explicitly and retain
# a guarded FPD fallback for compatible source variants.
set_property CONFIG.PSU__USE__M_AXI_GP2 1 $ps
set maxigp_width_prop CONFIG.PSU__MAXIGP2__DATA_WIDTH
if {[lsearch -exact [list_property $ps] $maxigp_width_prop] >= 0} {
    set_property $maxigp_width_prop 32 $ps
}

set control_master ""
set control_clk ""
foreach candidate [list \
    [list M_AXI_HPM0_LPD maxihpm0_lpd_aclk] \
    [list M_AXI_HPM0_FPD maxihpm0_fpd_aclk]] {
    set intf_name [lindex $candidate 0]
    set clk_name  [lindex $candidate 1]
    set intf_obj [get_bd_intf_pins -quiet $ps/$intf_name]
    set clk_obj  [get_bd_pins -quiet $ps/$clk_name]
    if {[llength $intf_obj] == 1 && [llength $clk_obj] == 1} {
        set control_master $intf_obj
        set control_clk $clk_obj
        puts "Using PS control master: $intf_name (clock $clk_name)"
        break
    }
}
if {$control_master eq "" || $control_clk eq ""} {
    error "No enabled PS HPM control master was found after setting PSU__USE__M_AXI_GP2"
}

# Add a standard AXI GPIO mailbox: channel 1 is PS->PL control, channel 2 is
# PL->PS status. SmartConnect absorbs AXI width/protocol differences.
if {[llength [get_bd_cells -quiet axi_smc_ctrl]] == 0} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_smc_ctrl
    set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] \
        [get_bd_cells axi_smc_ctrl]
}
if {[llength [get_bd_cells -quiet axi_gpio_ctrl]] == 0} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_ctrl
    set_property -dict [list \
        CONFIG.C_GPIO_WIDTH {32} \
        CONFIG.C_ALL_OUTPUTS {1} \
        CONFIG.C_IS_DUAL {1} \
        CONFIG.C_GPIO2_WIDTH {32} \
        CONFIG.C_ALL_INPUTS_2 {1}] [get_bd_cells axi_gpio_ctrl]
}

connect_bd_intf_net \
    $control_master \
    [get_bd_intf_pins axi_smc_ctrl/S00_AXI]
connect_bd_intf_net \
    [get_bd_intf_pins axi_smc_ctrl/M00_AXI] \
    [get_bd_intf_pins axi_gpio_ctrl/S_AXI]

# Reuse the vendor BD's validated AXI clock input as the source for every
# AXI interface in this block design.  At the RTL wrapper level axi_hp_clk is
# driven by the PS pl_clk0 output, so the physical clock remains the same.
#
# Do not pass a bd_net object as an ordinary positional object to
# connect_bd_net: Vivado 2024.2 can create a sink-only net and then report the
# attached pins as "not connected to a valid clock source".  Extend the
# existing clock net explicitly from its BD input port instead.
set axi_clk_port [get_bd_ports -quiet axi_hp_clk]
if {[llength $axi_clk_port] != 1} {
    error "Cannot resolve vendor BD clock input axi_hp_clk"
}
connect_bd_net \
    $axi_clk_port \
    $control_clk \
    [get_bd_pins axi_smc_ctrl/aclk] \
    [get_bd_pins axi_gpio_ctrl/s_axi_aclk]

set reset_source [get_bd_pins -quiet proc_sys_reset_0/peripheral_aresetn]
if {[llength $reset_source] != 1} {
    error "Cannot resolve peripheral_aresetn source pin"
}
connect_bd_net \
    $reset_source \
    [get_bd_pins axi_smc_ctrl/aresetn] \
    [get_bd_pins axi_gpio_ctrl/s_axi_aresetn]

# Fail early with a useful diagnostic if any clock sink did not join the
# vendor axi_hp_clk net.
set axi_clk_net [get_bd_nets -quiet -of_objects $axi_clk_port]
if {[llength $axi_clk_net] != 1} {
    error "Cannot resolve the axi_hp_clk net after AXI clock wiring"
}
foreach clk_sink [list \
    $control_clk \
    [get_bd_pins axi_smc_ctrl/aclk] \
    [get_bd_pins axi_gpio_ctrl/s_axi_aclk]] {
    set sink_net [get_bd_nets -quiet -of_objects $clk_sink]
    if {[llength $sink_net] != 1 || [lindex $sink_net 0] ne [lindex $axi_clk_net 0]} {
        error "AXI clock sink was not connected to axi_hp_clk: $clk_sink"
    }
}
puts "Using vendor AXI clock port: axi_hp_clk"

if {[llength [get_bd_ports -quiet gpio_control]] == 0} {
    create_bd_port -dir O -from 31 -to 0 gpio_control
}
if {[llength [get_bd_ports -quiet gpio_status]] == 0} {
    create_bd_port -dir I -from 31 -to 0 gpio_status
}
connect_bd_net -quiet [get_bd_pins axi_gpio_ctrl/gpio_io_o] \
    [get_bd_ports gpio_control]
connect_bd_net -quiet [get_bd_pins axi_gpio_ctrl/gpio2_io_i] \
    [get_bd_ports gpio_status]

# Fixed control aperture used by the bare-metal test application.
# M_AXI_HPM0_LPD reaches PL slaves through the 512 MiB aperture
# 0x8000_0000..0x9FFF_FFFF.  0xA000_0000 belongs to the FPD HPM
# aperture and is rejected when the LPD master is selected.
set control_base 0x80000000
set gpio_seg [get_bd_addr_segs -quiet axi_gpio_ctrl/S_AXI/Reg]
set ps_data [get_bd_addr_spaces -quiet $ps/Data]
if {[llength $ps_data] == 0} {
    set ps_data [get_bd_addr_spaces -of_objects $control_master]
}
if {[llength $gpio_seg] != 1 || [llength $ps_data] < 1} {
    error "Cannot resolve AXI GPIO address objects"
}
assign_bd_address -offset $control_base -range 0x00010000 \
    -target_address_space [lindex $ps_data 0] $gpio_seg -force

validate_bd_design
save_bd_design

generate_target all [get_files $bd_file]
set wrapper [make_wrapper -files [get_files $bd_file] -top]
set wrapper [file normalize [lindex $wrapper 0]]
set normalized_build_root [string tolower [file normalize $fpt_build_root]]
if {[string first $normalized_build_root [string tolower $wrapper]] != 0} {
    error "BD wrapper escaped the current build root: $wrapper"
}
add_files -norecurse $wrapper

add_files -norecurse $design_files
add_files -norecurse $memory_files
foreach mf $memory_files {
    set obj [get_files -quiet [file normalize $mf]]
    if {[llength $obj] == 1} {
        set_property file_type {Memory Initialization Files} $obj
    }
}
add_files -fileset constrs_1 -norecurse $constraint_files

source [file join $script_dir create_fp32_ips.tcl]

set_property top attention_board_top [get_filesets sources_1]
update_compile_order -fileset sources_1

# Keep the source tree independent and reproducible.
set_property source_mgmt_mode All [current_project]

puts "============================================================"
puts {[PASS] Independent Attention board project created}
puts "Project : [file join $project_dir ${project_name}.xpr]"
puts "Build   : $fpt_build_root"
puts "BD gen  : $bd_gen_dir"
puts "Part    : $part_name"
puts [format "Control : AXI GPIO @ 0x%08X" $control_base]
puts "Run     : $fpt_run_groups GQA group(s), SEQ_LEN=128, HEAD_DIM=128, BF16"
puts "============================================================"
