# Export a hardware platform from a foreground implementation checkpoint.
# Usage: vivado -mode batch -source export_foreground_xsa.tcl -tclargs \
#          <project.xpr> <post_route.dcp> <output.xsa>

if {$argc != 3} {
    error "Usage: export_foreground_xsa.tcl <project.xpr> <post_route.dcp> <output.xsa>"
}

set project_file [file normalize [lindex $argv 0]]
set route_dcp [file normalize [lindex $argv 1]]
set xsa_file [file normalize [lindex $argv 2]]

foreach required [list $project_file $route_dcp] {
    if {![file isfile $required]} {
        error "Missing required input: $required"
    }
}

open_project $project_file
open_checkpoint $route_dcp
file mkdir [file dirname $xsa_file]
write_hw_platform -fixed -force $xsa_file

puts "FOREGROUND_XSA_EXPORT=PASS"
puts "PROJECT=$project_file"
puts "ROUTE_DCP=$route_dcp"
puts "XSA=$xsa_file"

close_design
close_project
exit
