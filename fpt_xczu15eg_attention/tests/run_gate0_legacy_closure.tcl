# Gate 0 one-click closure:
#   1. Canonical Legacy full-chain XSim regression.
#   2. Host-side package/profile contract checks.
#   3. XCZU15EG board-top RTL elaboration.
#
# This script is intended to be sourced from the Vivado GUI Tcl Console.

set gate0_closure_script [file normalize [info script]]
set gate0_closure_tests  [file dirname $gate0_closure_script]
set gate0_closure_root   [file normalize [file join $gate0_closure_tests ..]]
set gate0_closure_repo   [file normalize [file join $gate0_closure_root ..]]

# Invalidate the prior closure before any new step can fail.  The simulation
# entry performs the same invalidation so that a quick rerun also revokes a
# previous full-closure claim.
if {[info exists ::env(FPT_RTL_GATE_BUILD_ROOT)] &&
    [string trim $::env(FPT_RTL_GATE_BUILD_ROOT)] ne ""} {
    set gate0_closure_build_parent \
        [file normalize $::env(FPT_RTL_GATE_BUILD_ROOT)]
} else {
    set gate0_closure_build_parent [file join $gate0_closure_root \
        build rtl_gates]
}
set gate0_closure_run_root [file normalize \
    [file join $gate0_closure_build_parent gate0_legacy]]
if {[file tail $gate0_closure_run_root] ne "gate0_legacy"} {
    error "Refusing to invalidate an unexpected Gate 0 path."
}
foreach gate0_stale_leaf {
    gate0_closure_summary.json
    GATE0_CLOSURE_PASS.txt
    gate0_closure_summary.json.tmp
    GATE0_CLOSURE_PASS.txt.tmp
} {
    set gate0_stale_path [file join $gate0_closure_run_root \
        $gate0_stale_leaf]
    if {[file exists $gate0_stale_path]} {
        if {[file isdirectory $gate0_stale_path]} {
            error "Refusing to replace an evidence directory: $gate0_stale_path"
        }
        file delete -force $gate0_stale_path
    }
}

source [file join $gate0_closure_tests run_gate0_legacy_regression.tcl]

set gate0_python [auto_execok python]
if {$gate0_python eq ""} {
    error "Gate 0 requires Python on PATH for host-side contract checks."
}

set gate0_host_results [file join $gate0_run_root host_checks]
file mkdir $gate0_host_results

proc gate0_closure_exec {args} {
    puts "COMMAND: [join $args { }]"
    if {[catch {set output [exec {*}$args 2>@1]} message]} {
        puts $message
        error "Gate 0 host check failed: [join $args { }]"
    }
    puts $output
}

set gate0_had_pycache_prefix \
    [info exists ::env(PYTHONPYCACHEPREFIX)]
if {$gate0_had_pycache_prefix} {
    set gate0_old_pycache_prefix $::env(PYTHONPYCACHEPREFIX)
}
set ::env(PYTHONPYCACHEPREFIX) [file join $gate0_host_results pycache]

if {[catch {
    gate0_closure_exec $gate0_python \
        [file join $gate0_closure_root python audit_package.py]
    gate0_closure_exec $gate0_python \
        [file join $gate0_closure_root python validate_profile_contract.py]
    gate0_closure_exec $gate0_python \
        [file join $gate0_closure_root python parse_v23_profile_log.py] \
        [file join $gate0_closure_tests sample_profile_v24.txt] \
        --out-dir $gate0_host_results
    gate0_closure_exec $gate0_python \
        [file join $gate0_closure_root python validate_profile_results.py] \
        [file join $gate0_host_results v23_hardware_profile_runs.csv] \
        --expected-runs 1
} gate0_host_message gate0_host_options]} {
    if {$gate0_had_pycache_prefix} {
        set ::env(PYTHONPYCACHEPREFIX) $gate0_old_pycache_prefix
    } else {
        unset ::env(PYTHONPYCACHEPREFIX)
    }
    return -options $gate0_host_options $gate0_host_message
}

if {$gate0_had_pycache_prefix} {
    set ::env(PYTHONPYCACHEPREFIX) $gate0_old_pycache_prefix
} else {
    unset ::env(PYTHONPYCACHEPREFIX)
}

set gate0_had_build_root [info exists ::env(FPT_VIVADO_BUILD_ROOT)]
if {$gate0_had_build_root} {
    set gate0_old_build_root $::env(FPT_VIVADO_BUILD_ROOT)
}
if {!$gate0_had_build_root ||
    [string trim $::env(FPT_VIVADO_BUILD_ROOT)] eq ""} {
    set ::env(FPT_VIVADO_BUILD_ROOT) [file join $gate0_run_root \
        board_elaboration]
}

if {[catch {
    source [file join $gate0_closure_root scripts \
        check_rtl_elaboration.tcl]
} gate0_elab_message gate0_elab_options]} {
    if {$gate0_had_build_root} {
        set ::env(FPT_VIVADO_BUILD_ROOT) $gate0_old_build_root
    } else {
        unset ::env(FPT_VIVADO_BUILD_ROOT)
    }
    return -options $gate0_elab_options $gate0_elab_message
}

if {$gate0_had_build_root} {
    set ::env(FPT_VIVADO_BUILD_ROOT) $gate0_old_build_root
} else {
    unset ::env(FPT_VIVADO_BUILD_ROOT)
}

set gate0_pass_file [file join $gate0_run_root \
    GATE0_CLOSURE_PASS.txt]
set gate0_closure_summary [file join $gate0_run_root \
    gate0_closure_summary.json]
set gate0_pass_temp "${gate0_pass_file}.tmp"
set gate0_closure_temp "${gate0_closure_summary}.tmp"

# Publish both closure artifacts as one guarded operation.  If either write or
# rename fails, neither final artifact is allowed to survive.
if {[catch {
    file mkdir $gate0_run_root

    set gate0_closure_stream [open $gate0_closure_temp w]
    puts $gate0_closure_stream "{"
    puts $gate0_closure_stream {  "schema": 1,}
    puts $gate0_closure_stream {  "gate": "gate0_legacy",}
    puts $gate0_closure_stream {  "status": "CLOSURE_PASS",}
    puts $gate0_closure_stream {  "simulation_status": "SIM_PASS",}
    puts $gate0_closure_stream {  "host_checks": "PASS",}
    puts $gate0_closure_stream {  "board_rtl_elaboration": "PASS",}
    puts $gate0_closure_stream {  "board_execution": "NOT_RUN",}
    puts $gate0_closure_stream \
        "  \"vivado\": [gate0_json_string [version -short]],"
    puts $gate0_closure_stream \
        {  "simulation_summary": "gate0_summary.json"}
    puts $gate0_closure_stream "}"
    close $gate0_closure_stream

    set gate0_pass_stream [open $gate0_pass_temp w]
    puts $gate0_pass_stream "Gate 0 Legacy closure: CLOSURE_PASS"
    puts $gate0_pass_stream "Vivado: [version -short]"
    puts $gate0_pass_stream "Board execution: NOT RUN"
    puts $gate0_pass_stream \
        "Evidence: full-chain XSim + host contracts + board-top RTL elaboration"
    close $gate0_pass_stream

    file rename -force $gate0_closure_temp $gate0_closure_summary
    file rename -force $gate0_pass_temp $gate0_pass_file
} gate0_publish_message gate0_publish_options]} {
    foreach gate0_publish_path [list \
            $gate0_pass_file $gate0_closure_summary \
            $gate0_pass_temp $gate0_closure_temp] {
        if {[file exists $gate0_publish_path] &&
            ![file isdirectory $gate0_publish_path]} {
            file delete -force $gate0_publish_path
        }
    }
    return -options $gate0_publish_options $gate0_publish_message
}

puts "============================================================"
puts {[PASS] GATE 0 LEGACY CLOSURE}
puts "Marker          : $gate0_pass_file"
puts "Summary         : $gate0_closure_summary"
puts "Board execution : NOT RUN"
puts "Next Gate       : Online Softmax Golden (do not start before commit)"
puts "============================================================"
