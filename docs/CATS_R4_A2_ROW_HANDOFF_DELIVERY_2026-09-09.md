# CATS-R4 A2 row handoff delivery — 2026-09-09

Status: **A unit/OOC READY on A-owned evidence; production integration NOT READY**.

- Branch: `agent/cats-r4-a2-row-handoff`
- Base commit: `7a36930a83ec716349b3dbc6b0bca2856cce7011`
- Technical evidence commit: `051559ef1edf03e7b3aeed9010c1b4c5bfa577a5`
- Consumed interface tag: `CATS_R4_INTERFACE_V3_COMMIT` → `4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`

This delivery does not modify the production manifest, board top, B numeric
internals, or C AXI/DMA implementation. A unit/OOC readiness does not authorize
a merge to `main` or constitute production-integration acceptance.

## Implemented A-side chain

- `rtl/core/bc/qk/cats_r4_qk_32lane_scheduler.sv`: tagged Q/K/MAC scheduling,
  causal masks, variable response latency, and `start_row_offset`.
- `rtl/core/bc/qk/cats_r4_qk_32lane_engine.sv`: scheduler, real FP32 service
  boundary, and backpressured score FIFO.
- `rtl/core/bc/qk/cats_r4_qk_q_slab_client.sv`: Q-slab need/ready/retire
  lifecycle for 256 slabs and 6144 engine jobs.
- `rtl/core/bc/qk/cats_r4_qk_score_formatter.sv`: `1/sqrt(128)` FP32 scaling
  and BF16 round-to-nearest-even formatting.
- `rtl/core/bc/qk/cats_r4_qk_a2_row_pipeline.sv`: raw engine scores through
  formatter, three-slot row assembly/max, physical score-store writes, frozen
  A-to-B row/score streams, aborts, ownership handoff, and final-release reuse.
- `rtl/core/bc/qk/cats_r4_qk_row_assembler.sv`, `cats_r4_qk_ab_handoff.sv`,
  `cats_r4_qk_slot_lifecycle.sv`, and `cats_r4_qk_row_abort_arbiter.sv`: row
  completion, strict key order/last, error delivery, and slot lifecycle.
- `rtl/core/bc/qk/qk_parallel_systolic_gqa_top.sv`: explicit per-lane
  `tile_in_valid` drive fixes the legacy Icarus lane-1/2/4/8 elaboration issue.

The three physical slots are safe because at most three rows are active in a
sub-batch. A later sub-batch cannot overwrite a B-owned slot: the raw score path
backpressures until `final_release` returns the exact token to FREE.

## Frozen A-to-B interface

Row channel (`valid/ready`):

`epoch[15:0], group[2:0], global_q_head[4:0], row[6:0], slot_id[1:0], numeric_mode[1:0], row_max_bf16[15:0]`

Score channel (`valid/ready`):

the same token plus `key[6:0], score_bf16[15:0], last`.

The regressions prove:

- each row covers every legal causal key `0..row` exactly once;
- score keys are strictly increasing and `last` is asserted only at `key=row`;
- score and row max cross the BF16 RNE formatter boundary before handoff;
- every payload field remains stable while `valid=1, ready=0`;
- numeric mode is latched at transaction start and cannot change while busy;
- A transfers ownership after the final score handshake and matching owner
  handoff; reuse requires the matching B `final_release`;
- reset/clear removes active ownership and buffered old-epoch work; mismatched
  epoch completions are consumed, counted, and dropped;
- malformed token/key/mask and non-finite scores produce a buffered abort with
  token, error code, and error key.

## Verified evidence

- Complete regression manifest:
  `artifacts/cats_r4_a2_regression_2026-09-10/manifest.json`.
- Scheduler workload: `jobs=6144`, `mac_steps=1,310,720`,
  `valid_macs=33,816,576`, `causal_lane_bubbles=8,126,464`,
  `causal_rows_skipped=6,144`, protocol errors `0`.
- Q-slab lifecycle: needs/readies/retires `256/256/256`, engine
  starts/completions `6144/6144`.
- A-to-B workload: `4096` rows and `264192` causal scores under deterministic
  and random backpressure/reset scenarios.
- Raw row XSim path passes FP32 → scale → BF16 RNE → full-row max → A-to-B
  stream → final release.
- Legacy lane equivalence now passes `2048` scores. Noncausal lane-1/2/4/8
  cycles are `23986/16162/12293/10577`; causal cycles are
  `14752/10865/8928/7993`.
- Full-size candidate score golden contains `264192` BF16 values in
  `artifacts/cats_r4_a2_score_golden_2026-09-10/scores_bf16.hex`, SHA-256
  `F2949704CB683D22EBBEE5C6F2ED6B05D1E16149DA3844A2C3E53EEE4515D565`.
  It is generated from repository Q/K and RoPE files but is explicitly
  `CANDIDATE_NOT_FROZEN`; it is not yet an independent C/D golden acceptance.
- Vivado 2025.2 real Floating Point IP OOC for `xczu15eg-ffvb1156-2-i` passes
  150 MHz: WNS `+1.816 ns`, TNS `0.000 ns`, failing setup endpoints `0`;
  utilization is `20,166` CLB LUTs, `44,983` CLB registers, `128` DSPs,
  `0` BRAM tiles, and `0` URAM. Synthesis errors and critical warnings are
  both `0`. Evidence is in `artifacts/cats_r4_a2_ooc_2026-09-09/manifest.json`.

## Reproduce

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
tests/run_v312_qk_multilane_checks.ps1
python -m unittest -v tests.test_cats_r4_a2_score_golden

$env:XILINXD_LICENSE_FILE = 'C:/Software/AMD/lic/25.2/vivado.lic'
$env:LM_LICENSE_FILE = $env:XILINXD_LICENSE_FILE
$oocOut = Join-Path $env:TEMP 'cats-r4-a2-ooc-review'
tests/run_cats_r4_qk_32lane_engine_realip_ooc.ps1 `
  -VivadoRoot C:/Software/AMD/vivado25.2/2025.2/Vivado `
  -OutputRoot $oocOut
```

## Readiness decision and remaining gates

A-owned scheduler, score/max, formatter, handoff/ownership, full-workload,
failure-path, legacy-equivalence, and OOC evidence are present and passing.
Therefore this delivery records **A unit/OOC READY** at the technical evidence
commit above.

The repository-wide `CATS_R4_RELEASE_GATE.md` remains unchanged because its A
checklist still combines A score ownership with B-owned FP32 weight production,
and because A/B/C have not yet jointly confirmed one resolved interface tag.
The following are team/integration gates, not unfinished A2 RTL:

1. C/D must independently validate or replace and freeze the candidate
   full-size score golden, then bind it to the common interface tag.
2. B must consume the frozen row/score handoff and provide B2 numerical and
   ownership evidence; C must provide memory/DMA/CDC/output evidence.
3. The compute wrapper must demonstrate an end-to-end full-size numerical
   comparison, including a recorded zero-failure result.
4. C/captain-owned staged integration must use
   `codex/cats-r4-local-integration`; production manifest, board top, BD,
   constraints, implementation, timing, and DRC gates must pass before `main`.

Until those gates close, this branch is reviewable and consumable by B/C but
must not be described as production-integration READY.
