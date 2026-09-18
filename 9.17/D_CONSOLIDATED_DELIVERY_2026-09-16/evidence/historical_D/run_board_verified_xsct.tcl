# One-off board download script for the verified v3.1 artifacts.
# Usage:
#   xsct.bat run_board_verified_xsct.tcl <bit> <psu_init.tcl> <application.elf>

if {[llength $argv] < 3} {
    error "Usage: xsct run_board_verified_xsct.tcl <bit> <psu_init.tcl> <application.elf>"
}

set bit_file [file normalize [lindex $argv 0]]
set psu_init_file [file normalize [lindex $argv 1]]
set app_elf [file normalize [lindex $argv 2]]

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

    init_ps [subst {$psu_mio_init_data $psu_peripherals_pre_init_data \
        $psu_pll_init_data $psu_clock_init_data $psu_ddr_init_data}]
    psu_ddr_phybringup_data
    init_ps [subst {$psu_peripherals_init_data $psu_resetin_init_data}]

    # The Attention design uses DDR, UART and PS-PL AXI only.  Unused PS-GTR
    # peripherals are intentionally left in reset to avoid polling absent lanes.
    init_peripheral
    init_ps [subst {$psu_peripherals_powerdwn_data}]
    init_ps [subst {$psu_afi_config}]
    init_ps [subst {$psu_ddr_qos_init_data}]

    configparams force-mem-accesses $saved_mode
}

puts "FPT_BOARD_DOWNLOAD_BEGIN"
puts "BIT=$bit_file"
puts "PSU_INIT=$psu_init_file"
puts "ELF=$app_elf"

connect
targets -set -nocase -filter {name =~ "PSU"}
rst -system
after 1000

source $psu_init_file
puts "Using reduced PS init (PS-GTR skipped): $psu_init_file"
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
puts "FPT_BOARD_DOWNLOAD_END"
puts {[PASS] Bitstream and ELF started; check PS UART at 115200 8N1.}
