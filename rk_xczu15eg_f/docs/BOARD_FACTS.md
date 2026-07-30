# RK-XCZU15EG-F V1.0 board facts used by Stage 1

This file separates facts actually used by the PL-only self-test from facts
that are intentionally deferred. It is not a substitute for the vendor
schematic or master XDC.

## Confirmed and used

| Item | Confirmed value | Evidence | Stage 1 use |
|---|---|---|---|
| Device | `xczu15eg-ffvb1156-2-i` | Board model and installed Vivado 2025.2 device database | Project `-part` |
| PL clock name | `PL_CLK0_P/N` | Core schematic page 5; board manual page 9 | Only external top-level interface |
| PL clock frequency | 200 MHz differential | Board manual page 9; tutorial page 33 | Clock Wizard `PRIM_IN_FREQ=200.000`, generated XDC period 5.000 ns |
| Clock P pin | AL8, Bank 64 | Core schematic page 5; tutorial page 18 | XDC `PACKAGE_PIN` |
| Clock N pin | AL7, Bank 64 | Core schematic page 5 | XDC `PACKAGE_PIN` |
| Clock-capable classification | AL8 `IO_L12P_T1U_N10_GC_64`, AL7 `IO_L12N_T1U_N11_GC_64`; both `IS_GLOBAL_CLK=1` | Vivado 2025.2 package-pin database, reproduced by `scripts/query_rk_clock_pins.tcl` | Confirms legal global-clock input |
| I/O standard | `DIFF_SSTL12` | Tutorial page 18 shows the same name with a spacing/typographic error; Vivado accepts `DIFF_SSTL12` | XDC |
| Differential termination | External 100 ohm resistor R22 | Core schematic page 5 | No internal termination property; `DIFF_SSTL12` rejects `DIFF_TERM_ADV` |
| Fabric clock | 100 MHz | Tutorial page 35 clock-wizard example; existing attention timing target | Clock Wizard output |

The top level has only `pl_clk0_p` and `pl_clk0_n`. Reset is generated inside
the PL after the clock wizard locks. Restart and status observation use VIO,
and run-time capture uses ILA. No uncertain LED, button, PS, DDR, or FMC pin is
constrained.

UltraScale+ package data uses the `GC` designation for these pins, not the
7-series `MRCC`/`SRCC` naming. Therefore the precise database-backed
classification is global-clock-capable (`IS_GLOBAL_CLK=1`).

## Confirmed but intentionally unused in Stage 1

| Item | Board fact | Reason deferred |
|---|---|---|
| PS DDR | Four MT40A512M16LY-062E devices, 64-bit total, 4 GB | PS/DDR/Linux is outside Stage 1 |
| PL DDR | Two MT40A512M16LY-062E devices, 32-bit total, 2 GB | MIG/DDR is outside Stage 1 |
| Advertised DDR rate | 2400 Mb/s | No memory controller is instantiated |
| PL DDR banks | Banks 64 and 65 | No DDR pins are constrained |

## Known DDR documentation inconsistency

The fitted memory part in the schematic/manual is `MT40A512M16LY-062E`.
The tutorial's MIG example on page 88 selects `MT40A512M16HA-083E`,
833 ps / 1200 MHz, 32-bit, with a 200 MHz reference. The Micron datasheet
identifies `-062E` and `-083E` as different speed grades. Therefore that
tutorial selection must not be copied into a later MIG design without the
vendor master XDC, board-specific preset, and documented memory validation.

## Not yet confirmed and not required for Stage 1

- Vendor master XDC for every board peripheral
- PS preset and boot-mode details
- PL DDR MIG preset and complete pinout
- FMC mezzanine pin assignments
- User LED/button polarity

These unknowns do not block the clock-only PL golden self-test.
