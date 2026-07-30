# FPT Responsibility B+C Direct Integration Delivery v5

This package directly connects the completed Responsibility-B frontend to the
Responsibility-C probability buffer and PV input loader:

```text
QK -> Causal Mask -> Row Tile Buffer -> BF16 Softmax
   -> P ping-pong buffer -> P replay/V loader -> PV input vectors
```

The formal one-Group integration top is:

```text
rtl/integration/qk_softmax_pv_pipeline_top.sv
```

The inherited v2 system layer also supplies a reference system top:

```text
rtl/integration/qk_softmax_pv_system_top.sv
```

One system `start` uses `gqa_group_controller.sv` to run Group 0 through 7 and
serves V from synthesizable `bf16_v_cache.sv` instead of a testbench responder.

## Fixed project configuration

```text
SEQ_LEN       = 128
HEAD_DIM      = 128
local Q heads = 4 per Group
GQA Groups    = 8
QK_TILE       = 4
PV_TILE       = 2
data          = BF16, 16 bits per scalar
```

One accepted `group_start` on the formal B+C top processes one GQA Group.  The
reference system wrapper performs all eight launches.  For one Group:

```text
global_q_head = group_id*4 + local_head
global_kv_head = group_id
```

## Formal output boundary

This delivery intentionally stops at the PV input stream:

```systemverilog
p_vec_bf16[31:0]
v_vec_bf16[31:0]
pv_vec_valid
pv_vec_ready
```

`done` means that the final PV input vector was accepted and the final P bank
was released.  It does not mean that a future PV MAC result is available.

## First run in Vivado 2019.2

From the package root:

```tcl
source run_vivado_bc_small.tcl
```

The test runs Group 0 followed by Group 7 and checks the direct B->C probability
stream, P-buffer contents and replay, global V-head/address mapping, V response
data, PV vectors, backpressure stability and all completion counts.

Expected per Group:

```text
256 probabilities
512 V requests
512 PV input vectors
```

Expected final output includes:

```text
PASS: B+C direct integration Group 0
PASS: B+C direct integration Group 7
PASS: complete B+C QK->Softmax->PBuffer->PV-loader integration test
```

The optional full-size run is:

```tcl
source run_vivado_bc_full_optional.tcl
```

It executes Group 6 with 65,536 probabilities and 2,097,152 PV input vectors.
This is substantially longer than the B-only full pipeline.

## Robustness, V-cache and 8-Group run

```tcl
source run_vivado_bc_extended.tcl
```

This self-checks out-of-range Group rejection, a repeated start while busy,
reset during QK/C/stalled-PV activity, actual V-cache data, and one system
start executing Group 0 through Group 7.  To include the original small joint
test as well:

```tcl
source run_vivado_bc_all.tcl
```

## Provisional synthesis and memory inference

Delivery v4 fixed the input-conversion and probability-output paths, passed all
13 behavioral tests, and improved Artix-7 timing from `WNS=-9.695 ns` to
`WNS=-5.643 ns`.  The supplied 50-path report showed that every remaining
worst path was the Softmax score-read -> EXP-decode -> sum-accumulation cone.
Delivery v5 divides that cone into four registered states.  See
`doc/ARTIX7_TIMING_FIX_V5.md`.

First run the fast Row Tile Buffer check introduced in v3:

```tcl
source run_synthesis_row_buffer.tcl
```

It requires the `512x17` payload store to map to exactly one RAMB primitive.
Then run the complete audits:

```tcl
source run_synthesis_bc_pipeline.tcl
source run_synthesis_bc_system.tcl
```

The first command synthesizes the formal external-V shell on temporary
`xc7a35t`.  The second includes the 2,097,152-bit V-cache and uses temporary
`xc7a100t`, because the small part lacks sufficient BRAM.  Both are 100 MHz
OOC audits and fail on latches, MDRV-1, or missing required BRAM inference;
they also report EXP-LUT logic usage and setup slack.

The pipeline synthesis also generates `post_synth_critical_paths.rpt` with up
to 50 paths.  Delivery v5 must be rerun in Vivado before 100 MHz is claimed.

## Files used by final integration

Responsibility B:

```text
rtl/qk/*
rtl/adapter/*
rtl/softmax/*
rtl/integration/qk_softmax_frontend.sv
rtl/integration/qk_softmax_pipeline_top.sv
```

Responsibility C:

```text
rtl/backend/softmax_output_buffer.sv
rtl/backend/pv_input_loader.sv
rtl/backend/softmax_pv_backend.sv
```

Joint integration:

```text
rtl/integration/qk_softmax_pv_pipeline_top.sv
tb/tb_qk_softmax_pv_pipeline.sv
```

System/robustness additions:

```text
rtl/backend/bf16_v_cache.sv
rtl/integration/gqa_group_controller.sv
rtl/integration/qk_softmax_pv_system_top.sv
tb/tb_bc_robustness.sv
tb/tb_qk_softmax_pv_all_groups.sv
```

The old C-side `b_to_c_control` and `softmax_metadata_tracker` are intentionally
not used: they consume pre-Softmax `row_*` data and would duplicate the Softmax
already owned by B.

See `doc/BC_INTERFACE_CONTRACT.md` and `doc/A_HANDOFF_BC.md` for the complete
port and completion contract.

## Tool boundary

Vivado 2019.2 can run the behavioral regressions and provisional Artix-7
structural checks.  Final RAM inference, utilization, timing, IP regeneration,
implementation and bitstream generation must be repeated in a Vivado release
that supports the Kria K26/KV260 target.
