# Synthesize only the Q/K/V bridge to prove XPM block-memory binding.
# This is a non-simulation structural check.

set script_dir [file normalize [file dirname [info script]]]
set system_dir [file normalize [file join $script_dir ..]]
set rtl_dir [file join $system_dir rtl]
set out_dir [file join $system_dir generated rtl_check qkv_bram]
file mkdir $out_dir

create_project -in_memory rk_qkv_bram_check \
    -part xczu15eg-ffvb1156-2-i
set_property target_language Verilog [current_project]
set_property XPM_LIBRARIES {XPM_MEMORY} [current_project]
read_verilog -sv [list \
    [file join $rtl_dir rk_xpm_sdpram.sv] \
    [file join $rtl_dir axis_qkv_memory_bridge.sv]]
synth_design -top axis_qkv_memory_bridge \
    -part xczu15eg-ffvb1156-2-i -mode out_of_context

report_utilization -hierarchical -file \
    [file join $out_dir utilization_hierarchical.rpt]
report_ram_utilization -file [file join $out_dir ram_utilization.rpt]

set lutram_cells [get_cells -hier -quiet -filter {
    REF_NAME =~ RAM32* || REF_NAME =~ RAM64* || REF_NAME =~ RAM128* ||
    REF_NAME =~ RAM256*
}]
set bram_cells [get_cells -hier -quiet -filter {
    REF_NAME =~ RAMB18* || REF_NAME =~ RAMB36*
}]
set fh [open [file join $out_dir status.txt] w]
puts $fh "status=SOFTWARE_PASS"
puts $fh "part=[get_property PART [current_project]]"
puts $fh "simulation_launched=false"
puts $fh "lutram_primitive_count=[llength $lutram_cells]"
puts $fh "bram_primitive_count=[llength $bram_cells]"
puts $fh "hardware_state=HARDWARE_PENDING"
close $fh

if {[llength $lutram_cells] != 0} {
    error "Q/K/V bridge still contains LUTRAM primitives"
}
if {[llength $bram_cells] == 0} {
    error "Q/K/V bridge did not produce BRAM primitives"
}
puts "RK_QKV_BRAM_CHECK_PASS=$out_dir"
