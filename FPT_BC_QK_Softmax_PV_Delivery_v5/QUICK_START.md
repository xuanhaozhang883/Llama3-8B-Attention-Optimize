# Quick Start — B+C v5

## B+C joint regression

```tcl
cd C:/short/path/FPT_BC_QK_Softmax_PV_Delivery_v5
source run_vivado_bc_small.tcl
```

The path should be kept short because Vivado 2019.2 on Windows has legacy path
length limits.

## Optional full configuration

```tcl
source run_vivado_bc_full_optional.tcl
```

## Existing B-only regressions

```tcl
source run_vivado_v4_quick.tcl
source run_vivado_v4_all.tcl
source run_vivado_v4_full_pipeline_optional.tcl
```

The joint small regression is the required first B+C test.  The full joint run
is intentionally optional because `PV_TILE=2` creates 2,097,152 vectors for one
full Group.

## Robustness, V-cache and 8-Group regression

```tcl
source run_vivado_bc_extended.tcl
```

This runs three self-checking tops:

1. illegal Group ID rejection using the parameterized 7-Group guard;
2. busy-start rejection plus reset during QK, C activity and a stalled PV beat;
3. Group 0 through 7 under the reference controller using the synthesizable
   V-cache rather than a testbench V responder.

To rerun both the original small regression and all robustness tests:

```tcl
source run_vivado_bc_all.tcl
```

## Provisional Vivado 2019.2 synthesis

Fast Row Tile Buffer BRAM inference check:

```tcl
source run_synthesis_row_buffer.tcl
```

Do not continue until it prints:

```text
PASS: Row Tile Buffer inferred exactly one block-RAM primitive
```

Formal B+C shell with external V memory, temporary `xc7a35t` target:

```tcl
source run_synthesis_bc_pipeline.tcl
```

Controller+B+C+full V-cache, temporary `xc7a100t` target:

```tcl
source run_synthesis_bc_system.tcl
```

The larger part is intentional: the full V-cache stores 2,097,152 bits before
BRAM overhead and cannot fit in the small `xc7a35t`.  Both scripts run OOC
synthesis, audit latch and multiple-driver issues, require Row Tile/P/V buffers
to infer BRAM, count EXP-LUT logic and report the 100 MHz synthesis slack.  The
pipeline run also writes `post_synth_critical_paths.rpt` for up to 50 paths.
