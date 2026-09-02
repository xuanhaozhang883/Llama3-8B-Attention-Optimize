# Rebuild only the existing v3.1 A53 application after source changes.
set script_dir [file normalize [file dirname [info script]]]
set board_root [file normalize [file join $script_dir ..]]
set ws [file join $board_root vitis workspace]
if {[info exists ::env(FPT_VITIS_WORKSPACE)] &&
    [string trim $::env(FPT_VITIS_WORKSPACE)] ne ""} {
    set ws [file normalize $::env(FPT_VITIS_WORKSPACE)]
}
set app_elf [file join $ws fpt_attention_test Debug fpt_attention_test.elf]

if {![file isdirectory $ws]} {
    error "Missing Vitis workspace: $ws; run create_vitis_app_xsct.tcl first"
}

setws $ws
app build -name fpt_attention_test

if {![file isfile $app_elf]} {
    set app_debug_dir [file join $ws fpt_attention_test Debug]
    puts "Vitis returned before the ELF existed; running managed make in $app_debug_dir"
    if {[catch {
        exec make --no-print-directory -C $app_debug_dir all 2>@1
    } make_output]} {
        puts $make_output
        error "Managed application build failed"
    }
    puts $make_output
}
if {![file isfile $app_elf]} {
    error "Application build completed without an ELF: $app_elf"
}

puts "============================================================"
puts {[PASS] v3.1.4 Vitis application rebuilt}
puts "ELF: $app_elf"
puts "============================================================"
