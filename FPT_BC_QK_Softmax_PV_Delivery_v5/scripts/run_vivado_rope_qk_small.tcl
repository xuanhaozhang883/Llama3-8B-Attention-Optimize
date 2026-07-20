set origin_dir [file normalize [file join [file dirname [info script]] ..]]
set repo_dir [file normalize [file join $origin_dir ..]]
set project_dir [file join $origin_dir vivado_rope_qk_small_sim]
catch {close_sim}
if {[llength [get_projects -quiet]] > 0} { close_project }
create_project fpt_rope_qk_small $project_dir -part xc7a35tcpg236-1 -force
set rtl_files [concat \
    [glob -nocomplain [file join $origin_dir rtl rope *.sv]] \
    [list [file join $origin_dir rtl integration rope_group_bridge.sv]] \
    [glob -nocomplain [file join $origin_dir rtl qk *.sv]] \
    [glob -nocomplain [file join $origin_dir rtl qk *.v]] \
    [list [file join $repo_dir RoPE bf16_mul.v]] \
    [list [file join $repo_dir RoPE bf16_addsub.v]]]
add_files -norecurse $rtl_files
add_files -fileset sim_1 -norecurse [list \
    [file join $origin_dir sim_models floating_point_behavioral.sv] \
    [file join $origin_dir tb tb_rope_qk_pipeline_small.sv] \
    [file join $origin_dir tb data rope_small_sin.hex] \
    [file join $origin_dir tb data rope_small_cos.hex]]
set_property file_type SystemVerilog [get_files -quiet *.sv]
set_property top tb_rope_qk_pipeline_small [get_filesets sim_1]
# GUI-friendly setting: one click on "Run Behavioral Simulation" runs beyond
# the 28.54 us self-check instead of stopping at Vivado's 1000 ns default.
set_property xsim.simulate.runtime 100us [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
close_sim
set sim_log [file join $project_dir fpt_rope_qk_small.sim sim_1 behav xsim simulate.log]
if {![file exists $sim_log]} {
    error "XSim log was not generated: $sim_log"
}
set log_fd [open $sim_log r]
set log_text [read $log_fd]
close $log_fd
if {[string first "TEST_RESULT: PASS RoPE->QK" $log_text] < 0} {
    error "RoPE->QK simulation did not report PASS; inspect $sim_log"
}
puts "RoPE->QK small integration finished; require TEST_RESULT: PASS."
