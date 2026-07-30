# Reproducible, non-simulation Vivado build and hardware handoff driver.
#
# Batch example:
#   vivado -mode batch -source build_system_project.tcl -tclargs \
#     --xpr D:/repo/rk_xczu15eg_f/system/vx/ps_dma_loopback/rk_ps_dma_loopback.xpr \
#     --mode bitstream --jobs 4
#
# The xsa mode updates/generates IP output products and exports an XSA without
# starting synthesis.  The bitstream mode runs synth_1 and impl_1 through
# write_bitstream, writes implementation reports, copies the .bit file, and
# exports an XSA with -include_bit.  This script never launches simulation.

namespace eval ::rkbuild {
    variable cfg
    array set cfg {
        xpr ""
        mode "xsa"
        out ""
        expected_part "xczu15eg-ffvb1156-2-i"
        jobs 4
        upgrade_ip 1
        reset_runs 0
        help 0
    }

    variable state
    array set state {
        status "IN_PROGRESS"
        message ""
        project_name ""
        project_part ""
        output_dir ""
        xsa_path ""
        bit_path ""
        include_bit 0
        implementation_reports 0
        started_at ""
        finished_at ""
    }

    variable log_path ""
    variable project_opened_here 0
}

proc ::rkbuild::usage {} {
    puts {
Usage:
  vivado -mode batch -source build_system_project.tcl -tclargs \
    --xpr <project.xpr> [--mode xsa|bitstream] [--out <directory>] \
    [--expected-part xczu15eg-ffvb1156-2-i] [--jobs N] \
    [--upgrade-ip 0|1] [--reset-runs 0|1]

Modes:
  xsa        Generate/update IP and export an XSA without a bitstream.
             Synthesis, implementation and simulation are not launched.
  bitstream  Run synth_1 and impl_1 through write_bitstream, save reports,
             copy the bitstream, and export an XSA with -include_bit.

When --xpr is omitted in the Vivado GUI, the currently open project is used.
Default output:
  <system>/generated/vivado_build/<project-name>
}
}

proc ::rkbuild::parse_bool {value option_name} {
    set normalized [string tolower $value]
    if {$normalized in {1 true yes on}} {
        return 1
    }
    if {$normalized in {0 false no off}} {
        return 0
    }
    error "$option_name expects 0/1, true/false, yes/no, or on/off; got '$value'"
}

proc ::rkbuild::next_arg {argv_name index_name option_name} {
    upvar 1 $argv_name args
    upvar 1 $index_name i
    incr i
    if {$i >= [llength $args]} {
        error "missing value for $option_name"
    }
    return [lindex $args $i]
}

proc ::rkbuild::parse_args {args} {
    variable cfg
    set i 0
    while {$i < [llength $args]} {
        set option [lindex $args $i]
        switch -- $option {
            --xpr {
                set cfg(xpr) [next_arg args i $option]
            }
            --mode {
                set cfg(mode) [string tolower [next_arg args i $option]]
            }
            --out {
                set cfg(out) [next_arg args i $option]
            }
            --expected-part {
                set cfg(expected_part) [string tolower [next_arg args i $option]]
            }
            --jobs {
                set cfg(jobs) [next_arg args i $option]
            }
            --upgrade-ip {
                set cfg(upgrade_ip) [parse_bool [next_arg args i $option] $option]
            }
            --reset-runs {
                set cfg(reset_runs) [parse_bool [next_arg args i $option] $option]
            }
            --help -
            -help -
            -h {
                set cfg(help) 1
            }
            default {
                error "unknown option '$option'; use --help for usage"
            }
        }
        incr i
    }

    if {$cfg(help)} {
        return
    }
    if {$cfg(mode) ni {xsa bitstream}} {
        error "--mode must be 'xsa' or 'bitstream'; got '$cfg(mode)'"
    }
    if {![string is integer -strict $cfg(jobs)] || $cfg(jobs) < 1} {
        error "--jobs must be a positive integer; got '$cfg(jobs)'"
    }
}

proc ::rkbuild::current_xpr {} {
    set project [current_project -quiet]
    if {$project eq ""} {
        return ""
    }
    set project_dir [get_property DIRECTORY $project]
    set project_name [get_property NAME $project]
    return [file normalize [file join $project_dir "${project_name}.xpr"]]
}

proc ::rkbuild::json_escape {value} {
    return [string map {\\ \\\\ \" \\\" \n \\n \r \\r \t \\t} $value]
}

proc ::rkbuild::json_bool {value} {
    if {$value} {
        return "true"
    }
    return "false"
}

proc ::rkbuild::write_status {} {
    variable cfg
    variable state
    if {$state(output_dir) eq ""} {
        return
    }
    file mkdir $state(output_dir)
    set status_path [file join $state(output_dir) status.json]
    set fh [open $status_path w]
    puts $fh "\{"
    puts $fh "  \"schema_version\": 1,"
    puts $fh "  \"phase\": \"vivado_system_build\","
    puts $fh "  \"status\": \"[json_escape $state(status)]\","
    puts $fh "  \"message\": \"[json_escape $state(message)]\","
    puts $fh "  \"mode\": \"[json_escape $cfg(mode)]\","
    puts $fh "  \"project_name\": \"[json_escape $state(project_name)]\","
    puts $fh "  \"project_xpr\": \"[json_escape $cfg(xpr)]\","
    puts $fh "  \"expected_part\": \"[json_escape $cfg(expected_part)]\","
    puts $fh "  \"project_part\": \"[json_escape $state(project_part)]\","
    puts $fh "  \"jobs\": $cfg(jobs),"
    puts $fh "  \"upgrade_ip\": [json_bool $cfg(upgrade_ip)],"
    puts $fh "  \"reset_runs\": [json_bool $cfg(reset_runs)],"
    puts $fh "  \"simulation_launched\": false,"
    puts $fh "  \"include_bit\": [json_bool $state(include_bit)],"
    puts $fh "  \"implementation_reports\": [json_bool $state(implementation_reports)],"
    puts $fh "  \"xsa\": \"[json_escape $state(xsa_path)]\","
    puts $fh "  \"bitstream\": \"[json_escape $state(bit_path)]\","
    puts $fh "  \"hardware_state\": \"HARDWARE_PENDING\","
    puts $fh "  \"started_at\": \"[json_escape $state(started_at)]\","
    puts $fh "  \"finished_at\": \"[json_escape $state(finished_at)]\""
    puts $fh "\}"
    close $fh
}

proc ::rkbuild::log {message} {
    variable log_path
    set timestamp [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%S%z"]
    set line "$timestamp $message"
    puts $line
    if {$log_path ne ""} {
        set fh [open $log_path a]
        puts $fh $line
        close $fh
    }
}

proc ::rkbuild::write_text {path text} {
    file mkdir [file dirname $path]
    set fh [open $path w]
    puts $fh $text
    close $fh
}

proc ::rkbuild::report_ip_status_to {path} {
    file mkdir [file dirname $path]
    report_ip_status -file $path
}

proc ::rkbuild::prepare_ip {reports_dir} {
    variable cfg

    set ips [get_ips -quiet]
    set standalone_ips {}
    foreach ip $ips {
        set ip_file [string map {\\ /} \
            [file normalize [get_property IP_FILE $ip]]]
        if {([string first ".srcs/sources_1/bd/" $ip_file] < 0) &&
            ([string first ".gen/" $ip_file] < 0)} {
            lappend standalone_ips $ip
        }
    }
    # get_files also returns nested block designs generated inside complex IP
    # such as DDR4.  Those .gen sub-designs can only be generated by their
    # parent IP; only source BDs owned by the project are valid targets here.
    set bd_files {}
    foreach bd_file [get_files -quiet \
                         -filter {FILE_TYPE == "Block Designs"}] {
        set normalized_bd [string map {\\ /} [file normalize $bd_file]]
        if {[string first ".srcs/" $normalized_bd] >= 0} {
            lappend bd_files $bd_file
        }
    }
    report_ip_status_to [file join $reports_dir ip_status_before.rpt]
    log "IP inventory: [llength $ips] total, [llength $standalone_ips] standalone, [llength $bd_files] source block design(s)"

    if {$cfg(upgrade_ip)} {
        foreach ip $standalone_ips {
            set needs_upgrade 0
            if {![catch {get_property IS_LOCKED $ip} locked] && $locked} {
                set needs_upgrade 1
            }
            if {![catch {get_property UPGRADE_VERSIONS $ip} versions] &&
                [llength $versions] > 0} {
                set needs_upgrade 1
            }
            if {$needs_upgrade} {
                log "Upgrading IP: $ip"
                if {[catch {upgrade_ip $ip} upgrade_error]} {
                    error "failed to upgrade IP '$ip': $upgrade_error"
                }
            }
        }
    } else {
        log "IP upgrade disabled by --upgrade-ip 0"
    }

    # Generate the containing block design first, then standalone IP objects.
    # Vivado treats already-generated targets as up to date.
    if {[llength $bd_files] > 0} {
        log "Generating block-design output products"
        generate_target all $bd_files
    }
    if {[llength $standalone_ips] > 0} {
        log "Generating standalone IP output products"
        generate_target all $standalone_ips
        export_ip_user_files -of_objects $standalone_ips \
            -no_script -sync -force
    }
    update_compile_order -fileset sources_1
    report_ip_status_to [file join $reports_dir ip_status_after.rpt]

    set locked_ips [get_ips -quiet -filter {IS_LOCKED == 1}]
    if {[llength $locked_ips] > 0} {
        error "locked IP remains after preparation: [join $locked_ips {, }]"
    }
}

proc ::rkbuild::run_is_complete {run_name} {
    set run [get_runs -quiet $run_name]
    if {$run eq ""} {
        error "required Vivado run '$run_name' does not exist"
    }
    set progress [get_property PROGRESS $run]
    set status [get_property STATUS $run]
    return [expr {$progress eq "100%" && [string match -nocase "*complete*" $status]}]
}

proc ::rkbuild::run_is_failed {run_name} {
    set status [string toupper [get_property STATUS [get_runs $run_name]]]
    return [expr {
        [string match "*ERROR*" $status] ||
        [string match "*FAIL*" $status] ||
        [string match "*CANCEL*" $status]
    }]
}

proc ::rkbuild::write_run_status {run_name path} {
    set run [get_runs $run_name]
    set lines [list \
        "name=$run_name" \
        "status=[get_property STATUS $run]" \
        "progress=[get_property PROGRESS $run]" \
        "needs_refresh=[get_property NEEDS_REFRESH $run]" \
        "directory=[get_property DIRECTORY $run]"]
    write_text $path [join $lines "\n"]
}

proc ::rkbuild::launch_or_reuse_run {run_name args} {
    variable cfg
    set run [get_runs -quiet $run_name]
    if {$run eq ""} {
        error "required Vivado run '$run_name' does not exist"
    }

    set needs_refresh [get_property NEEDS_REFRESH $run]
    if {$cfg(reset_runs) || $needs_refresh || [run_is_failed $run_name]} {
        log "Resetting run $run_name (requested=$cfg(reset_runs), refresh=$needs_refresh)"
        reset_run $run_name
    }

    if {[run_is_complete $run_name]} {
        log "Reusing current completed run $run_name"
        return
    }

    log "Launching $run_name"
    if {[llength $args] == 0} {
        launch_runs $run_name -jobs $cfg(jobs)
    } else {
        launch_runs $run_name {*}$args -jobs $cfg(jobs)
    }
    wait_on_run $run_name
    if {![run_is_complete $run_name]} {
        set status [get_property STATUS [get_runs $run_name]]
        set progress [get_property PROGRESS [get_runs $run_name]]
        error "$run_name did not complete successfully (status='$status', progress='$progress')"
    }
}

proc ::rkbuild::find_bitstream {} {
    set impl_run [get_runs impl_1]
    set run_dir [get_property DIRECTORY $impl_run]
    set top [get_property TOP [get_filesets sources_1]]
    set expected [file join $run_dir "${top}.bit"]
    if {[file exists $expected]} {
        return [file normalize $expected]
    }
    set candidates [glob -nocomplain -directory $run_dir *.bit]
    if {[llength $candidates] == 1} {
        return [file normalize [lindex $candidates 0]]
    }
    error "unable to identify a unique bitstream in '$run_dir' (expected '$expected')"
}

proc ::rkbuild::write_not_generated_markers {reports_dir} {
    set reason "NOT GENERATED: --mode xsa intentionally does not launch synthesis or implementation."
    foreach name {timing_summary utilization_hierarchical methodology drc} {
        write_text [file join $reports_dir "${name}.NOT_GENERATED.txt"] $reason
    }
}

proc ::rkbuild::export_xsa {xsa_path include_bit} {
    file mkdir [file dirname $xsa_path]
    if {$include_bit} {
        log "Exporting hardware platform with included bitstream: $xsa_path"
        write_hw_platform -fixed -include_bit -force -file $xsa_path
    } else {
        log "Exporting hardware platform without bitstream: $xsa_path"
        write_hw_platform -fixed -force -file $xsa_path
    }
    if {![file exists $xsa_path]} {
        error "Vivado returned from write_hw_platform but XSA was not created: $xsa_path"
    }
}

proc ::rkbuild::build {} {
    variable cfg
    variable state
    variable log_path
    variable project_opened_here

    set state(started_at) [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%S%z"]

    if {$cfg(xpr) eq ""} {
        set cfg(xpr) [current_xpr]
    }
    if {$cfg(xpr) eq ""} {
        error "--xpr is required in batch mode; no Vivado GUI project is currently open"
    }
    set cfg(xpr) [file normalize $cfg(xpr)]
    if {![file isfile $cfg(xpr)]} {
        error "XPR does not exist: $cfg(xpr)"
    }

    set project_stem [file rootname [file tail $cfg(xpr)]]
    set state(project_name) $project_stem
    if {$cfg(out) eq ""} {
        set system_dir [file dirname [file dirname [file normalize [info script]]]]
        set cfg(out) [file join $system_dir generated vivado_build $project_stem]
    }
    set cfg(out) [file normalize $cfg(out)]
    set state(output_dir) $cfg(out)
    set reports_dir [file join $cfg(out) reports]
    set artifacts_dir [file join $cfg(out) artifacts]
    file mkdir $reports_dir
    file mkdir $artifacts_dir
    set log_path [file join $cfg(out) build.log]
    write_text $log_path ""
    set state(message) "build started"
    write_status

    set already_open [current_xpr]
    if {$already_open eq ""} {
        log "Opening Vivado project: $cfg(xpr)"
        open_project $cfg(xpr)
        set project_opened_here 1
    } elseif {![string equal -nocase [file normalize $already_open] $cfg(xpr)]} {
        error "another Vivado project is already open: $already_open"
    } else {
        log "Using currently open Vivado GUI project: $cfg(xpr)"
    }

    set state(project_name) [get_property NAME [current_project]]
    set state(project_part) [string tolower [get_property PART [current_project]]]
    if {$state(project_part) ne $cfg(expected_part)} {
        error "part mismatch: expected '$cfg(expected_part)', project uses '$state(project_part)'"
    }
    log "Exact part check passed: $state(project_part)"
    log "Build mode: $cfg(mode); simulation is disabled"

    prepare_ip $reports_dir

    set xsa_path [file normalize [file join $artifacts_dir "$state(project_name).xsa"]]
    set state(xsa_path) $xsa_path
    if {$cfg(mode) eq "xsa"} {
        write_not_generated_markers $reports_dir
        export_xsa $xsa_path 0
    } else {
        launch_or_reuse_run synth_1
        write_run_status synth_1 [file join $reports_dir synthesis_run_status.txt]

        launch_or_reuse_run impl_1 -to_step write_bitstream
        write_run_status impl_1 [file join $reports_dir implementation_run_status.txt]

        log "Opening implemented design and writing sign-off reports"
        open_run impl_1
        report_timing_summary -delay_type max -report_unconstrained \
            -check_timing_verbose -max_paths 20 -file \
            [file join $reports_dir timing_summary.rpt]
        report_utilization -hierarchical -file \
            [file join $reports_dir utilization_hierarchical.rpt]
        report_methodology -file [file join $reports_dir methodology.rpt]
        report_drc -file [file join $reports_dir drc.rpt]
        set state(implementation_reports) 1

        set source_bit [find_bitstream]
        set delivered_bit [file normalize \
            [file join $artifacts_dir "$state(project_name).bit"]]
        file copy -force $source_bit $delivered_bit
        set state(bit_path) $delivered_bit
        set state(include_bit) 1
        export_xsa $xsa_path 1
    }

    set state(status) "SOFTWARE_PASS"
    set state(message) "Vivado build completed; physical board validation remains HARDWARE_PENDING"
    set state(finished_at) [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%S%z"]
    write_status
    log "RK_VIVADO_BUILD_COMPLETE=$cfg(out)"
    log "RK_VIVADO_XSA=$state(xsa_path)"
    if {$state(bit_path) ne ""} {
        log "RK_VIVADO_BITSTREAM=$state(bit_path)"
    }
}

set rkbuild_exit_code 0
if {[catch {
    ::rkbuild::parse_args {*}$argv
    if {$::rkbuild::cfg(help)} {
        ::rkbuild::usage
    } else {
        ::rkbuild::build
    }
} rkbuild_error rkbuild_options]} {
    set rkbuild_exit_code 1
    set ::rkbuild::state(status) "FAILED"
    set ::rkbuild::state(message) $rkbuild_error
    set ::rkbuild::state(finished_at) \
        [clock format [clock seconds] -format "%Y-%m-%dT%H:%M:%S%z"]
    catch {::rkbuild::write_status}
    catch {::rkbuild::log "RK_VIVADO_BUILD_FAILED=$rkbuild_error"}
    puts stderr "RK_VIVADO_BUILD_FAILED=$rkbuild_error"
    if {[dict exists $rkbuild_options -errorinfo]} {
        puts stderr [dict get $rkbuild_options -errorinfo]
    }
}

if {$::rkbuild::project_opened_here} {
    catch {close_project}
}
if {$rkbuild_exit_code != 0} {
    # Propagate an error to batch callers without forcibly terminating a
    # Vivado GUI session that sourced this script from its Tcl Console.
    return -code error $rkbuild_error
}
