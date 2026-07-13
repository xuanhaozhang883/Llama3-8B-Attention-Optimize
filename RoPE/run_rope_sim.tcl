# Run from either a Vivado Tcl Console or a Vitis/Vivado terminal.
# The working directory is deliberately set to repository root so all
# repository-relative $readmemh/$fopen paths in the testbench are reproducible.

set rope_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $rope_dir ..]]
set build_dir [file join $repo_root build rope_xsim]
file mkdir $build_dir
cd $build_dir

puts "INFO: repository root = $repo_root"
puts "INFO: run directory   = $build_dir"

xvlog -sv [file join $rope_dir tb_rope_qk_file.sv]
xvlog [file join $rope_dir bf16_mul.v] [file join $rope_dir bf16_addsub.v] [file join $rope_dir rope_engine.v]
xelab tb_rope_qk_file -s rope_tb -debug typical
xsim rope_tb -runall \
    -testplusarg ROPE_Q_INPUT=[file join $rope_dir data q_before_rope_bf16.hex] \
    -testplusarg ROPE_K_INPUT=[file join $rope_dir data k_before_rope_bf16.hex] \
    -testplusarg ROPE_SIN=[file join $rope_dir data sin_bf16.hex] \
    -testplusarg ROPE_COS=[file join $rope_dir data cos_bf16.hex] \
    -testplusarg ROPE_Q_GOLDEN=[file join $rope_dir data q_after_rope_golden_bf16.hex] \
    -testplusarg ROPE_K_GOLDEN=[file join $rope_dir data k_after_rope_golden_bf16.hex] \
    -testplusarg ROPE_Q_OUTPUT=[file join $rope_dir results q_rope_verilog.hex] \
    -testplusarg ROPE_K_OUTPUT=[file join $rope_dir results k_rope_verilog.hex]
