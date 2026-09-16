# Generate a standalone Cortex-A53 BSP directly from an XSA, without loading
# the deprecated Vitis workspace/project commands.

if {[llength $argv] != 2} {
    error "Usage: xsct generate_standalone_bsp_hsi.tcl <hardware.xsa> <output-dir>"
}

set xsa [file normalize [lindex $argv 0]]
set out_dir [file normalize [lindex $argv 1]]
if {![file isfile $xsa]} {
    error "Missing XSA: $xsa"
}
if {[file exists $out_dir] && [llength [glob -nocomplain -directory $out_dir *]]} {
    error "Output directory must be new or empty: $out_dir"
}
file mkdir $out_dir

hsi open_hw_design $xsa
hsi create_sw_design fpt_standalone_bsp \
    -proc psu_cortexa53_0 -os standalone
hsi generate_bsp -dir $out_dir
hsi write_mss -name system -dir $out_dir -force
hsi close_sw_design [hsi current_sw_design]
hsi close_hw_design [hsi current_hw_design]

puts "============================================================"
puts {[PASS] Standalone Cortex-A53 BSP sources generated from XSA}
puts "BSP: $out_dir"
puts "============================================================"
