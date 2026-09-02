# Rebuild only the existing v3.1 A53 application after source changes.
set script_dir [file normalize [file dirname [info script]]]
set board_root [file normalize [file join $script_dir ..]]
set ws [file join $board_root vitis workspace]
set app_elf [file join $ws fpt_attention_test Debug fpt_attention_test.elf]

if {![file isdirectory $ws]} {
    error "Missing Vitis workspace: $ws; run create_vitis_app_xsct.tcl first"
}

setws $ws
app build -name fpt_attention_test

if {![file isfile $app_elf]} {
    error "Vitis reported completion but application ELF is missing: $app_elf"
}

puts "============================================================"
puts {[PASS] v3.1 Vitis application rebuilt}
puts "ELF: $app_elf"
puts "============================================================"
