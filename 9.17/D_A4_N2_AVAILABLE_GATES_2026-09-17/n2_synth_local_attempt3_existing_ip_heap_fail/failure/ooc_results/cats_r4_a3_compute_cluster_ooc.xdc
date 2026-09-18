create_clock -name core_clk -period 6.666 [get_ports clk]
set_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports clk]
# This package-less OOC wrapper exposes very wide ready/valid contract buses.
# They have no physical pin locations here.  Timing them creates tens of
# thousands of artificial setup/hold checks and forces destructive delay
# detours.  Preserve every internal 150 MHz clock-to-clock path instead.
set_false_path -from [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_false_path -to [get_ports -filter {DIRECTION == OUT}]