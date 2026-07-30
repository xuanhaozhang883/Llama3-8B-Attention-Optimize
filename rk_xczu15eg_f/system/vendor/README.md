# RK-XCZU15EG-F vendor configuration gate

This directory intentionally does not contain guessed PS or PL-DDR settings.
The board vendor must provide machine-importable files for PCB V1.0.

## PS configuration

Place the verified adapter at:

```text
system/vendor/ps/apply_ps_config.tcl
```

It must define:

```tcl
proc rk_apply_ps_config {ps_cell} {
    # Apply the vendor PS preset/configuration to $ps_cell.
}
```

After applying the board's PS DDR, MIO and boot configuration, it must enable:

- `M_AXI_HPM0_FPD` for PS control of PL AXI-Lite slaves;
- `S_AXI_HPC0_FPD` for DMA access to PS DDR;
- `pl_clk0` at 100 MHz for the bring-up system;
- `pl_resetn0`;
- the matching `maxihpm0_fpd_aclk` and `saxihpc0_fpd_aclk` pins.

Do not use the KV260 board preset or a ZCU102/AXU15EG preset.

## PL DDR configuration

Provide:

```text
system/vendor/pl_ddr/<verified MIG XCI>
system/vendor/pl_ddr/<RK V1.0 Master XDC>
```

The project must match the fitted `2 × MT40A512M16LY-062E`, 32-bit, 2 GB
PL DDR on Banks 64/65 and the board's 200 MHz differential reference clock.
The tutorial's `MT40A512M16HA-083E` screenshot is not an accepted substitute.

Vendor files may only be committed or redistributed after their license and
publication permission have been checked.
