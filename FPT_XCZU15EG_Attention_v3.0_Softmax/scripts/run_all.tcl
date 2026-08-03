set script_dir [file normalize [file dirname [info script]]]
source [file join $script_dir create_attention_board_project.tcl]
set argv [list 8]
source [file join $script_dir build_attention_board_all.tcl]
