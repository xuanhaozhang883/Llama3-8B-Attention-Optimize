# RK-XCZU15EG-F execution blockers and gates

## Cleared build gates

| Gate | State | Evidence |
|---|---|---|
| Isolated worktree | Cleared | `<repo_root>` |
| Active migration branch | Cleared | `rk-xczu15eg-final-system` |
| Frozen Stage 1 baseline | Cleared | `rk-xczu15eg-pl-selftest` |
| Target device | Cleared | Vivado 2025.2 resolves `xczu15eg-ffvb1156-2-i` |
| Built-in IP | Cleared | Floating Point, Clocking Wizard, VIO and ILA are installed |
| Stage 1 implementation | Cleared | Bitstream generated with positive setup/hold slack |
| Stage 1 physical validation | Pending | Requires the physical board, JTAG and VIO/ILA observation |

The completed Stage 1 implementation had no blocking DRC or routing error.
Remaining performance and debug-hub advisories are recorded in
`reports/12_rk_pl_selftest_bitstream/summary.md`.

## Vivado Tcl Store warning

Vivado 2025.2 reports that the user Tcl Store catalog under
`%APPDATA%\Xilinx\Vivado\2025.2\XilinxTclStore`
is corrupted and falls back to the installation area. It also reports a
missing `::tclapp::support::appinit 1.2` while updating the catalog.

The current flow uses built-in Xilinx IP and does not depend on Tcl Store
apps. This warning is recorded instead of resetting unrelated user state.

## Stage 2/3 external-asset audit

Audited on 2026-07-26 under the repository `references` directory. It
contains five board/device PDFs and two planning Markdown files, but no
machine-importable vendor project assets.

The WeChat archive `XCZU15EG参考手册.zip` was also inspected. It contains the
same five PDFs only; it does not contain `3_source_code`, XDC, XCI, Tcl, XPR,
XSA or a PS preset.

### Stage 2 PL DDR: BLOCKED

Required and not found:

- RK-XCZU15EG-F V1.0 Master XDC;
- verified PL DDR4 MIG `.xci` or equivalent Tcl;
- vendor Vivado reference project;
- board-version-matched MIG configuration notes.

The board memory is documented as `2 × MT40A512M16LY-062E`, 32-bit, 2 GB on
Banks 64/65 with a 200 MHz differential reference clock. The tutorial example
uses a different `MT40A512M16HA-083E` selection and must not be copied.

A fail-fast PL-DDR project gate and bare-metal memory-test source are present.
They do not establish calibration or hardware correctness.

### Stage 3 PS/PS DDR: BLOCKED

Required and not found:

- vendor Zynq UltraScale+ PS preset or reference project;
- verified PS DDR and MIO configuration;
- UART/JTAG/SD/eMMC/QSPI/boot-mode configuration;
- XSA/BSP, FSBL, PMUFW, BIF/device-tree or equivalent source package.

The PS-DDR, DMA and Attention Block Design generators fail before project
creation until a verified `rk_apply_ps_config` adapter is supplied. PDFs are
useful for cross-checking but are not sufficient to claim safe PS/DDR
configuration.

## Safe work completed while blocked

- 128-bit AXI4-Stream DMA loopback RTL;
- fixed-layout Q/K/V ingress and Context egress RTL;
- production single-GQA accelerator wrapper and AXI-Lite control registers;
- PS-DDR/DMA and PS-DDR/DMA/Attention Block Design generators;
- PS-DDR, PL-DDR, DMA loopback and single-GQA bare-metal sources;
- A53 software syntax checks and RTL hierarchy compile/elaboration.

No new behavioral simulation was run for this foundation round. No PS/PL-DDR
hardware claim is made.
