create_clock -name core_clk -period 6.666 [get_ports clk]
set_property HD.CLK_SRC BUFGCE_X0Y0 [get_ports clk]
# This is a B-owned contract wrapper, not a placed board top.  Its wide
# ready/valid buses have no package pin locations in OOC.  Timing every one of
# those pins creates tens of thousands of tight setup/hold checks and can make
# Vivado's router exhaust host memory.  Keep the 150 MHz internal clock-to-clock
# paths timed, and explicitly exclude the unconstrained contract I/O from the
# OOC timing graph.
set_false_path -from [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_false_path -to [get_ports -filter {DIRECTION == OUT}]