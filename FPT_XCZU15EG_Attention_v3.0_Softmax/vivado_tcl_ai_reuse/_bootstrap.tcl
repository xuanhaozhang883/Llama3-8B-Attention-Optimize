# Shared bootstrap for the AI-facing wrapper scripts.
namespace eval ::fpt_ai_tcl {
    variable toolkit_dir [file normalize [file dirname [info script]]]
    variable delivery_root [file normalize [file join $toolkit_dir ..]]
}

proc ::fpt_ai_tcl::require_vivado {} {
    if {[llength [info commands version]] == 0 ||
        [llength [info commands get_parts]] == 0} {
        error "Run this script from the Vivado Tcl Console"
    }
}

proc ::fpt_ai_tcl::jobs {} {
    set value 8
    if {[info exists ::env(FPT_JOBS)] &&
        [string trim $::env(FPT_JOBS)] ne ""} {
        set value [string trim $::env(FPT_JOBS)]
    }
    if {![string is integer -strict $value] || $value < 1} {
        error "FPT_JOBS must be a positive integer, got: $value"
    }
    return $value
}

proc ::fpt_ai_tcl::load_flow {} {
    variable delivery_root
    require_vivado
    set flow [file join $delivery_root scripts vivado_flow.tcl]
    if {![file isfile $flow]} {
        error "Missing canonical Vivado flow: $flow"
    }
    source $flow
}

proc ::fpt_ai_tcl::run {action} {
    load_flow
    set parallel_jobs [jobs]
    ::fpt_vivado::run $action $parallel_jobs
}

