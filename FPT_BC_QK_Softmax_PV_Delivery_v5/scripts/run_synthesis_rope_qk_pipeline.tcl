# Creates a persistent .xpr and runs 100 MHz OOC synthesis of the formal
# one-Group RoPE-aware pipeline. Floating-point QK arithmetic uses the existing
# generated Vivado IP; RoPE uses one shared BF16 pair pipeline with DSP hints.
set origin_dir [file normalize [file join [file dirname [info script]] ..]]
source [file join $origin_dir scripts synthesis_bc_common.tcl]
run_bc_synthesis \
    $origin_dir \
    rope_qk_softmax_pv_pipeline_top \
    vivado_synth_rope_qk_pipeline \
    xc7a100tcsg324-1 \
    rope_qk_pipeline_artix7 \
    0
