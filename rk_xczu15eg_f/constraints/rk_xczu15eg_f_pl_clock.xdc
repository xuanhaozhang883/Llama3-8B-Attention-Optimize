# RK-XCZU15EG-F V1.0 PL system clock.
# Sources:
# - XCZU15EG_CORE V1.0 schematic, page 5: PL_CLK0_P/N on Bank 64.
# - RK-XCZU15EG-F V1.0 manual, page 9: 200 MHz differential PL clock.
# - RK_15EG_FPGA tutorial, page 18: PL_CLK0_P package pin AL8.
# The core schematic also resolves the complementary N pin as AL7 and shows
# an external 100-ohm termination resistor, so internal DIFF_TERM is disabled.

set_property PACKAGE_PIN AL8 [get_ports pl_clk0_p]
set_property PACKAGE_PIN AL7 [get_ports pl_clk0_n]
set_property IOSTANDARD DIFF_SSTL12 [get_ports {pl_clk0_p pl_clk0_n}]

# rk_pl_clk_wiz is configured with PRIM_IN_FREQ=200.000 MHz. Its generated
# XDC owns the single 5.000 ns input-clock definition; duplicating create_clock
# here would override that clock and produce Constraints 18-1056.
#
# No internal differential termination property is applied. The schematic
# shows external 100-ohm resistor R22, and DIFF_SSTL12 rejects DIFF_TERM_ADV
# (DRC PORTPROP-6).
