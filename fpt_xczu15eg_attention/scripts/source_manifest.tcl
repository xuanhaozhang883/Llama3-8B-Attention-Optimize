set board_root [file normalize [file join [file dirname [info script]] ..]]

proc collect_hdl_files {dir_name} {
    set result {}
    foreach item [glob -nocomplain -directory $dir_name *] {
        if {[file isdirectory $item]} {
            set result [concat $result [collect_hdl_files $item]]
        } elseif {[regexp -nocase {\.(v|sv)$} $item]} {
            lappend result [file normalize $item]
        }
    }
    return $result
}

set board_rtl [collect_hdl_files [file join $board_root rtl board]]
set core_rtl  [collect_hdl_files [file join $board_root rtl core]]
set design_files [concat $board_rtl $core_rtl]
set memory_files [list \
    [file join $board_root mem exp_lut_q15.mem] \
    [file join $board_root mem sin_bf16.hex] \
    [file join $board_root mem cos_bf16.hex]]
set constraint_files [list [file join $board_root scripts attention_board.xdc]]

proc require_files {items} {
    foreach f $items {
        if {![file isfile $f]} { error "Missing required file: $f" }
    }
}
require_files $design_files
require_files $memory_files
require_files $constraint_files
