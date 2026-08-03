# Unified Vivado entry point for the v2.6 Causal Dual-Tile delivery.
# The AI-facing wrappers in vivado_tcl_ai_reuse/ dispatch through this file.

namespace eval ::fpt_vivado {
    variable flow_script [file normalize [info script]]
    variable script_dir [file dirname $flow_script]
    variable project_root [file normalize [file join $script_dir ..]]
}

proc ::fpt_vivado::require_vivado {} {
    if {[llength [info commands version]] == 0 ||
        [llength [info commands get_parts]] == 0} {
        error "This flow must be sourced from the Vivado Tcl Console"
    }
}

proc ::fpt_vivado::require_jobs {jobs} {
    if {![string is integer -strict $jobs] || $jobs < 1} {
        error "jobs must be a positive integer, got: $jobs"
    }
}

proc ::fpt_vivado::load_config {} {
    variable script_dir
    return [file join $script_dir project_config.tcl]
}

proc ::fpt_vivado::print_help {} {
    puts ""
    puts "FPT XCZU15EG v2.6 Vivado flow"
    puts "  fpt_vivado::run create"
    puts "  fpt_vivado::run open"
    puts "  fpt_vivado::run elaborate"
    puts "  fpt_vivado::run sim_online"
    puts "  fpt_vivado::run synth ?jobs?"
    puts "  fpt_vivado::run implement ?jobs?"
    puts "  fpt_vivado::run bitstream ?jobs?"
    puts "  fpt_vivado::run reports"
    puts ""
    puts "Recommended order: elaborate -> sim_online -> synth -> implement -> bitstream"
    puts ""
}

proc ::fpt_vivado::open_project_if_needed {} {
    source [load_config]
    if {[llength [get_projects -quiet]] > 0} {
        set current_dir [file normalize [get_property DIRECTORY [current_project]]]
        set expected_dir [file normalize $fpt_project_dir]
        if {![string equal -nocase $current_dir $expected_dir]} {
            error "Another Vivado project is open: $current_dir"
        }
        return
    }
    if {![file isfile $fpt_project_file]} {
        error "Generated project does not exist. Run: fpt_vivado::run create"
    }
    open_project $fpt_project_file
}

proc ::fpt_vivado::check_run_complete {run_name stage_name} {
    set status [get_property STATUS [get_runs $run_name]]
    if {![string match {*Complete*} $status]} {
        error "$stage_name did not complete successfully: $status"
    }
    puts "\[PASS\] $stage_name: $status"
}

proc ::fpt_vivado::run_project_synthesis {jobs} {
    require_jobs $jobs
    open_project_if_needed
    reset_run synth_1
    launch_runs synth_1 -jobs $jobs
    wait_on_run synth_1
    check_run_complete synth_1 "Synthesis"
    open_run synth_1
}

proc ::fpt_vivado::run_project_implementation {jobs} {
    require_jobs $jobs
    open_project_if_needed
    set synth_status [get_property STATUS [get_runs synth_1]]
    if {![string match {*Complete*} $synth_status]} {
        run_project_synthesis $jobs
    }
    reset_run impl_1
    launch_runs impl_1 -to_step route_design -jobs $jobs
    wait_on_run impl_1
    check_run_complete impl_1 "Implementation"
    open_run impl_1
}

proc ::fpt_vivado::run_online_simulation {} {
    variable project_root
    set runner [file join $project_root tests run_online_softmax_vivado.ps1]
    if {![file isfile $runner]} {
        error "Missing Online Softmax regression runner: $runner"
    }
    set powershell [auto_execok powershell]
    if {$powershell eq ""} {
        error "powershell was not found"
    }
    set result [exec $powershell -NoProfile -ExecutionPolicy Bypass -File $runner]
    puts $result
}

proc ::fpt_vivado::write_reports {} {
    variable project_root
    open_project_if_needed
    set impl_status [get_property STATUS [get_runs impl_1]]
    if {![string match {*Complete*} $impl_status]} {
        error "Implementation is not complete: $impl_status"
    }
    open_run impl_1
    set report_dir [file join $project_root reports v2.6_causal_dualtile]
    file mkdir $report_dir
    report_utilization -hierarchical \
        -file [file join $report_dir utilization_impl.rpt]
    report_timing_summary -delay_type min_max -report_unconstrained \
        -check_timing_verbose -max_paths 20 \
        -file [file join $report_dir timing_summary_impl.rpt]
    report_drc -file [file join $report_dir drc_impl.rpt]
    report_power -file [file join $report_dir power_impl.rpt]
    puts "\[PASS\] Reports written to: $report_dir"
}

proc ::fpt_vivado::run {action {jobs 8}} {
    variable script_dir
    set action [string tolower [string trim $action]]
    if {$action eq "help"} {
        print_help
        return
    }
    require_vivado
    switch -- $action {
        create {
            source [file join $script_dir create_attention_board_project.tcl]
        }
        open {
            open_project_if_needed
            puts "\[PASS\] Opened: [get_property DIRECTORY [current_project]]"
        }
        elaborate {
            source [file join $script_dir check_rtl_elaboration_ipfix.tcl]
        }
        sim_online {
            run_online_simulation
        }
        synth {
            run_project_synthesis $jobs
        }
        implement {
            run_project_implementation $jobs
        }
        bitstream {
            require_jobs $jobs
            set ::env(FPT_JOBS) $jobs
            source [file join $script_dir build_profile_foreground_ipfix.tcl]
        }
        reports {
            write_reports
        }
        default {
            print_help
            error "Unknown Vivado flow action: $action"
        }
    }
}

::fpt_vivado::print_help
