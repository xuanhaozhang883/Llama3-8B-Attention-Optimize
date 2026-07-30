# ============================================================================
# Complete serial-versus-overlap GQA regression
# ============================================================================
#
# Runs:
#   1. Two-bank Buffer unit test.
#   2. Wavefront Scheduler unit test.
#   3. Performance-counter unit test.
#   4. Default-parameter static elaboration.
#   5. Serial full-chain small Attention.
#   6. Optimized overlap full-chain small Attention.
#   7. Bit-exact comparison of every Context output.
#   8. Serial/overlap cycle and speedup report.
#
# Vivado Tcl Console:
#   cd D:/.../Llama3-8B/A_attention_integration_final_v5
#   source {D:/.../Llama3-8B/A_attention_integration_final_v5/scripts/run_vivado_gqa_overlap_regression.tcl}
#
# Generated work/results:
#   A_attention_integration_final_v5/vivado_runs/gqa_overlap_regression
# ============================================================================

# [info script] can be relative when sourced as "source scripts/...". Resolve
# it once before any test case changes the current working directory.
set script_path [file normalize [info script]]
set script_dir  [file dirname $script_path]
set a_root      [file normalize [file dirname $script_dir]]
set repo_root   [file normalize [file dirname $a_root]]

set bc_root   [file join $repo_root FPT_BC_QK_Softmax_PV_Delivery_v5]
set rope_root [file join $repo_root QK_after_RoPE]
set pv_root   [file join $repo_root PV_module]

# Keep all generated XSim files under the Attention integration directory
# instead of creating a large folder beside Llama3-8B.
set run_root [file join $a_root vivado_runs gqa_overlap_regression]
file delete -force $run_root
file mkdir $run_root

set unit_buffer_sources [list \
    [file join $a_root rtl adapter \
        pv_tile2_to_tile4_buffer_adapter.sv] \
    [file join $a_root rtl optimization_v24 \
        gqa_pingpong_buffer.sv] \
    [file join $a_root tb optimization_v24 \
        tb_gqa_pingpong_buffer.sv]]

set unit_scheduler_sources [list \
    [file join $a_root rtl optimization_v24 \
        gqa_overlap_scheduler.sv] \
    [file join $a_root tb optimization_v24 \
        tb_gqa_overlap_scheduler.sv]]

set unit_counter_sources [list \
    [file join $a_root rtl optimization_v24 \
        attention_overlap_perf_counters.sv] \
    [file join $a_root tb optimization_v24 \
        tb_attention_overlap_perf_counters.sv]]

set default_elab_sources [list \
    [file join $a_root rtl adapter \
        pv_tile2_to_tile4_buffer_adapter.sv] \
    [file join $a_root rtl optimization_v24 \
        gqa_pingpong_buffer.sv] \
    [file join $a_root rtl optimization_v24 \
        gqa_overlap_scheduler.sv] \
    [file join $a_root rtl optimization_v24 \
        attention_overlap_perf_counters.sv]]

set full_chain_tb [file join $a_root tb \
    tb_attention_system_with_rope_pv_small.sv]

set full_design_sources [list \
    [file join $a_root rtl top \
        attention_with_pv_config_guard.sv] \
    [file join $a_root rtl controller \
        attention_group_pv_controller.sv] \
    [file join $a_root rtl adapter \
        pv_tile2_to_tile4_buffer_adapter.sv] \
    [file join $a_root rtl optimization_v24 \
        gqa_pingpong_buffer.sv] \
    [file join $a_root rtl optimization_v24 \
        gqa_overlap_scheduler.sv] \
    [file join $a_root rtl optimization_v24 \
        attention_overlap_perf_counters.sv] \
    [file join $a_root rtl top \
        attention_system_with_rope_pv_top.sv] \
    [file join $a_root rtl top \
        attention_system_with_rope_pv_overlap_top.sv] \
    \
    [file join $bc_root rtl adapter causal_mask_stream.sv] \
    [file join $bc_root rtl adapter qk_softmax_adapter.sv] \
    [file join $bc_root rtl adapter score_rowtile_buffer.sv] \
    [file join $bc_root rtl adapter score_rowtile_payload_bram.sv] \
    [file join $bc_root rtl backend bf16_v_cache.sv] \
    [file join $bc_root rtl backend pv_input_loader.sv] \
    [file join $bc_root rtl backend softmax_output_buffer.sv] \
    [file join $bc_root rtl backend softmax_pv_backend.sv] \
    [file join $bc_root rtl integration qk_softmax_frontend.sv] \
    [file join $bc_root rtl integration qk_softmax_pipeline_top.sv] \
    [file join $bc_root rtl integration qk_softmax_pv_pipeline_top.sv] \
    [file join $bc_root rtl qk bf16_to_fp32.v] \
    [file join $bc_root rtl qk fp32_add_ip.v] \
    [file join $bc_root rtl qk fp32_mul_ip.v] \
    [file join $bc_root rtl qk fp32_to_bf16.v] \
    [file join $bc_root rtl qk qk_result_scaler.sv] \
    [file join $bc_root rtl qk qk_systolic_gqa_top.sv] \
    [file join $bc_root rtl qk qk_systolic_pe.sv] \
    [file join $bc_root rtl qk qk_systolic_tile.sv] \
    [file join $bc_root rtl softmax exp_lut.sv] \
    [file join $bc_root rtl softmax softmax_bf16.sv] \
    [file join $bc_root rtl softmax unsigned_restoring_divider.sv] \
    \
    [file join $rope_root rtl rope rope_pair_pipeline.sv] \
    [file join $rope_root rtl rope rope_group_prepare.sv] \
    [file join $rope_root rtl rope rope_qk_group_cache.sv] \
    [file join $rope_root rtl integration rope_group_bridge.sv] \
    [file join $rope_root rtl integration \
        rope_qk_softmax_pv_pipeline_top.sv] \
    \
    [file join $pv_root rtl pv_bf16_to_fp32.v] \
    [file join $pv_root rtl pv_fp32_add_ip.sv] \
    [file join $pv_root rtl pv_fp32_mul_ip.sv] \
    [file join $pv_root rtl pv_fp32_to_bf16.v] \
    [file join $pv_root rtl pv_result_converter.sv] \
    [file join $pv_root rtl pv_systolic_gqa_top.sv] \
    [file join $pv_root rtl pv_systolic_pe.sv] \
    [file join $pv_root rtl pv_systolic_tile.sv] \
    \
    [file join $bc_root sim_models floating_point_behavioral.sv] \
    $full_chain_tb]

set memory_sources [list \
    [file join $bc_root rtl softmax exp_lut_q15.mem] \
    [file join $rope_root tb data rope_small_sin.hex] \
    [file join $rope_root tb data rope_small_cos.hex]]

# Report every missing dependency in one pass.
set required_files [concat \
    $unit_buffer_sources \
    $unit_scheduler_sources \
    $unit_counter_sources \
    $default_elab_sources \
    $full_design_sources \
    $memory_sources]

set missing_files [list]
foreach file_name $required_files {
    if {![file isfile $file_name]} {
        lappend missing_files $file_name
    }
}

if {[llength $missing_files] != 0} {
    puts "============================================================"
    puts "GQA OVERLAP REGRESSION CANNOT START"
    puts "The following required files are missing:"
    foreach file_name $missing_files {
        puts "  $file_name"
    }
    puts "============================================================"
    error "Install every required RTL/TB/memory file first."
}

# A same-named old smoke TB is not sufficient. Check the exact features this
# comparison needs before spending time compiling and simulating.
set tb_handle [open $full_chain_tb r]
set tb_contents [read $tb_handle]
close $tb_handle

set missing_tb_features [list]
foreach required_token {
    CONTEXT_DUMP
    STATS_DUMP
    GQA_OVERLAP_DUT
} {
    if {[string first $required_token $tb_contents] < 0} {
        lappend missing_tb_features $required_token
    }
}

if {[llength $missing_tb_features] != 0} {
    error "tb_attention_system_with_rope_pv_small.sv is not the instrumented serial-versus-overlap TB. Missing: [join $missing_tb_features {, }]"
}

proc prepare_case_dir {case_dir memory_sources} {
    file delete -force $case_dir
    file mkdir $case_dir

    foreach memory_file $memory_sources {
        file copy -force $memory_file \
            [file join $case_dir [file tail $memory_file]]
    }
}

proc run_external {args} {
    puts "COMMAND: [join $args { }]"

    if {[catch {
        set output [exec {*}$args 2>@1]
    } message]} {
        puts $message
        error "External command failed: [join $args { }]"
    }

    puts $output
}

proc check_xsim_log {case_dir} {
    set log_path [file join $case_dir xsim.log]
    if {![file isfile $log_path]} {
        return
    }

    set handle [open $log_path r]
    set contents [read $handle]
    close $handle

    # XSim can return process status 0 even when a SystemVerilog $fatal
    # terminated the test. Detect that condition before comparing empty files.
    if {[regexp -nocase {\$fatal|FATAL_ERROR|Fatal:|simulation failed} \
            $contents]} {
        error "XSim reported a fatal simulation failure. Inspect: $log_path"
    }
}

proc run_unit_case {
    run_root case_name top_name sources memory_sources
} {
    set case_dir [file join $run_root $case_name]
    prepare_case_dir $case_dir $memory_sources
    cd $case_dir

    puts "============================================================"
    puts "RUNNING UNIT CASE: $case_name"
    puts "============================================================"

    run_external xvlog -sv {*}$sources
    run_external xelab $top_name \
        -s ${case_name}_snapshot -debug typical
    run_external xsim ${case_name}_snapshot -runall
    check_xsim_log $case_dir
}

proc run_full_case {
    run_root case_name define_name sources memory_sources dump_path stats_path
} {
    set case_dir [file join $run_root $case_name]
    prepare_case_dir $case_dir $memory_sources
    cd $case_dir

    puts "============================================================"
    puts "RUNNING FULL CASE: $case_name"
    puts "============================================================"

    if {$define_name eq ""} {
        run_external xvlog -sv {*}$sources
    } else {
        run_external xvlog -sv -d $define_name {*}$sources
    }

    run_external xelab tb_attention_system_with_rope_pv_small \
        -s ${case_name}_snapshot -debug typical

    # Pass ASCII-only relative names to SystemVerilog $fopen. Tcl copies the
    # finished files to the organized results root after XSim exits.
    set local_dump_name  [file tail $dump_path]
    set local_stats_name [file tail $stats_path]

    run_external xsim ${case_name}_snapshot -runall \
        -testplusarg CONTEXT_DUMP=$local_dump_name \
        -testplusarg STATS_DUMP=$local_stats_name
    check_xsim_log $case_dir

    set local_dump_path  [file join $case_dir $local_dump_name]
    set local_stats_path [file join $case_dir $local_stats_name]

    foreach required_output [list \
            $local_dump_path \
            $local_stats_path] {
        if {![file isfile $required_output]} {
            error "XSim completed without creating $required_output. Check the TB plusarg/$fopen logic and this case's XSim log."
        }
    }

    file copy -force $local_dump_path $dump_path
    file copy -force $local_stats_path $stats_path
}

proc run_default_elaboration {run_root sources} {
    set case_dir [file join $run_root default_elaboration]
    file delete -force $case_dir
    file mkdir $case_dir
    cd $case_dir

    puts "============================================================"
    puts "RUNNING DEFAULT-PARAMETER STATIC ELABORATION"
    puts "============================================================"

    run_external xvlog -sv {*}$sources
    foreach top_name {
        gqa_pingpong_buffer
        gqa_overlap_scheduler
        attention_overlap_perf_counters
    } {
        run_external xelab $top_name \
            -s ${top_name}_default_snapshot
    }
}

proc read_nonempty_lines {path} {
    set handle [open $path r]
    set contents [read $handle]
    close $handle

    set result [list]
    foreach line [split $contents "\n"] {
        set trimmed [string trim $line]
        if {$trimmed ne ""} {
            lappend result $trimmed
        }
    }
    return $result
}

proc read_stats {path} {
    set lines [read_nonempty_lines $path]
    if {[llength $lines] < 2 ||
        [lindex $lines 0] ne "metric,value"} {
        error "Invalid statistics file: $path"
    }

    set result [dict create]
    foreach line [lrange $lines 1 end] {
        set fields [split $line ","]
        if {[llength $fields] != 2} {
            error "Invalid statistics line in $path: $line"
        }
        dict set result [lindex $fields 0] [lindex $fields 1]
    }
    return $result
}

# --------------------------------------------------------------------------
# Execute regression
# --------------------------------------------------------------------------

run_unit_case $run_root unit_buffer \
    tb_gqa_pingpong_buffer $unit_buffer_sources $memory_sources

run_unit_case $run_root unit_scheduler \
    tb_gqa_overlap_scheduler $unit_scheduler_sources $memory_sources

run_unit_case $run_root unit_counters \
    tb_attention_overlap_perf_counters $unit_counter_sources $memory_sources

run_default_elaboration $run_root $default_elab_sources

set baseline_dump  [file join $run_root baseline_context.txt]
set baseline_stats [file join $run_root baseline_stats.csv]
set overlap_dump   [file join $run_root overlap_context.txt]
set overlap_stats  [file join $run_root overlap_stats.csv]

run_full_case $run_root full_serial "" \
    $full_design_sources $memory_sources \
    $baseline_dump $baseline_stats

run_full_case $run_root full_overlap GQA_OVERLAP_DUT \
    $full_design_sources $memory_sources \
    $overlap_dump $overlap_stats

foreach required_output [list \
        $baseline_dump \
        $baseline_stats \
        $overlap_dump \
        $overlap_stats] {
    if {![file isfile $required_output]} {
        error "Required regression output is missing: $required_output"
    }
}

# --------------------------------------------------------------------------
# Bit-exact output comparison
# --------------------------------------------------------------------------

set baseline_lines [read_nonempty_lines $baseline_dump]
set overlap_lines  [read_nonempty_lines $overlap_dump]
set expected_contexts [expr {8 * 4 * 4 * 4}]

if {[llength $baseline_lines] != $expected_contexts} {
    error "Serial Context dump count mismatch: [llength $baseline_lines] / $expected_contexts"
}

if {[llength $overlap_lines] != $expected_contexts} {
    error "Overlap Context dump count mismatch: [llength $overlap_lines] / $expected_contexts"
}

for {set index 0} {$index < $expected_contexts} {incr index} {
    set serial_line  [lindex $baseline_lines $index]
    set overlap_line [lindex $overlap_lines $index]

    if {$serial_line ne $overlap_line} {
        error "Bit-exact mismatch at Context index $index: serial={$serial_line} overlap={$overlap_line}"
    }
}

# --------------------------------------------------------------------------
# Correctness and performance statistics
# --------------------------------------------------------------------------

set serial [read_stats $baseline_stats]
set overlap [read_stats $overlap_stats]

set required_keys {
    total_cycles
    bc_cycles
    pv_cycles
    overlap_cycles
    bank_full_wait_cycles
    bank_empty_wait_cycles
    context_count
    duplicate_count
    missing_count
    error_bitmap
}

foreach implementation_name {serial overlap} {
    set implementation [set $implementation_name]

    foreach required_key $required_keys {
        if {![dict exists $implementation $required_key]} {
            error "Missing $implementation_name statistics key: $required_key"
        }
    }

    if {[dict get $implementation context_count] !=
        $expected_contexts} {
        error "$implementation_name Context count mismatch: [dict get $implementation context_count]"
    }

    if {[dict get $implementation duplicate_count] != 0 ||
        [dict get $implementation missing_count] != 0 ||
        [dict get $implementation error_bitmap] != 0} {
        error "$implementation_name correctness counters are nonzero: $implementation"
    }
}

set serial_total  [dict get $serial total_cycles]
set overlap_total [dict get $overlap total_cycles]
set bc_cycles     [dict get $overlap bc_cycles]
set pv_cycles     [dict get $overlap pv_cycles]
set overlap_cycles [dict get $overlap overlap_cycles]

if {$serial_total == 0 || $overlap_total == 0} {
    error "Total cycle count must be nonzero."
}

if {$overlap_cycles == 0} {
    error "Optimized run produced zero B+C/PV overlap cycles."
}

set overlap_denominator [expr {min($bc_cycles, $pv_cycles)}]
if {$overlap_denominator == 0} {
    error "Overlap-efficiency denominator is zero."
}

set overlap_efficiency \
    [expr {100.0 * $overlap_cycles / $overlap_denominator}]
set speedup [expr {1.0 * $serial_total / $overlap_total}]
set cycles_saved [expr {$serial_total - $overlap_total}]
set cycle_reduction \
    [expr {100.0 * $cycles_saved / $serial_total}]

if {$speedup <= 1.0} {
    puts "WARNING: Functional overlap passed, but measured speedup is not greater than 1.0x."
}

# --------------------------------------------------------------------------
# Persist compact human/machine-readable reports
# --------------------------------------------------------------------------

set comparison_path [file join $run_root performance_comparison.csv]
set comparison [open $comparison_path w]
puts $comparison "metric,serial,overlap"
puts $comparison "total_cycles,$serial_total,$overlap_total"
puts $comparison "bc_cycles,[dict get $serial bc_cycles],$bc_cycles"
puts $comparison "pv_cycles,[dict get $serial pv_cycles],$pv_cycles"
puts $comparison "overlap_cycles,[dict get $serial overlap_cycles],$overlap_cycles"
puts $comparison "context_count,[dict get $serial context_count],[dict get $overlap context_count]"
puts $comparison "duplicate_count,[dict get $serial duplicate_count],[dict get $overlap duplicate_count]"
puts $comparison "missing_count,[dict get $serial missing_count],[dict get $overlap missing_count]"
puts $comparison "error_bitmap,[dict get $serial error_bitmap],[dict get $overlap error_bitmap]"
close $comparison

set summary_path [file join $run_root validation_summary.md]
set summary [open $summary_path w]
puts $summary "# GQA serial-versus-overlap regression"
puts $summary ""
puts $summary "- Serial/overlap Context outputs: $expected_contexts / $expected_contexts"
puts $summary "- Bit-exact mismatches: 0"
puts $summary "- Serial total cycles: $serial_total"
puts $summary "- Overlap total cycles: $overlap_total"
puts $summary "- Cycles saved: $cycles_saved"
puts $summary [format "- Cycle reduction: %.3f%%" $cycle_reduction]
puts $summary [format "- End-to-end speedup: %.4fx" $speedup]
puts $summary "- Optimized B+C cycles: $bc_cycles"
puts $summary "- Optimized PV cycles: $pv_cycles"
puts $summary "- Optimized overlap cycles: $overlap_cycles"
puts $summary [format "- Overlap efficiency: %.3f%%" \
    $overlap_efficiency]
puts $summary "- Bank-full wait cycles: [dict get $overlap bank_full_wait_cycles]"
puts $summary "- Bank-empty wait cycles: [dict get $overlap bank_empty_wait_cycles]"
puts $summary "- Duplicate outputs: 0"
puts $summary "- Missing outputs: 0"
puts $summary "- Error bitmap: 0"
close $summary

puts "============================================================"
puts {[PASS] COMPLETE GQA OVERLAP REGRESSION}
puts "Bit-exact Context outputs = $expected_contexts"
puts "Bit-exact mismatches      = 0"
puts "Serial total cycles       = $serial_total"
puts "Overlap total cycles      = $overlap_total"
puts "Cycles saved              = $cycles_saved"
puts [format "Cycle reduction           = %.3f%%" $cycle_reduction]
puts [format "End-to-end speedup        = %.4fx" $speedup]
puts "Optimized B+C cycles      = $bc_cycles"
puts "Optimized PV cycles       = $pv_cycles"
puts "Overlap cycles            = $overlap_cycles"
puts [format "Overlap efficiency        = %.3f%%" \
    $overlap_efficiency]
puts "Bank-full wait cycles     = [dict get $overlap bank_full_wait_cycles]"
puts "Bank-empty wait cycles    = [dict get $overlap bank_empty_wait_cycles]"
puts "Duplicate outputs         = 0"
puts "Missing outputs           = 0"
puts "Error bitmap              = 0"
puts "Results directory         = $run_root"
puts "Summary                   = $summary_path"
puts "============================================================"
