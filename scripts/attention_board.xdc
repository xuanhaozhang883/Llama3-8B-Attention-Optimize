# Vendor-verified error LED/output pin from the PL<->PS DDR example.
set_property IOSTANDARD LVCMOS33 [get_ports error]
set_property PACKAGE_PIN D16 [get_ports error]

# The engine clock is PS pl_clk0 = approximately 150 MHz. The clock is generated inside the
# Zynq MPSoC block and normally carries its generated-clock constraint.
# This extra constraint is intentionally omitted to avoid a duplicate clock.

