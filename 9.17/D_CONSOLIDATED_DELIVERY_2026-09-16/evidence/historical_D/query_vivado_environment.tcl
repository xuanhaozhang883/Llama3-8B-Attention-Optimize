puts "VIVADO_PWD=[pwd]"
puts "VIVADO_HOME_EXISTS=[info exists ::env(HOME)]"
if {[info exists ::env(HOME)]} { puts "VIVADO_HOME=$::env(HOME)" }
puts "VIVADO_USERPROFILE_EXISTS=[info exists ::env(USERPROFILE)]"
if {[info exists ::env(USERPROFILE)]} { puts "VIVADO_USERPROFILE=$::env(USERPROFILE)" }
puts "VIVADO_TILDE=[file normalize ~]"
puts "VIVADO_TMP=[file normalize [file tempdir]]"
exit
