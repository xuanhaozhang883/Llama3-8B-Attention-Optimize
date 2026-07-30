# Usage:
# xsct run_on_board_xsct.tcl <psu_init.tcl> <application.elf>
set script_dir [file normalize [file dirname [info script]]]
set board_root [file normalize [file join $script_dir ..]]
source [file join $script_dir project_config.tcl]
set bit_file [lindex [glob -nocomplain \
    [file join $board_root vivado $fpt_project_name \
     ${fpt_project_name}.runs impl_1 *.bit]] 0]

if {[llength $argv] < 2} {
    error "Usage: xsct run_on_board_xsct.tcl <psu_init.tcl> <application.elf>"
}
set psu_init [file normalize [lindex $argv 0]]
set app_elf  [file normalize [lindex $argv 1]]
foreach f [list $bit_file $psu_init $app_elf] {
    if {![file isfile $f]} { error "Missing required file: $f" }
}

connect
targets -set -nocase -filter {name =~ "PSU"}
rst -system
after 1000
source $psu_init
psu_init
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
dow $app_elf
con
puts {[PASS] Bitstream and ELF started; check PS UART at 115200 8N1.}
