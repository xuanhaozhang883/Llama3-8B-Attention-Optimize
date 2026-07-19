create_clock -name clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]

# Provisional Artix-7 OOC clock location.  Without this property Vivado 2019.2
# cannot estimate clock insertion delay/skew for the module boundary.  The
# final KV260 system constraint must use the actual top-level clock source.
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]
