# 100 MHz input clock constraint for QK synthesis experiments
create_clock -name qk_clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]
