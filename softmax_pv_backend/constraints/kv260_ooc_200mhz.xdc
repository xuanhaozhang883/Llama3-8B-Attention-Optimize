# Out-of-context timing target for the fixed KV260 backend wrapper.
# The final Block Design must use its generated kernel clock constraint.
create_clock -name kernel_clk -period 5.000 [get_ports clk]
