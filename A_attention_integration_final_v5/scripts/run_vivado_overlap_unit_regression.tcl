# Corrected GQA overlap unit regression.
#
# Run from Vivado Tcl Console:
#   cd <repo>/A_attention_integration_final_v5
#   source scripts/run_vivado_overlap_unit_regression.tcl

set script_dir [file dirname [info script]]
set a_root     [file dirname $script_dir]
set run_root   [file join [file dirname [file dirname $a_root]] \
                     gqa_overlap_unit_regression]

set adapter [file join $a_root rtl adapter \
                 pv_tile2_to_tile4_buffer_adapter.sv]
set buffer [file join $a_root rtl optimization_v24 \
                gqa_pingpong_buffer.sv]
set scheduler [file join $a_root rtl optimization_v24 \
                   gqa_overlap_scheduler.sv]
set counters [file join $a_root rtl optimization_v24 \
                  attention_overlap_perf_counters.sv]

set tb_buffer [file join $a_root tb optimization_v24 \
                   tb_gqa_pingpong_buffer.sv]
set tb_scheduler [file join $a_root tb optimization_v24 \
                      tb_gqa_overlap_scheduler.sv]
set tb_counters [file join $a_root tb optimization_v24 \
                     tb_attention_overlap_perf_counters.sv]

set required_files [list \
    $adapter $buffer $scheduler $counters \
    $tb_buffer $tb_scheduler $tb_counters]

set missing_files [list]
foreach file_name $required_files {
    if {![file isfile $file_name]} {
        lappend missing_files $file_name
    }
}

if {[llength $missing_files] != 0} {
    puts "============================================================"
    puts "OVERLAP UNIT REGRESSION CANNOT START"
    puts "The following required files are missing:"
    foreach file_name $missing_files {
        puts "  $file_name"
    }
    puts "============================================================"
    error "Install the corrected overlap_v24 package first."
}

file delete -force $run_root
file mkdir $run_root

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

proc run_case {run_root case_name top_name sources} {
    set case_dir [file join $run_root $case_name]
    file mkdir $case_dir
    cd $case_dir

    puts "============================================================"
    puts "RUNNING: $case_name"
    puts "============================================================"

    run_external xvlog -sv {*}$sources
    run_external xelab $top_name \
        -s ${case_name}_snapshot -debug typical
    run_external xsim ${case_name}_snapshot -runall
}

run_case $run_root unit_buffer tb_gqa_pingpong_buffer \
    [list $adapter $buffer $tb_buffer]

run_case $run_root unit_scheduler tb_gqa_overlap_scheduler \
    [list $scheduler $tb_scheduler]

run_case $run_root unit_counters tb_attention_overlap_perf_counters \
    [list $counters $tb_counters]

puts "============================================================"
puts {[PASS] CORRECTED GQA OVERLAP UNIT REGRESSION}
puts "Buffer       : PASS"
puts "Scheduler    : PASS"
puts "Counters     : PASS"
puts "Run directory: $run_root"
puts "============================================================"

