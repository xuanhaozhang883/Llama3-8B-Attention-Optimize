# 100 MHz clock for synthesis/timing experiments.
create_clock -name pv_clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]
