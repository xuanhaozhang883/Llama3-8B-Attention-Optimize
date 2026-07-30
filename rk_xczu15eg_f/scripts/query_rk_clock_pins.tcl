# Read-only device-database check for the RK PL differential clock pins.

set script_dir [file normalize [file dirname [info script]]]
set rk_root [file normalize [file join $script_dir ..]]
set project_file [file join $rk_root vx rk_pl_selftest.xpr]
if {![file isfile $project_file]} {
    error "Create the RK project before querying package pins: $project_file"
}
open_project $project_file
open_run synth_1
foreach pin_name {AL8 AL7} {
    set pin_obj [get_package_pins $pin_name]
    if {[llength $pin_obj] != 1} {
        error "Package pin $pin_name was not found"
    }
    puts "RK_PACKAGE_PIN=$pin_name"
    report_property -all $pin_obj
}
close_project
