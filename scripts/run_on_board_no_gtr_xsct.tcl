# FPT XCZU15EG Attention board download helper for boards whose unused PS-GTR
# lanes do not lock during the generated psu_init sequence.
#
# Usage from XSCT:
#   set argv [list <psu_init.tcl> <application.elf>]
#   source scripts/run_on_board_no_gtr_xsct.tcl
#
# This initializes MIO, clocks, DDR, UART and AXI/AFI, but intentionally leaves
# unused USB/PCIe/DP/SATA SerDes peripherals in reset. The Attention design uses
# PS DDR, UART and PS-PL AXI only; it does not require PS-GTR lanes.

set script_dir [file normalize [file dirname [info script]]]
set board_root [file normalize [file join $script_dir ..]]
source [file join $script_dir project_config.tcl]
set bit_candidates [list]
set export_bit [file join $board_root export ${fpt_project_name}.bit]
if {[file isfile $export_bit]} {
    lappend bit_candidates $export_bit
}
set bit_candidates [concat $bit_candidates [glob -nocomplain \
    [file join $fpt_project_dir ${fpt_project_name}.runs impl_1 *.bit]]]

if {[llength $argv] < 2} {
    error "Usage: xsct run_on_board_no_gtr_xsct.tcl <psu_init.tcl> <application.elf>"
}
if {[llength $bit_candidates] < 1} {
    error "v3.1 FlashAttention bitstream was not found in export/ or the generated Vivado project"
}

set bit_file [file normalize [lindex $bit_candidates 0]]
set psu_init_file [file normalize [lindex $argv 0]]
set app_elf [file normalize [lindex $argv 1]]

foreach f [list $bit_file $psu_init_file $app_elf] {
    if {![file isfile $f]} {
        error "Missing required file: $f"
    }
}

proc fpt_psu_init_no_gtr {} {
    set saved_mode [configparams force-mem-accesses]
    configparams force-mem-accesses 1

    variable psu_mio_init_data
    variable psu_peripherals_pre_init_data
    variable psu_pll_init_data
    variable psu_clock_init_data
    variable psu_ddr_init_data
    variable psu_peripherals_init_data
    variable psu_resetin_init_data
    variable psu_peripherals_powerdwn_data
    variable psu_afi_config
    variable psu_ddr_qos_init_data

    # Required by the Attention bare-metal flow.
    init_ps [subst {$psu_mio_init_data $psu_peripherals_pre_init_data \
        $psu_pll_init_data $psu_clock_init_data $psu_ddr_init_data}]
    psu_ddr_phybringup_data
    init_ps [subst {$psu_peripherals_init_data $psu_resetin_init_data}]

    # Deliberately omit:
    #   init_serdes
    #   psu_serdes_init_data
    #   psu_resetout_init_data
    # The imported merchant PS preset enables USB/PCIe/DP/SATA GTR paths and
    # polls lane PLL locks. Those peripherals are not used by this design.

    init_peripheral
    init_ps [subst {$psu_peripherals_powerdwn_data}]
    init_ps [subst {$psu_afi_config}]
    init_ps [subst {$psu_ddr_qos_init_data}]

    configparams force-mem-accesses $saved_mode
}

connect
targets -set -nocase -filter {name =~ "PSU"}
rst -system
after 1000

source $psu_init_file
puts "[format {Using reduced PS init (PS-GTR skipped): %s} $psu_init_file]"
fpt_psu_init_no_gtr

puts "Programming bitstream: $bit_file"
fpga -file $bit_file
after 1000

if {[llength [info commands psu_ps_pl_isolation_removal]]} {
    psu_ps_pl_isolation_removal
}
if {[llength [info commands psu_ps_pl_reset_config]]} {
    psu_ps_pl_reset_config
}
if {[llength [info commands psu_post_config]]} {
    psu_post_config
}

targets -set -nocase -filter {name =~ "Cortex-A53 #0"}
rst -processor -clear-registers
after 500
puts "Downloading ELF: $app_elf"
dow $app_elf
con
puts {[PASS] v3.1 FlashAttention bitstream and ELF started with reduced no-GTR PS initialization; check PS UART at 115200 8N1.}
