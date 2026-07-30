# Reproducible Vivado entry point for the RK-XCZU15EG-F V1.0 PL-only
# single-GQA golden self-test.
#
# Examples:
#   vivado -mode batch -source build_rk_xczu15eg_pl_selftest.tcl \
#       -tclargs all
#   source rk_xczu15eg_f/build_rk_xczu15eg_pl_selftest.tcl
#
# Supported actions: project, sim, bitstream, all. The default is "project"
# when sourced without Tcl arguments, which is the safest GUI behavior.

set rk_root [file normalize [file dirname [info script]]]
set action project
if {$argc > 0} {
    set action [string tolower [lindex $argv 0]]
}

set project_script \
    [file join $rk_root scripts create_rk_pl_selftest_project.tcl]
set sim_script \
    [file join $rk_root scripts run_rk_pl_selftest_sim.tcl]
set bitstream_script \
    [file join $rk_root scripts build_rk_pl_selftest_bitstream.tcl]

switch -- $action {
    project {
        source $project_script
    }
    sim {
        source $sim_script
    }
    bitstream {
        source $bitstream_script
    }
    all {
        source $project_script
        source $sim_script
        source $bitstream_script
    }
    default {
        error "Unknown RK Stage 1 action '$action'; use project, sim, bitstream, or all"
    }
}

puts "RK_STAGE1_ACTION_COMPLETE=$action"
