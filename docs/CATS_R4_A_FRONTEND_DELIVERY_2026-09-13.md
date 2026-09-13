# CATS-R4 A compute frontend delivery — 2026-09-13

Status: **superseded checkpoint**.  The current closure record is
`docs/CATS_R4_A_FRONTEND_FINAL_EVIDENCE_2026-09-13.md`.

This checkpoint implements the A-owned compute composition boundary described
by `CATS_R4_AC_PARALLEL_PLAN_2026-09-13.md`.  It does not modify B4, the
production weight/V service, output reorder/CDC/DDR, board top, constraints,
or `scripts/source_manifest.tcl`.

## Delivered

- `rtl/core/cluster/cats_r4_compute_frontend.sv`
  - `CLUSTERS` is constrained to 1, 2, or 4.
  - Each cluster owns an independent Q-slab client, 32-lane QK/FP32 engine,
    score formatter, three-slot row assembler, A→B handoff, and abort/owner
    path.
  - Q/K requests, score-store requests, row/score handoff, final release, and
    Q-slab service ports remain per-cluster and flattened only at the module
    boundary.  No testbench service model is instantiated in this RTL.
  - The normal data boundary is the IF_V3 row/score stream.  Slots become
    reusable only after the matching `final_release` transfer; abort/cancel is
    held atomic with the external `row_abort` transfer by the child wrapper.
  - Group routing is static and deterministic: `cluster = group % CLUSTERS`.
    Thus four clusters receive `{0,4}`, `{1,5}`, `{2,6}`, `{3,7}` and execute
    two balanced waves over the eight KV groups.  Group/head mismatches are
    rejected before a child FIFO and counted separately.

- `rtl/core/bc/qk/cats_r4_qk_row_assembler.sv` and
  `rtl/core/bc/qk/cats_r4_qk_a2_row_pipeline.sv`
  - Unsupported IF_V3 numeric modes (`2/3`) are accepted as a transaction
    error, counted once, made sticky, and prevented from admitting score
    traffic or opening a row.  A clear/reset is required before a new mode
    transaction.

- `tb/tb_cats_r4_compute_frontend_routing.sv` and
  `tests/run_cats_r4_compute_frontend_routing_iverilog.ps1`
  - Reproducible Icarus smoke regression for `CLUSTERS=1,2,4`.
  - Exercises all eight legal group assignments and an invalid group/head
    token.  The test stops at `q_slab_need`; it intentionally does not hide a
    Q/K memory model or claim full 33,816,576-MAC system performance.

## Verification

```powershell
tests/run_cats_r4_compute_frontend_routing_iverilog.ps1 `
  -IcarusRoot D:\iverilog\iverilog
```

Observed marker:

```text
[PASS] CATS-R4 compute frontend static 1/2/4-cluster routing regression
```

The existing A-side regressions were also rerun after the mode gate change:

```text
run_cats_r4_qk_slot_lifecycle_iverilog.ps1       PASS
run_cats_r4_qk_row_handoff_wrapper_iverilog.ps1  PASS
run_cats_r4_qk_ab_handoff_iverilog.ps1            PASS
```

The frontend is **not** marked production READY.  C still has to connect the
real B4 and weight/V services, run end-to-end numerical/protocol regressions,
and decide whether the 1/2/4 configurations meet system timing and performance
gates.  The current branch does not contain board measurements.

## Handoff identity

- COMMON_BASE reference: `18cdd2335bfa60927b1fbb466020561681f725eb` (the
  reviewed B-integration checkpoint present in this worktree).
- A-owned changes: this document, the frontend RTL/TB/runner, and the narrow
  unsupported-mode guard in the existing A row pipeline.
- The final commit SHA and regression artifact hashes are recorded when this
  checkpoint is committed.  Any system integration should consume the exact
  commit rather than copying individual files.
