# Gate 0: canonical Legacy full-chain simulation.
#
# The test intentionally compiles the frozen authoritative Legacy RTL listed in
# tests/legacy_core_manifest.txt.  The existing small integration testbench
# remains a shared repository fixture until the dual-mode integration Gate.
# All generated files are written below an ignored build directory.
#
# Vivado GUI Tcl Console:
#   cd D:/path/to/rope-qk-integration/fpt_xczu15eg_attention
#   source tests/run_gate0_legacy_regression.tcl

set gate0_script_path [file normalize [info script]]
set gate0_tests_dir   [file dirname $gate0_script_path]
set gate0_board_root  [file normalize [file join $gate0_tests_dir ..]]
set gate0_repo_root   [file normalize [file join $gate0_board_root ..]]
set gate0_original_cwd [pwd]

proc gate0_read_legacy_manifest {board_root manifest_path} {
    if {![file isfile $manifest_path]} {
        error "Gate 0 Legacy manifest is missing: $manifest_path"
    }

    set stream [open $manifest_path r]
    set contents [read $stream]
    close $stream

    set normalized_core_root [string map [list "\\" "/"] \
        [file normalize [file join $board_root rtl core]]]
    set normalized_core_prefix "${normalized_core_root}/"
    set result [list]
    set seen [dict create]
    foreach line [split $contents "\n"] {
        set relative_path [string trim $line]
        if {$relative_path eq "" ||
            [string index $relative_path 0] eq "#"} {
            continue
        }
        if {[file pathtype $relative_path] ne "relative"} {
            error "Legacy manifest paths must be relative: $relative_path"
        }

        set source_path [file normalize \
            [file join $board_root $relative_path]]
        set normalized_source_path [string map [list "\\" "/"] \
            $source_path]
        set source_prefix [string range $normalized_source_path 0 \
            [expr {[string length $normalized_core_prefix] - 1}]]
        if {![string equal -nocase \
                $normalized_core_prefix $source_prefix]} {
            error "Legacy manifest source escapes rtl/core: $relative_path"
        }
        if {[file extension $source_path] ni {.v .sv}} {
            error "Legacy manifest contains a non-HDL file: $relative_path"
        }
        if {[dict exists $seen $source_path]} {
            error "Legacy manifest contains a duplicate: $relative_path"
        }
        if {![file isfile $source_path]} {
            error "Legacy manifest source is missing: $relative_path"
        }

        dict set seen $source_path 1
        lappend result $source_path
    }

    if {[llength $result] != 44} {
        error "Gate 0 Legacy manifest must contain exactly 44 HDL files."
    }
    return $result
}

proc gate0_invalidate_evidence {run_root} {
    if {[file tail $run_root] ne "gate0_legacy"} {
        error "Refusing to invalidate evidence outside gate0_legacy: $run_root"
    }
    foreach leaf {
        gate0_summary.json
        compiled_sources.txt
        gate0_closure_summary.json
        GATE0_CLOSURE_PASS.txt
        gate0_closure_summary.json.tmp
        GATE0_CLOSURE_PASS.txt.tmp
    } {
        set evidence_path [file join $run_root $leaf]
        if {[file exists $evidence_path]} {
            if {[file isdirectory $evidence_path]} {
                error "Refusing to replace an evidence directory: $evidence_path"
            }
            file delete -force $evidence_path
        }
    }
}

proc gate0_run_external {args} {
    puts "COMMAND: [join $args { }]"
    if {[catch {
        set output [exec {*}$args 2>@1]
    } message]} {
        puts $message
        error "External command failed: [join $args { }]"
    }
    puts $output
}

proc gate0_read_nonempty_lines {path} {
    set stream [open $path r]
    set contents [read $stream]
    close $stream

    set result [list]
    foreach line [split $contents "\n"] {
        set trimmed [string trim $line]
        if {$trimmed ne ""} {
            lappend result $trimmed
        }
    }
    return $result
}

proc gate0_read_stats {path} {
    set lines [gate0_read_nonempty_lines $path]
    if {[llength $lines] < 2 || [lindex $lines 0] ne "metric,value"} {
        error "Invalid Gate 0 statistics file: $path"
    }

    set result [dict create]
    foreach line [lrange $lines 1 end] {
        set fields [split $line ","]
        if {[llength $fields] != 2} {
            error "Invalid Gate 0 statistics line: $line"
        }
        dict set result [lindex $fields 0] [lindex $fields 1]
    }
    return $result
}

proc gate0_json_string {value} {
    return "\"[string map [list "\\" "\\\\" "\"" "\\\""] $value]\""
}

if {[info exists ::env(FPT_RTL_GATE_BUILD_ROOT)] &&
    [string trim $::env(FPT_RTL_GATE_BUILD_ROOT)] ne ""} {
    set gate0_build_parent \
        [file normalize $::env(FPT_RTL_GATE_BUILD_ROOT)]
} else {
    set gate0_build_parent [file join $gate0_board_root build rtl_gates]
}
set gate0_run_root [file normalize \
    [file join $gate0_build_parent gate0_legacy]]
set gate0_case_dir [file join $gate0_run_root legacy_full_chain]

# A new attempt invalidates every prior PASS artifact before it can fail.
gate0_invalidate_evidence $gate0_run_root

# Only this fixed, narrowly scoped generated case directory is replaced.
if {[file tail $gate0_case_dir] ne "legacy_full_chain"} {
    error "Refusing to clean an unexpected Gate 0 path: $gate0_case_dir"
}
file delete -force $gate0_case_dir
file mkdir $gate0_case_dir

set gate0_core_root [file join $gate0_board_root rtl core]
set gate0_legacy_manifest [file join $gate0_tests_dir \
    legacy_core_manifest.txt]
set gate0_sources [gate0_read_legacy_manifest \
    $gate0_board_root $gate0_legacy_manifest]
set gate0_behavioral_model [file join $gate0_repo_root \
    FPT_BC_QK_Softmax_PV_Delivery_v5 sim_models \
    floating_point_behavioral.sv]
set gate0_tb [file join $gate0_repo_root \
    A_attention_integration_final_v5 tb \
    tb_attention_system_with_rope_pv_small.sv]
set gate0_memory_files [list \
    [file join $gate0_board_root mem exp_lut_q15.mem] \
    [file join $gate0_tests_dir data rope_small_sin.hex] \
    [file join $gate0_tests_dir data rope_small_cos.hex]]

lappend gate0_sources [file normalize $gate0_behavioral_model]
lappend gate0_sources [file normalize $gate0_tb]

set gate0_required_files [concat $gate0_sources $gate0_memory_files]
set gate0_missing [list]
foreach required_file $gate0_required_files {
    if {![file isfile $required_file]} {
        lappend gate0_missing $required_file
    }
}
if {[llength $gate0_missing] != 0} {
    puts "Gate 0 cannot start. Missing files:"
    foreach missing_file $gate0_missing {
        puts "  $missing_file"
    }
    error "Gate 0 dependency check failed."
}

set tb_stream [open $gate0_tb r]
set tb_text [read $tb_stream]
close $tb_stream
foreach required_token {
    "Serial baseline full-chain smoke test"
    "CONTEXT_DUMP"
    "STATS_DUMP"
} {
    if {[string first $required_token $tb_text] < 0} {
        error "Shared full-chain TB is missing required token: $required_token"
    }
}

foreach memory_file $gate0_memory_files {
    file copy -force $memory_file \
        [file join $gate0_case_dir [file tail $memory_file]]
}

set gate0_context_name legacy_context.txt
set gate0_stats_name   legacy_stats.csv
set gate0_snapshot     gate0_legacy_snapshot

if {[catch {
    cd $gate0_case_dir
    puts "============================================================"
    puts "GATE 0: CANONICAL LEGACY FULL-CHAIN REGRESSION"
    puts "Canonical RTL : $gate0_core_root"
    puts "Generated work: $gate0_case_dir"
    puts "============================================================"

    gate0_run_external xvlog -sv {*}$gate0_sources
    gate0_run_external xelab tb_attention_system_with_rope_pv_small \
        -s $gate0_snapshot -debug typical
    gate0_run_external xsim $gate0_snapshot -runall \
        -testplusarg CONTEXT_DUMP=$gate0_context_name \
        -testplusarg STATS_DUMP=$gate0_stats_name

    set xsim_log [file join $gate0_case_dir xsim.log]
    if {![file isfile $xsim_log]} {
        error "XSim log was not created: $xsim_log"
    }
    set log_stream [open $xsim_log r]
    set log_text [read $log_stream]
    close $log_stream
    if {[regexp -nocase \
            {\$fatal|FATAL_ERROR|Fatal:|simulation failed} $log_text]} {
        error "XSim reported a fatal failure. Inspect: $xsim_log"
    }
    foreach pass_token {
        "[PASS] Serial baseline full-chain smoke test"
        "[PASS] Raw-QK+RoPE+QK+Mask+Softmax+real-PV full-chain smoke test"
    } {
        if {[string first $pass_token $log_text] < 0} {
            error "XSim log is missing the completion marker: $pass_token"
        }
    }

    set context_path [file join $gate0_case_dir $gate0_context_name]
    set stats_path   [file join $gate0_case_dir $gate0_stats_name]
    if {![file isfile $context_path] || ![file isfile $stats_path]} {
        error "Gate 0 result dump is incomplete."
    }

    set context_lines [gate0_read_nonempty_lines $context_path]
    set expected_contexts [expr {8 * 4 * 4 * 4}]
    if {[llength $context_lines] != $expected_contexts} {
        error "Context count mismatch: [llength $context_lines] / $expected_contexts"
    }
    foreach context_line $context_lines {
        if {[llength [split $context_line ","]] != 9} {
            error "Malformed Context result line: $context_line"
        }
    }

    set stats [gate0_read_stats $stats_path]
    foreach required_key {
        total_cycles
        bc_cycles
        pv_cycles
        overlap_cycles
        context_count
        duplicate_count
        missing_count
        error_bitmap
    } {
        if {![dict exists $stats $required_key]} {
            error "Gate 0 statistics key is missing: $required_key"
        }
    }
    if {[dict get $stats total_cycles] <= 0} {
        error "Legacy total cycle count must be positive."
    }
    if {[dict get $stats context_count] != $expected_contexts} {
        error "Legacy statistics Context count mismatch."
    }
    # v2.6 keeps the Legacy arithmetic path but schedules adjacent GQA Groups
    # through the production Ping-Pong controller. A positive overlap count is
    # therefore a required optimization invariant, not an error condition.
    if {[dict get $stats overlap_cycles] <= 0} {
        error "v2.6 Ping-Pong overlap count must be positive."
    }
    foreach zero_key {
        duplicate_count
        missing_count
        error_bitmap
    } {
        if {[dict get $stats $zero_key] != 0} {
            error "Legacy invariant failed: $zero_key=[dict get $stats $zero_key]"
        }
    }

    set gate0_git_sha unknown
    catch {
        set gate0_git_sha [string trim \
            [exec git -C $gate0_repo_root rev-parse HEAD]]
    }
    set gate0_vivado_version [version -short]
    set summary_path [file join $gate0_run_root gate0_summary.json]
    file mkdir $gate0_run_root
    set summary [open $summary_path w]
    puts $summary "{"
    puts $summary {  "schema": 1,}
    puts $summary {  "gate": "gate0_legacy",}
    puts $summary {  "status": "SIM_PASS",}
    puts $summary {  "closure_status": "NOT_RUN",}
    puts $summary {  "board_execution": "NOT_RUN",}
    puts $summary "  \"git_sha\": [gate0_json_string $gate0_git_sha],"
    puts $summary "  \"vivado\": [gate0_json_string $gate0_vivado_version],"
    puts $summary {  "canonical_rtl": "fpt_xczu15eg_attention/rtl/core",}
    puts $summary "  \"rtl_source_count\": [expr {[llength $gate0_sources] - 2}],"
    puts $summary "  \"context_count\": [llength $context_lines],"
    puts $summary "  \"total_cycles\": [dict get $stats total_cycles],"
    puts $summary "  \"bc_cycles\": [dict get $stats bc_cycles],"
    puts $summary "  \"pv_cycles\": [dict get $stats pv_cycles],"
    puts $summary "  \"overlap_cycles\": [dict get $stats overlap_cycles],"
    puts $summary "  \"error_bitmap\": [dict get $stats error_bitmap]"
    puts $summary "}"
    close $summary

    set compiled_manifest_path [file join $gate0_run_root \
        compiled_sources.txt]
    set manifest [open $compiled_manifest_path w]
    foreach source_file $gate0_sources {
        puts $manifest $source_file
    }
    close $manifest

    puts "============================================================"
    puts {[PASS] Gate 0 canonical Legacy simulation}
    puts "Context outputs : [llength $context_lines]"
    puts "Total cycles    : [dict get $stats total_cycles]"
    puts "Error bitmap    : [dict get $stats error_bitmap]"
    puts "Summary         : $summary_path"
    puts "Board execution : NOT RUN (simulation evidence only)"
    puts "============================================================"
} gate0_message gate0_options]} {
    cd $gate0_original_cwd
    return -options $gate0_options $gate0_message
}

cd $gate0_original_cwd
