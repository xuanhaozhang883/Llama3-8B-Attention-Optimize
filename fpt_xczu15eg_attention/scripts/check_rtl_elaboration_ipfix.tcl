# Compatibility entry point retained for older instructions.  The global-BD
# fix is now part of the canonical check_rtl_elaboration.tcl.
set script_dir [file normalize [file dirname [info script]]]
puts "INFO: check_rtl_elaboration_ipfix.tcl is a compatibility alias."
source [file join $script_dir check_rtl_elaboration.tcl]
