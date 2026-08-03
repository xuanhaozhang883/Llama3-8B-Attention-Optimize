set fpt_ai_wrapper_dir [file normalize [file dirname [info script]]]
source [file join $fpt_ai_wrapper_dir _bootstrap.tcl]
::fpt_ai_tcl::run sim_online

