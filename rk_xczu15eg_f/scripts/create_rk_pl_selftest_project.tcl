# Create a persistent, from-scratch Vivado project for the RK-XCZU15EG-F
# PL-only one-GQA attention golden self-test.

set script_dir [file normalize [file dirname [info script]]]
set rk_root    [file normalize [file join $script_dir ..]]
set repo_root  [file normalize [file join $rk_root ..]]
set a_root     [file join $repo_root A_attention_integration_final_v5]
set bc_root    [file join $repo_root FPT_BC_QK_Softmax_PV_Delivery_v5]
set rope_root  [file join $repo_root QK_after_RoPE]
set pv_root    [file join $repo_root PV_module]
set golden_dir [file join $a_root tb golden_fpga_slice_data]
set data_dir   [file join $rk_root generated selftest_data]
set project_name rk_pl_selftest
# Keep the generated path short: Chipscope dbg_hub insertion on Windows fails
# when the implementation temporary directory exceeds 146 characters.
set project_dir  [file join $rk_root vx]
set part_name    xczu15eg-ffvb1156-2-i

proc rk_read_hex_lines {path} {
    set fh [open $path r]
    set data [split [string trim [read $fh]] "\n"]
    close $fh
    return $data
}

proc rk_write_hex_lines {path data} {
    set fh [open $path w]
    foreach value $data {
        puts $fh [string trim $value]
    }
    close $fh
}

proc rk_require_files {paths} {
    foreach path $paths {
        if {![file isfile $path]} {
            error "Required RK self-test input is missing: $path"
        }
    }
}

file mkdir $data_dir

# Derive the banked self-test images from the checked-in golden slice.
set q [rk_read_hex_lines [file join $golden_dir q_before_rope_bf16.hex]]
set k [rk_read_hex_lines [file join $golden_dir k_before_rope_bf16.hex]]
set v [rk_read_hex_lines [file join $golden_dir v_bf16.hex]]
if {[llength $q] != 65536 ||
    [llength $k] != 16384 ||
    [llength $v] != 16384} {
    error "Unexpected fpga_slice Q/K/V vector length"
}

set q_lo {}
set q_hi {}
for {set h 0} {$h < 4} {incr h} {
    for {set token 0} {$token < 128} {incr token} {
        set base [expr {($h*128+$token)*128}]
        for {set pair 0} {$pair < 64} {incr pair} {
            lappend q_lo [lindex $q [expr {$base+$pair}]]
            lappend q_hi [lindex $q [expr {$base+64+$pair}]]
        }
    }
}
set k_lo {}
set k_hi {}
for {set token 0} {$token < 128} {incr token} {
    set base [expr {$token*128}]
    for {set pair 0} {$pair < 64} {incr pair} {
        lappend k_lo [lindex $k [expr {$base+$pair}]]
        lappend k_hi [lindex $k [expr {$base+64+$pair}]]
    }
}
set v_beats {}
for {set index 0} {$index < 16384} {incr index 2} {
    lappend v_beats "[lindex $v [expr {$index+1}]][lindex $v $index]"
}

if {[llength $q_lo] != 32768 || [llength $q_hi] != 32768 ||
    [llength $k_lo] != 8192 || [llength $k_hi] != 8192 ||
    [llength $v_beats] != 8192} {
    error "Derived self-test vector length check failed"
}
rk_write_hex_lines [file join $data_dir q_before_lo.hex] $q_lo
rk_write_hex_lines [file join $data_dir q_before_hi.hex] $q_hi
rk_write_hex_lines [file join $data_dir k_before_lo.hex] $k_lo
rk_write_hex_lines [file join $data_dir k_before_hi.hex] $k_hi
rk_write_hex_lines [file join $data_dir v_beats.hex] $v_beats
file copy -force \
    [file join $golden_dir attn_out_per_head_bf16.hex] \
    [file join $data_dir context_expected.hex]
if {[llength [rk_read_hex_lines \
    [file join $data_dir context_expected.hex]]] != 65536} {
    error "Unexpected context golden vector length"
}

set design_files [list \
    [file join $a_root rtl top attention_with_pv_config_guard.sv] \
    [file join $a_root rtl controller attention_group_pv_controller.sv] \
    [file join $a_root rtl adapter pv_tile2_to_tile4_buffer_adapter.sv] \
    [file join $a_root rtl top attention_system_with_rope_pv_top.sv] \
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
    [file join $rope_root rtl rope rope_pair_pipeline.sv] \
    [file join $rope_root rtl rope rope_group_prepare.sv] \
    [file join $rope_root rtl rope rope_qk_group_cache.sv] \
    [file join $rope_root rtl integration rope_group_bridge.sv] \
    [file join $rope_root rtl integration rope_qk_softmax_pv_pipeline_top.sv] \
    [file join $pv_root rtl pv_bf16_to_fp32.v] \
    [file join $pv_root rtl pv_fp32_add_ip.sv] \
    [file join $pv_root rtl pv_fp32_mul_ip.sv] \
    [file join $pv_root rtl pv_fp32_to_bf16.v] \
    [file join $pv_root rtl pv_result_converter.sv] \
    [file join $pv_root rtl pv_systolic_gqa_top.sv] \
    [file join $pv_root rtl pv_systolic_pe.sv] \
    [file join $pv_root rtl pv_systolic_tile.sv] \
    [file join $rk_root rtl attention_pl_selftest_core.sv] \
    [file join $rk_root rtl rk_xczu15eg_f_attention_selftest_top.sv]]

set synthesis_memory_files [list \
    [file join $bc_root rtl softmax exp_lut_q15.mem] \
    [file join $golden_dir sin_bf16.hex] \
    [file join $golden_dir cos_bf16.hex]]
set selftest_memory_files [glob -nocomplain [file join $data_dir *.hex]]
set constraint_file \
    [file join $rk_root constraints rk_xczu15eg_f_pl_clock.xdc]
set simulation_files [list \
    [file join $rk_root tb tb_rk_xczu15eg_f_attention_selftest.sv] \
    [file join $bc_root sim_models floating_point_behavioral.sv]]

rk_require_files [concat $design_files $synthesis_memory_files \
    $selftest_memory_files $simulation_files [list $constraint_file]]
if {[llength $selftest_memory_files] != 6} {
    error "Expected six generated self-test memory files"
}

if {[llength [get_projects -quiet]] > 0} {
    close_project
}
create_project $project_name $project_dir -part $part_name -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property default_lib xil_defaultlib [current_project]

add_files -norecurse $design_files
add_files -norecurse $synthesis_memory_files
add_files -norecurse $selftest_memory_files
add_files -fileset constrs_1 -norecurse $constraint_file
set_property used_in_synthesis false [get_files $constraint_file]
add_files -fileset sim_1 -norecurse $simulation_files
set_property file_type SystemVerilog [get_files -quiet *.sv]

foreach memory_file [concat $synthesis_memory_files $selftest_memory_files] {
    set imported [get_files -quiet [file tail $memory_file]]
    if {[llength $imported] != 1} {
        error "Expected one project file named [file tail $memory_file]"
    }
    set_property file_type {Memory Initialization Files} $imported
}

source [file join $rk_root ip create_rk_pl_selftest_ips.tcl]

# Behavioral simulation uses the repository's handshake-accurate models.
set xci_files [get_files -quiet *.xci]
if {[llength $xci_files] > 0} {
    set_property used_in_simulation false $xci_files
}

set_property top rk_xczu15eg_f_attention_selftest_top \
    [get_filesets sources_1]
set_property top tb_rk_xczu15eg_f_attention_selftest \
    [get_filesets sim_1]
set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt \
    [get_runs synth_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "RK_PROJECT_READY=[file join $project_dir ${project_name}.xpr]"
puts "RK_PART=$part_name"
puts "RK_PS_DDR_MIG_PRESENT=0"
close_project
