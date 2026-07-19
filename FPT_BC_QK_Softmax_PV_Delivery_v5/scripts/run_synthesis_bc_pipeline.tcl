# Provisional 100 MHz Artix-7 OOC synthesis of the formal B+C shell.
# V storage remains external in this top.  Use run_synthesis_bc_system.tcl for
# the larger wrapper that includes the complete 8-head V-cache.
set origin_dir [file normalize [file join [file dirname [info script]] ..]]
source [file join $origin_dir scripts synthesis_bc_common.tcl]
run_bc_synthesis \
    $origin_dir \
    qk_softmax_pv_pipeline_top \
    vivado_synth_bc_pipeline \
    xc7a35tcpg236-1 \
    bc_pipeline_artix7 \
    0
