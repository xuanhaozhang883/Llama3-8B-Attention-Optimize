set all_parts [get_parts]
set target_parts [get_parts -quiet *xczu15eg*]
puts "VIVADO_ALL_PART_COUNT=[llength $all_parts]"
puts "VIVADO_XCZU15EG_COUNT=[llength $target_parts]"
foreach part $target_parts { puts "VIVADO_XCZU15EG_PART=$part" }
set families [lsort -unique [get_property FAMILY $all_parts]]
foreach family $families { puts "VIVADO_INSTALLED_FAMILY=$family" }
exit
