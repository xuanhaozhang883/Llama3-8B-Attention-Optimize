if {$argc < 3} {
    error "usage: synth_qk4_flash_system_ooc.tcl <source_root> <build_root> <report_root>"
}

set source_root [file normalize [lindex $argv 0]]
set build_root [file normalize [lindex $argv 1]]
set report_root [file normalize [lindex $argv 2]]
set part_name xczu15eg-ffvb1156-2-i

proc collect_rtl_files {dir_name} {
    set result {}
    foreach item [glob -nocomplain -directory $dir_name *] {
        if {[file isdirectory $item]} {
            set result [concat $result [collect_rtl_files $item]]
        } elseif {[regexp -nocase {\.(v|sv)$} $item]} {
            lappend result [file normalize $item]
        }
    }
    return $result
}

file mkdir $build_root
file mkdir $report_root
create_project qk4_flash_system_ooc $build_root -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl_files [collect_rtl_files [file join $source_root rtl core]]
if {[llength $rtl_files] == 0} {
    error "No core RTL files found below $source_root"
}
add_files -norecurse $rtl_files
add_files -norecurse [list \
    [file join $source_root mem exp_lut_q15.mem] \
    [file join $source_root mem sin_bf16.hex] \
    [file join $source_root mem cos_bf16.hex]]

set_property top flash_attention_system_with_rope_top [get_filesets sources_1]
set_property generic {QK_LANES=4 V_LANES=8 RUN_GQA_GROUPS=8} \
    [get_filesets sources_1]

# Keep floating-point IPs as synthesis checkpoints.  This is the stable path
# for Vivado 2018.3 and still accounts for every IP resource in the top design.
set ::FPT_FP_IP_SYNTH_CHECKPOINT true
source [file join $source_root scripts create_fp32_ips.tcl]
update_compile_order -fileset sources_1

set xdc_path [file join $build_root qk4_flash_system_ooc.xdc]
set xdc_file [open $xdc_path w]
puts $xdc_file {create_clock -name flash_clk -period 6.667 [get_ports clk]}
close $xdc_file
add_files -fileset constrs_1 -norecurse $xdc_path

set synth_run [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt $synth_run
launch_runs $synth_run -jobs 1
wait_on_run $synth_run
if {[get_property PROGRESS $synth_run] ne "100%"} {
    error "synth_1 did not complete: [get_property STATUS $synth_run]"
}
open_run $synth_run

report_utilization -hierarchical -file \
    [file join $report_root utilization_hierarchical.rpt]
report_utilization -file [file join $report_root utilization.rpt]
report_timing_summary -delay_type max -max_paths 20 -report_unconstrained \
    -file [file join $report_root timing_summary.rpt]
report_methodology -file [file join $report_root methodology.rpt]
write_checkpoint -force [file join $build_root qk4_flash_system_synth.dcp]

set timing_path [get_timing_paths -delay_type max -max_paths 1 -quiet]
set wns "NA"
if {[llength $timing_path] > 0} {
    set wns [get_property SLACK [lindex $timing_path 0]]
}
set summary [open [file join $report_root summary.txt] w]
puts $summary "vivado=[version -short]"
puts $summary "part=$part_name"
puts $summary "top=flash_attention_system_with_rope_top"
puts $summary "qk_lanes=4"
puts $summary "v_lanes=8"
puts $summary "run_gqa_groups=8"
puts $summary "target_mhz=150"
puts $summary "wns_ns=$wns"
close $summary

puts "QK4_FLASH_SYSTEM_OOC_PASS wns_ns=$wns"
close_project
