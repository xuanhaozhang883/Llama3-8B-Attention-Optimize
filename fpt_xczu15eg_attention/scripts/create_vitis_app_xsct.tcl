# Run in XSCT 2024.2 after build_attention_board_all.tcl has generated the XSA.
set script_dir [file normalize [file dirname [info script]]]
set board_root [file normalize [file join $script_dir ..]]
source [file join $script_dir project_config.tcl]
set xsa [file join $board_root export $fpt_xsa_name]
set ws  [file join $board_root vitis workspace]
set src [file join $board_root vitis src]

if {![file isfile $xsa]} { error "Missing XSA: $xsa" }
file mkdir $ws
setws $ws

# Classic XSCT commands remain available in Vitis 2024.2, although AMD marks
# XSCT as deprecated. If a local installation rejects them, follow README_CN.
catch {app remove fpt_attention_test}
catch {platform remove fpt_attention_platform}

platform create -name fpt_attention_platform -hw $xsa \
    -proc psu_cortexa53_0 -os standalone
platform generate
app create -name fpt_attention_test -platform fpt_attention_platform \
    -domain standalone_domain -template {Empty Application}
importsources -name fpt_attention_test -path $src
app build -name fpt_attention_test

puts "============================================================"
puts {[PASS] Vitis application created and built}
puts "Workspace: $ws"
puts "ELF search: [glob -nocomplain -directory $ws -types f */*/*.elf]"
puts "============================================================"
