# Shared Vivado 2019.2-compatible OOC synthesis and structural audit.

proc set_run_property_if_present {run_object property_name property_value} {
    if {[lsearch -exact [list_property $run_object] $property_name] >= 0} {
        set_property $property_name $property_value $run_object
    } else {
        puts "WARNING: run property $property_name is unavailable"
    }
}

proc configure_ooc_synthesis {run_object} {
    set properties [list_property $run_object]
    set mode_property STEPS.SYNTH_DESIGN.ARGS.MODE
    set more_property {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS}
    if {[lsearch -exact $properties $mode_property] >= 0} {
        # Dictionary form prevents a value beginning with '-' from being
        # parsed as an option by Vivado 2019.2's set_property command.
        set_property -dict [list $mode_property out_of_context] $run_object
    } elseif {[lsearch -exact $properties $more_property] >= 0} {
        set_property -dict [list $more_property {-mode out_of_context}] $run_object
    } else {
        error "Vivado run exposes no supported out-of-context synthesis option"
    }
}

proc collection_by_name {collection pattern} {
    set result [list]
    foreach object $collection {
        if {[string match $pattern [get_property NAME $object]]} {
            lappend result $object
        }
    }
    return $result
}

proc run_bc_synthesis {origin_dir top_name project_leaf part_name report_leaf require_vcache} {
    set project_dir [file join $origin_dir $project_leaf]
    set report_dir  [file join $origin_dir reports $report_leaf]
    set jobs 4
    file mkdir $report_dir

    if {[llength [get_projects -quiet]] > 0} { close_project }
    create_project fpt_bc_ooc_synth $project_dir -part $part_name -force
    set_property target_language Verilog [current_project]
    set_property simulator_language Mixed [current_project]

    set rtl_files [concat \
        [glob -nocomplain [file join $origin_dir rtl adapter *.sv]] \
        [glob -nocomplain [file join $origin_dir rtl softmax *.sv]] \
        [glob -nocomplain [file join $origin_dir rtl qk *.sv]] \
        [glob -nocomplain [file join $origin_dir rtl qk *.v]] \
        [glob -nocomplain [file join $origin_dir rtl backend *.sv]] \
        [glob -nocomplain [file join $origin_dir rtl integration *.sv]]]
    add_files -norecurse $rtl_files
    add_files -norecurse [file join $origin_dir rtl softmax exp_lut_q15.mem]
    add_files -fileset constrs_1 -norecurse \
        [file join $origin_dir constraints qk_softmax_100mhz.xdc]
    set_property file_type SystemVerilog [get_files -quiet *.sv]
    set_property file_type {Memory Initialization Files} \
        [get_files -quiet *exp_lut_q15.mem]

    source [file join $origin_dir scripts create_fp32_ips.tcl]
    set_property top $top_name [get_filesets sources_1]
    update_compile_order -fileset sources_1

    set synth_run [get_runs synth_1]
    configure_ooc_synthesis $synth_run
    set_run_property_if_present $synth_run \
        STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none

    reset_run synth_1
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
        error "$top_name synthesis did not complete: [get_property STATUS [get_runs synth_1]]"
    }
    open_run synth_1

    report_utilization -hierarchical \
        -file [file join $report_dir post_synth_utilization_hier.rpt]
    report_timing_summary -delay_type max -report_unconstrained \
        -file [file join $report_dir post_synth_timing.rpt]
    report_timing -delay_type max -max_paths 50 -nworst 10 \
        -file [file join $report_dir post_synth_critical_paths.rpt]
    report_methodology \
        -file [file join $report_dir post_synth_methodology.rpt]
    catch {report_ram_utilization \
        -file [file join $report_dir post_synth_ram_utilization.rpt]}
    write_checkpoint -force [file join $report_dir ${top_name}_post_synth.dcp]

    set latch_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ "LD*"}]
    set black_box_cells [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
    set all_rams [get_cells -quiet -hierarchical -filter {REF_NAME =~ "RAMB*"}]
    set row_rams [collection_by_name $all_rams *u_rowtile_buffer*]
    set p_rams [collection_by_name $all_rams *u_p_buffer*]
    set v_rams [collection_by_name $all_rams *u_v_cache*]
    set exp_logic [get_cells -quiet -hierarchical -filter \
        {(NAME =~ "*u_exp_lut*") && ((REF_NAME =~ "LUT*") || (REF_NAME =~ "RAMD*") || (REF_NAME =~ "ROM*"))}]
    set ff_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ "FD*"}]
    set row_ffs [collection_by_name $ff_cells *u_rowtile_buffer*]
    set p_ffs [collection_by_name $ff_cells *u_p_buffer*]
    set v_ffs [collection_by_name $ff_cells *u_v_cache*]

    set mdrv_checks [get_drc_checks -quiet MDRV-1]
    if {[llength $mdrv_checks] > 0} {
        set mdrv_text [report_drc -checks $mdrv_checks -return_string]
    } else {
        set mdrv_text "MDRV-1 check unavailable in this Vivado release"
    }
    set mdrv_file [open [file join $report_dir post_synth_multiple_driver.rpt] w]
    puts $mdrv_file $mdrv_text
    close $mdrv_file

    set timing_check [check_timing -verbose -return_string]
    set timing_file [open [file join $report_dir post_synth_check_timing.rpt] w]
    puts $timing_file $timing_check
    close $timing_file

    set worst_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
    if {[llength $worst_paths] > 0} {
        set worst_slack [get_property SLACK [lindex $worst_paths 0]]
    } else {
        set worst_slack "NO_CONSTRAINED_PATH"
    }

    set summary_path [file join $report_dir SYNTHESIS_AUDIT_SUMMARY.txt]
    set summary [open $summary_path w]
    puts $summary "top=$top_name"
    puts $summary "part=$part_name"
    puts $summary "target_clock_mhz=100"
    puts $summary "latch_cells=[llength $latch_cells]"
    puts $summary "black_box_cells=[llength $black_box_cells]"
    puts $summary "row_tile_buffer_ramb=[llength $row_rams]"
    puts $summary "p_buffer_ramb=[llength $p_rams]"
    puts $summary "v_cache_ramb=[llength $v_rams]"
    puts $summary "exp_lut_logic_cells=[llength $exp_logic]"
    puts $summary "flip_flop_cells=[llength $ff_cells]"
    puts $summary "row_tile_buffer_flip_flops=[llength $row_ffs]"
    puts $summary "p_buffer_flip_flops=[llength $p_ffs]"
    puts $summary "v_cache_flip_flops=[llength $v_ffs]"
    puts $summary "worst_setup_slack_ns=$worst_slack"
    close $summary

    # Print the complete audit before enforcing it, so a failed run still
    # exposes every independent result in the Tcl console.
    puts "AUDIT: latch cells = [llength $latch_cells]"
    puts "AUDIT: black-box cells = [llength $black_box_cells]"
    puts "AUDIT: Row/P/V-cache RAMB counts = [llength $row_rams]/[llength $p_rams]/[llength $v_rams]"
    puts "AUDIT: Row/P/V-cache FF counts = [llength $row_ffs]/[llength $p_ffs]/[llength $v_ffs]"
    puts "AUDIT: EXP LUT logic cells = [llength $exp_logic]"
    puts "AUDIT: worst synthesis setup slack = $worst_slack ns"

    if {[llength $latch_cells] != 0} {
        error "Unexpected latch primitives: [llength $latch_cells]"
    }
    if {[llength $black_box_cells] != 0} {
        error "Unresolved black-box cells: [llength $black_box_cells]"
    }
    if {[regexp -nocase {found[[:space:]]+[1-9][0-9]*[[:space:]]+violation} $mdrv_text]} {
        error "MDRV-1 multiple-driver violation detected"
    }
    if {[llength $row_rams] == 0} {
        error "Row Tile Buffer did not infer block RAM"
    }
    if {[llength $p_rams] == 0} {
        error "P Buffer did not infer block RAM"
    }
    if {[llength $p_rams] > 4} {
        error "P Buffer BRAM usage is unexpectedly high: [llength $p_rams]"
    }
    if {$require_vcache && ([llength $v_rams] == 0)} {
        error "V-cache did not infer block RAM"
    }
    if {[llength $row_ffs] > 2048} {
        error "Row Tile Buffer contains an unexpected large FF array"
    }
    if {[llength $p_ffs] > 2048} {
        error "P Buffer contains an unexpected large FF array"
    }
    if {$require_vcache && ([llength $v_ffs] > 4096)} {
        error "V-cache contains an unexpected large FF array"
    }
    if {$worst_slack eq "NO_CONSTRAINED_PATH"} {
        error "No constrained timing path was found"
    }
    if {[string is double -strict $worst_slack] && ($worst_slack < 0.0)} {
        error "Provisional 100 MHz synthesis timing failed: slack=$worst_slack ns"
    }

    puts "PASS: $top_name OOC synthesis completed"
    puts "PASS: no latch primitive and no reported MDRV-1 violation"
    puts "PASS: Row Tile Buffer BRAM count = [llength $row_rams]"
    puts "PASS: P Buffer BRAM count = [llength $p_rams]"
    if {$require_vcache} {
        puts "PASS: V-cache BRAM count = [llength $v_rams]"
    }
    puts "INFO: EXP LUT logic cells = [llength $exp_logic]"
    puts "INFO: Row/P/V-cache FF counts = [llength $row_ffs]/[llength $p_ffs]/[llength $v_ffs]"
    puts "INFO: worst synthesis setup slack = $worst_slack ns"
    puts "PASS: provisional 100 MHz synthesis timing has non-negative slack"
    puts "Reports: $report_dir"
}
