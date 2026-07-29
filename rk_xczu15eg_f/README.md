# RK-XCZU15EG-F V1.0 PL-only Attention Self-test

This directory contains the RK-XCZU15EG-F V1.0 migration stages that are
independent from the retained `kv260/` regression baseline.

The current stage is intentionally limited to:

```text
200 MHz differential PL clock
-> 100 MHz generated clock
-> one-GQA-group on-chip golden self-test
-> VIO / ILA status
```

The current stage does not instantiate Zynq PS, PS DDR, PL DDR, MIG, DMA,
DataMover, Linux, Vitis software, or SD/eMMC boot logic.

## Target

```text
Board:       RK-XCZU15EG-F V1.0
Device:      XCZU15EG-2FFVB1156I
Vivado part: xczu15eg-ffvb1156-2-i
Tool:        Vivado 2025.2
```

## Directory roles

```text
constraints/  Board-level PL-only XDC
rtl/          Board wrapper and board-independent self-test core
tb/           Behavioral verification
ip/           Rebuild policy for target-device IP
scripts/      Terminal entry points and result helpers
docs/         Board facts, blockers, and GUI/hardware instructions
reports/      Phase status, summaries, and generated reports
artifacts/    Generated bitstream/debug probes; publish via Release
```

## What the design executes

The checked-in golden slice is one Llama 3 GQA group:

- four Q heads
- one shared K/V head
- sequence length 128
- head dimension 128
- BF16 inputs and golden context output

At configuration/reset release, the PL loads the V cache, reads Q/K from
inferred on-chip ROM, executes the production
RoPE -> QK -> causal mask -> Softmax -> PV path, and compares all 65,536
context words against the golden result with absolute tolerance 0.0001.
Restart runs the same test again without reprogramming the FPGA.

## Primary GUI entry

After the project-creation step has run, open this file in Vivado:

```text
rk_xczu15eg_f/vx/rk_pl_selftest.xpr
```

The absolute path in this worktree is:

```text
<repo_root>\rk_xczu15eg_f\vx\rk_pl_selftest.xpr
```

The XPR is generated and intentionally excluded from Git. The Tcl source is
the reproducible definition of the project. The short `vx` directory is
intentional: on Windows, Vivado debug-hub insertion fails if its temporary
implementation path exceeds 146 characters.

## One-command rebuild

From the repository root in a VS Code PowerShell terminal:

```powershell
$env:VIVADO_BIN = "D:\Vitis\2025.2\Vivado\bin\vivado.bat"
.\rk_xczu15eg_f\scripts\run_stage1.ps1 -Mode all
```

The equivalent single Tcl entry point is:

```powershell
& $env:VIVADO_BIN -mode batch -source `
  .\rk_xczu15eg_f\build_rk_xczu15eg_pl_selftest.tcl -tclargs all
```

The stages are independently restartable:

```powershell
.\rk_xczu15eg_f\scripts\run_stage1.ps1 -Mode project
.\rk_xczu15eg_f\scripts\run_stage1.ps1 -Mode sim
.\rk_xczu15eg_f\scripts\run_stage1.ps1 -Mode bitstream
```

Run `project` after deleting or moving generated project files, after changing
the target IP configuration, or when opening the repository on another
computer. Run `sim` after RTL/testbench changes. Run `bitstream` only after
simulation passes.

## Vivado GUI verification

1. Double-click the generated XPR above.
2. In **Project Manager -> Settings -> General**, confirm part
   `xczu15eg-ffvb1156-2-i` and top
   `rk_xczu15eg_f_attention_selftest_top`.
3. In **Sources**, confirm there is no Zynq UltraScale+ MPSoC block design,
   MIG, AXI DMA, or DataMover.
4. Select **Run Simulation -> Run Behavioral Simulation**. The simulation top
   is `tb_rk_xczu15eg_f_attention_selftest`; it executes two complete runs and
   prints a final `[PASS]`.
5. Select **Run Synthesis**, then **Run Implementation**, then
   **Generate Bitstream**. The automated script performs the same stages and
   also emits the required reports.
6. Use **Open Implemented Design -> Report Timing Summary** and verify setup
   and hold timing. Do not infer timing closure from bitstream existence alone.

For programming and VIO/ILA operation, follow
`docs/HARDWARE_MANAGER_VIO_GUIDE.md`.

## Result locations

| Result | Location |
|---|---|
| Behavioral status/log | `reports/10_rk_pl_selftest_sim/` |
| Post-synthesis reports | `reports/11_rk_pl_selftest_synth/` |
| Post-route/bitstream reports | `reports/12_rk_pl_selftest_bitstream/` |
| Hardware-validation record | `reports/13_rk_pl_selftest_hardware/` |
| Stable bitstream | `artifacts/rk_xczu15eg_f_pl_selftest.bit` |
| Matching debug probes | `artifacts/rk_xczu15eg_f_pl_selftest.ltx` |

`BOARD_FACTS.md` states exactly which board facts are confirmed.
`BLOCKERS.md` separates cleared gates from deferred and hardware-only work.

## Executed Stage 1 result

The local Vivado 2025.2 run completed behavioral simulation, synthesis,
implementation, sign-off reports, and `write_bitstream` for
`xczu15eg-ffvb1156-2-i`.

| Check | Result |
|---|---:|
| Golden context comparisons | 65,536 per run |
| Restart regression | PASS, two complete runs |
| Mismatches | 0 |
| Production cycles at 100 MHz | 16,170,681 |
| Post-route WNS | +2.221 ns |
| Post-route WHS | +0.011 ns |
| Routing errors | 0 |
| Bitstream precondition DRC errors | 0 |

Physical board programming has not been executed and remains explicitly
`HARDWARE VALIDATION PENDING`.
