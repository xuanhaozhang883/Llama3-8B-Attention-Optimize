# CATS-R4 A abort/cancel audit — 2026-09-13

Disposition: **ACCEPTED for A-side consumption**.

The窄修复 from commit `a26cdc5ee64e12884fc9e529213ba6630202356b` was reviewed
against the frozen IF_V3 ownership rules.  The change is limited to
`cats_r4_qk_slot_lifecycle.sv`, `cats_r4_qk_row_handoff_wrapper.sv`, and their
directed testbench updates.

Evidence rerun on the current worktree:

```text
tests/run_cats_r4_qk_slot_lifecycle_iverilog.ps1
tests/run_cats_r4_qk_row_handoff_wrapper_iverilog.ps1
tests/run_cats_r4_qk_ab_handoff_iverilog.ps1
```

All three regressions pass.  The tests cover A-owner abort returning a slot to
FREE, abort priority over a same-slot final-score handoff, wrong-token release
rejection, and full 4,096-row/264,192-causal-score A→B transfer with reset and
random backpressure.  No XSim/board claim is made here.

The accepted behavior is:

1. an A-owner abort and the outward `row_abort` transfer commit atomically;
2. abort wins over a competing handoff for the same slot;
3. a B-owned slot remains unavailable until the exact full-token
   `final_release`; and
4. rejected release/abort assertions are counted once per assertion and set a
   sticky owner error.

This audit does not change the public IF_V3 ports and does not authorize
production manifest or board integration.
