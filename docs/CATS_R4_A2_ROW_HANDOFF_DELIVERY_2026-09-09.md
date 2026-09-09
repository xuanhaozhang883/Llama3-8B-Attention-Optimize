# CATS-R4 A2 row handoff delivery — 2026-09-09

Status: **A2 implementation complete with simulation memory/B-consumer stubs; A2 READY sign-off blocked**.

This delivery stays on `agent/cats-r4-a2-row-handoff`. It does not modify the
production manifest, board top, B numeric internals, or C AXI/DMA implementation.

## Implemented A-side chain

- `cats_r4_qk_32lane_scheduler.sv`: tagged Q/K/MAC scheduling, causal masks,
  variable response latency, and `start_row_offset`.
- `cats_r4_qk_32lane_engine.sv`: scheduler, real FP32 service boundary, and
  backpressured score FIFO.
- `cats_r4_qk_q_slab_client.sv`: Q-slab need/ready/retire lifecycle. Each
  16-row window is split into offsets `0,3,6,9,12,15` and row counts
  `3,3,3,3,3,1`; four key-block jobs are issued per sub-batch.
- `cats_r4_qk_score_formatter.sv`: `1/sqrt(128)` FP32 scaling and BF16 RNE.
- `cats_r4_qk_a2_row_pipeline.sv`: raw engine scores through formatter,
  three-slot row assembly/max, physical score-store writes, frozen A-to-B
  row/score streams, aborts, ownership handoff, and final-release-only reuse.
- `cats_r4_qk_row_assembler.sv`, `cats_r4_qk_ab_handoff.sv`,
  `cats_r4_qk_slot_lifecycle.sv`, and `cats_r4_qk_row_abort_arbiter.sv`:
  row completion, strict key order/last, error delivery, and slot lifecycle.

The three physical slots are safe because at most three rows are active in a
sub-batch. A later sub-batch cannot overwrite a slot while B owns it: the raw
score path backpressures until `final_release` returns that exact token to FREE.

## Frozen A-to-B interface

Row channel (`valid/ready`):

`epoch[15:0], group[2:0], global_q_head[4:0], row[6:0], slot_id[1:0], numeric_mode[1:0], row_max_bf16[15:0]`

Score channel (`valid/ready`):

the same token plus `key[6:0], score_bf16[15:0], last`.

Properties proven by the regressions:

- each row covers every legal causal key `0..row` exactly once;
- score keys are strictly increasing and `last` is asserted only at `key=row`;
- score and row max are computed after the score formatter's BF16 RNE boundary;
- payloads remain stable while `valid=1, ready=0`;
- numeric mode is latched by transaction start and checked on each row/block;
- ownership changes A→B only with the final score handshake and matching owner
  handoff; a slot becomes reusable only after matching `final_release`;
- reset/clear removes active ownership and buffered old-epoch work; mismatched
  epoch completions are consumed, counted, and dropped;
- malformed token/key/mask and non-finite score data produce a buffered abort
  with token, error code, and error key.

## Verified counters and tests

- Scheduler full workload: `jobs=6144`, `mac_steps=1,310,720`,
  `valid_macs=33,816,576`, `causal_lane_bubbles=8,126,464`,
  `causal_rows_skipped=6,144`, protocol errors `0`.
- Q-slab lifecycle: needs/readies/retires `256/256/256`, engine
  starts/completions `6144/6144`, protocol errors and epoch drops `0` in the
  clean full workload.
- A-to-B full workload: rows `4096`, causal scores `264192`; deterministic and
  random-backpressure/reset scenarios pass.
- Raw row pipeline XSim: raw FP32 → scale → BF16 RNE → full-row max → A-to-B
  score stream → final release passes.
- Existing QK lane arithmetic equivalence is checked separately for lanes
  `1/2/4/8`; it is supporting arithmetic evidence, not a substitute for a new
  full-size top-level numerical run.

Repeatable commands:

```powershell
tests/run_cats_r4_qk_32lane_engine_iverilog.ps1
tests/run_cats_r4_qk_q_slab_client_iverilog.ps1
tests/run_cats_r4_qk_score_formatter_iverilog.ps1
tests/run_cats_r4_qk_row_assembler_iverilog.ps1
tests/run_cats_r4_qk_ab_handoff_iverilog.ps1
tests/run_cats_r4_qk_slot_lifecycle_iverilog.ps1
tests/run_cats_r4_qk_row_abort_arbiter_iverilog.ps1
tests/run_cats_r4_qk_row_handoff_wrapper_iverilog.ps1
tests/run_cats_r4_qk_a2_row_pipeline_xsim.ps1
```

## Remaining sign-off gates

These are not additional A2 RTL implementation tasks:

1. Vivado 2025.2 can generate `floating_point_0/1/2`, but OOC
   `synth_design` stops because this machine has no license for feature
   `Synthesis` and/or device `xczu15eg`. Therefore no new WNS/utilization claim
   is made.
2. The repository does not provide a frozen full-size Q/K stimulus plus golden
   score artifact for the new A2 wrapper. A new top-level `combined_failures=0`
   claim requires that declared dataset/numeric-mode input from the team.
3. Production manifest/board integration remains deliberately deferred until
   the captain accepts this A handoff and B/C interfaces are at their required
   readiness, as required by the repository plan.

Accordingly, the implementation is ready for review and B-side consumption,
but the branch must not be labeled `A2 READY`, merged into the production
manifest, or used for board-performance claims until those gates close.
