# Provisional 100 MHz Artix-7 OOC synthesis of controller+B+C+full V-cache.
# xc7a100t is used because the full 8*128*128 BF16 V-cache alone exceeds the
# BRAM capacity of the small xc7a35t simulation target.  This remains a
# structural/reference result, not KV260 signoff.
set origin_dir [file normalize [file join [file dirname [info script]] ..]]
source [file join $origin_dir scripts synthesis_bc_common.tcl]
run_bc_synthesis \
    $origin_dir \
    qk_softmax_pv_system_top \
    vivado_synth_bc_system \
    xc7a100tcsg324-1 \
    bc_system_artix7 \
    1
