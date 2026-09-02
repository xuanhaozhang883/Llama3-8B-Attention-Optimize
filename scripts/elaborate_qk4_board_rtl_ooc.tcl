if {$argc < 2} {
    error "usage: elaborate_qk4_board_rtl_ooc.tcl <source_root> <build_root>"
}
set source_root [file normalize [lindex $argv 0]]
set build_root [file normalize [lindex $argv 1]]
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
create_project qk4_board_rtl_elaboration $build_root -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl_files [concat \
    [collect_rtl_files [file join $source_root rtl board]] \
    [collect_rtl_files [file join $source_root rtl core]]]
add_files -norecurse $rtl_files
add_files -norecurse [file join $source_root tests stubs design_1_wrapper_stub.sv]
add_files -norecurse [list \
    [file join $source_root mem exp_lut_q15.mem] \
    [file join $source_root mem sin_bf16.hex] \
    [file join $source_root mem cos_bf16.hex]]

set_property top attention_board_top [get_filesets sources_1]
set_property generic {RUN_GROUPS=8 QK_LANES=4 V_LANES=8} \
    [get_filesets sources_1]
set ::FPT_FP_IP_SYNTH_CHECKPOINT true
source [file join $source_root scripts create_fp32_ips.tcl]
update_compile_order -fileset sources_1

set synth_run [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none $synth_run
launch_runs $synth_run -jobs 1
wait_on_run $synth_run
if {[get_property PROGRESS $synth_run] ne "100%"} {
    error "synth_1 did not complete: [get_property STATUS $synth_run]"
}
open_run $synth_run
set cell_count [llength [get_cells -hierarchical -quiet]]
if {$cell_count == 0} {
    error "Board synthesis produced an empty design"
}
puts "QK4_BOARD_RTL_SYNTHESIS_PASS cells=$cell_count"
close_project
