# Read-only audit/export helper for the vendor RK-XCZU15EG-F V1.0 project.
# This script never launches simulation, synthesis, implementation or
# bitstream generation. Run it on a disposable extracted copy of the vendor
# project because Vivado may update project metadata while opening it.

if {$argc != 2} {
    error "Usage: vivado -mode batch -source audit_vendor_factory_project.tcl -tclargs <vendor.xpr> <output_dir>"
}

set vendor_xpr [file normalize [lindex $argv 0]]
set output_dir [file normalize [lindex $argv 1]]
set expected_part "xczu15eg-ffvb1156-2-i"

if {![file isfile $vendor_xpr]} {
    error "Vendor project does not exist: $vendor_xpr"
}
file mkdir $output_dir

open_project $vendor_xpr
set actual_part [get_property PART [current_project]]
if {$actual_part ne $expected_part} {
    error "Vendor project part mismatch: expected $expected_part, got $actual_part"
}

set bd_files [get_files -quiet *.bd]
if {[llength $bd_files] != 1} {
    error "Expected one vendor Block Design, found [llength $bd_files]"
}
open_bd_design [lindex $bd_files 0]

set ps_cells [get_bd_cells -quiet -hier -filter {
    VLNV =~ "xilinx.com:ip:zynq_ultra_ps_e:*"
}]
if {[llength $ps_cells] != 1} {
    error "Expected one Zynq UltraScale+ PS cell, found [llength $ps_cells]"
}
set ddr_cells [get_bd_cells -quiet -hier -filter {
    VLNV =~ "xilinx.com:ip:ddr4:*"
}]
if {[llength $ddr_cells] != 1} {
    error "Expected one PL DDR4 cell, found [llength $ddr_cells]"
}

set ps_cell [lindex $ps_cells 0]
set ddr_cell [lindex $ddr_cells 0]
write_bd_tcl -force [file join $output_dir vendor_factory_bd.tcl]
report_property -all $ps_cell \
    -file [file join $output_dir ps_cell_properties.txt]
report_property -all $ddr_cell \
    -file [file join $output_dir pl_ddr_cell_properties.txt]

set summary_path [file join $output_dir audit_summary.txt]
set summary [open $summary_path w]
puts $summary "VENDOR_XPR=$vendor_xpr"
puts $summary "PROJECT_PART=$actual_part"
puts $summary "BD_FILE=[lindex $bd_files 0]"
puts $summary "PS_CELL=$ps_cell"
puts $summary "PS_VLNV=[get_property VLNV $ps_cell]"
puts $summary "PL_DDR_CELL=$ddr_cell"
puts $summary "PL_DDR_VLNV=[get_property VLNV $ddr_cell]"
puts $summary "BD_INTERFACES=[join [get_bd_intf_ports -quiet] { }]"
puts $summary "ADDRESS_SEGMENTS=[join [get_bd_addr_segs -quiet] { }]"
close $summary

puts "RK_VENDOR_AUDIT_OK=$summary_path"
puts "RK_VENDOR_BD_TCL=[file join $output_dir vendor_factory_bd.tcl]"
close_project
