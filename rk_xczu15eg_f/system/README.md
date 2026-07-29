# RK-XCZU15EG-F PS/DMA/Attention system

Target board: RK-XCZU15EG-F V1.0

Exact device: `xczu15eg-ffvb1156-2-i`

Tool version: Vivado/Vitis 2025.2

This directory contains the reproducible GUI-project generators, RTL and
A53 standalone software for:

- PS DDR and 128-bit AXI DMA loopback;
- vendor PL DDR self-test;
- PS DDR → DMA → single-GQA Attention → DMA → PS DDR;
- the production `RoPE → QK → Scale/Mask → Softmax → PV` path;
- kernel, DMA and application-level latency counters.

No behavioral simulation is launched by the system build scripts.
`SOFTWARE_PASS` means the tools completed; physical tests remain
`HARDWARE_PENDING` until captured on the exact board.

## Vivado GUI projects

```text
system/vx/ps_dma_loopback/rk_ps_dma_loopback.xpr
system/vx/pl_ddr/rk_pl_ddr.xpr
system/vx/ps_attention/rk_ps_attention_single_gqa.xpr
```

The `system/vx` projects are generated files. Their sources of truth are:

```text
system/bd/create_ps_dma_loopback_project.tcl
system/pl_ddr/create_pl_ddr_project.tcl
system/bd/create_ps_attention_project.tcl
system/vendor/ps/apply_ps_config.tcl
```

The PS adapter is derived from the exact vendor project. The PL DDR flow uses
the vendor XCI/XDC cache prepared by `scripts/prepare_vendor_assets.ps1`.
Vendor archives remain local because redistribution permission is unknown.

## Non-simulation build

```powershell
.\rk_xczu15eg_f\system\scripts\build_system_project.ps1 `
  -Project ps_dma_loopback -BuildMode bitstream -Jobs 4

.\rk_xczu15eg_f\system\scripts\build_system_project.ps1 `
  -Project ps_attention -BuildMode bitstream -Jobs 4
```

Outputs are written below:

```text
system/generated/vivado_build/<project>/
```

See `docs/VIVADO_NON_SIM_BUILD_ZH.md` for the GUI/Tcl equivalent.

## Vitis GUI workspaces

Windows path depth in a Vitis BSP can exceed `MAX_PATH`, so generated
workspaces default to:

```text
D:\Vitis\ws\rkd
D:\Vitis\ws\rka
```

The very short names are intentional.  The Attention BSP cannot generate
`translation_table.S.obj.d` reliably under the longer repository-style
workspace path on Windows.

Create or rebuild them with:

```powershell
.\rk_xczu15eg_f\system\scripts\create_vitis_workspace.ps1 `
  -Profile dma_loopback -Recreate

.\rk_xczu15eg_f\system\scripts\create_vitis_workspace.ps1 `
  -Profile attention_single_gqa -Recreate
```

`software/static_check` is for syntax-only stubs. Never add it to a real
Vitis include path; generated XSA/BSP headers are authoritative.

## Data and memory implementation

The fixed single-GQA frame is:

```text
Q[4][128][128], K[1][128][128], V[1][128][128], BF16
```

Q/K/V AXI beats are stored in explicit XPM simple-dual-port block RAM.
`scripts/check_qkv_bram.tcl` proves that the bridge contains BRAM and no
LUTRAM primitives. Protocol and registers are documented in
`docs/DATA_PROTOCOL.md`.

The default weak software provider uses placeholder zeros. Competition
correctness requires strong real-data implementations of the APIs in
`software/common/attention_data_provider.h`.

## Hardware acceptance order

1. PS DDR cache-on/cache-off patterns.
2. DMA loopback at all eight configured lengths.
3. PL DDR `init_calib_complete == 1` and `error == 0`, then stress tests.
4. Single-GQA transaction with real BF16 Q/K/V and Golden Context.
5. Record kernel, DMA and full-application latency separately.
6. Expand from one GQA group to all eight only after repeatable correctness.

The Chinese GUI handoff is in `README_GUI_ZH.md`.
