# CATS-R4 A2 factual handoff to C — 2026-09-09

## Immutable identity

- Owner: member A
- Source branch: `agent/cats-r4-a2-row-handoff`
- Base commit: `7a36930a83ec716349b3dbc6b0bca2856cce7011`
- Technical evidence commit: `051559ef1edf03e7b3aeed9010c1b4c5bfa577a5`
- Interface tag: `CATS_R4_INTERFACE_V3_COMMIT`
- Resolved interface commit: `4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`
- Target shared branch: `codex/cats-r4-local-integration`
- Tool/part: Vivado 2025.2, `xczu15eg-ffvb1156-2-i`
- A status: **unit/OOC READY on A-owned evidence**
- Project status: **production integration NOT READY**

The technical evidence commit is the immutable review anchor. Later commits may
only add documentation unless their diffs and new evidence are reviewed.

## Files to consume

Primary RTL:

- `rtl/core/bc/qk/cats_r4_qk_32lane_scheduler.sv`
- `rtl/core/bc/qk/cats_r4_qk_32lane_fp32_service.sv`
- `rtl/core/bc/qk/cats_r4_qk_32lane_engine.sv`
- `rtl/core/bc/qk/cats_r4_qk_q_slab_client.sv`
- `rtl/core/bc/qk/cats_r4_qk_score_formatter.sv`
- `rtl/core/bc/qk/cats_r4_qk_row_assembler.sv`
- `rtl/core/bc/qk/cats_r4_qk_ab_handoff.sv`
- `rtl/core/bc/qk/cats_r4_qk_slot_lifecycle.sv`
- `rtl/core/bc/qk/cats_r4_qk_row_abort_arbiter.sv`
- `rtl/core/bc/qk/cats_r4_qk_row_handoff_wrapper.sv`
- `rtl/core/bc/qk/cats_r4_qk_a2_row_pipeline.sv`

Testbenches:

- `tb/tb_cats_r4_qk_32lane_engine.sv`
- `tb/tb_cats_r4_qk_q_slab_client.sv`
- `tb/tb_cats_r4_qk_score_formatter.sv`
- `tb/tb_cats_r4_qk_row_assembler.sv`
- `tb/tb_cats_r4_qk_ab_handoff.sv`
- `tb/tb_cats_r4_qk_slot_lifecycle.sv`
- `tb/tb_cats_r4_qk_row_abort_arbiter.sv`
- `tb/tb_cats_r4_qk_row_handoff_wrapper.sv`
- `tb/tb_cats_r4_qk_a2_row_pipeline.sv`
- `tb/tb_v312_qk_multilane_equivalence.sv`

Runners:

- `tests/run_cats_r4_qk_32lane_engine_iverilog.ps1`
- `tests/run_cats_r4_qk_q_slab_client_iverilog.ps1`
- `tests/run_cats_r4_qk_score_formatter_iverilog.ps1`
- `tests/run_cats_r4_qk_row_assembler_iverilog.ps1`
- `tests/run_cats_r4_qk_ab_handoff_iverilog.ps1`
- `tests/run_cats_r4_qk_slot_lifecycle_iverilog.ps1`
- `tests/run_cats_r4_qk_row_abort_arbiter_iverilog.ps1`
- `tests/run_cats_r4_qk_row_handoff_wrapper_iverilog.ps1`
- `tests/run_cats_r4_qk_a2_row_pipeline_xsim.ps1`
- `tests/run_v312_qk_multilane_checks.ps1`
- `tests/run_cats_r4_qk_32lane_engine_realip_ooc.ps1`

Golden generation and verification:

- `python/generate_cats_r4_a2_score_golden.py`
- `tests/test_cats_r4_a2_score_golden.py`
- `artifacts/cats_r4_a2_score_golden_2026-09-10/manifest.json`
- `artifacts/cats_r4_a2_score_golden_2026-09-10/scores_bf16.hex`

Auditable evidence and detailed delivery:

- `artifacts/cats_r4_a2_regression_2026-09-10/manifest.json`
- `artifacts/cats_r4_a2_ooc_2026-09-09/manifest.json`
- `docs/CATS_R4_A2_ROW_HANDOFF_DELIVERY_2026-09-09.md`

## Frozen A-to-B channels

Row channel uses `valid/ready` with:

`epoch[15:0], group[2:0], global_q_head[4:0], row[6:0], slot_id[1:0], numeric_mode[1:0], row_max_bf16[15:0]`

Score channel uses `valid/ready`, the same row token, and:

`key[6:0], score_bf16[15:0], last`

Both scores and row max have passed the BF16 RNE formatter. Scores are emitted
strictly in `key=0..row` order and `last` is true only for `key=row`. Payload is
stable under backpressure. Numeric mode is latched at row start. The last score
handshake and matching owner handoff transfer the slot from A to B; only a
matching B `final_release` permits reuse. Reset/clear and epoch mismatch remove
old work, while malformed metadata or non-finite data is reported through the
buffered abort channel.

## Evidence accepted from A

- Full workload: `4096` rows, `264192` valid causal scores.
- Q-slab lifecycle: `256` slabs and `6144` engine jobs.
- Scheduler: `33,816,576` valid MACs and zero protocol errors.
- Legacy lane equivalence: PASS for lanes 1/2/4/8, `2048` compared scores.
- Candidate full-size golden: `264192` BF16 scores; SHA-256
  `F2949704CB683D22EBBEE5C6F2ED6B05D1E16149DA3844A2C3E53EEE4515D565`.
- OOC at 150 MHz: WNS `+1.816 ns`, TNS `0.000 ns`, no failing setup endpoint;
  `20,166` CLB LUTs, `44,983` registers, `128` DSPs, no BRAM/URAM, zero
  synthesis errors, and zero critical warnings.

Every regression-log SHA-256 is recorded in
`artifacts/cats_r4_a2_regression_2026-09-10/manifest.json`; OOC input, command,
report, and log hashes are recorded in the OOC manifest. The score golden is a
candidate derived from repository Q/K and RoPE data, not an independently
frozen C/D reference.

## Reproduction commands

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
$oocOut = Join-Path $env:TEMP 'cats-r4-a2-ooc-c-review'
tests/run_cats_r4_qk_32lane_engine_realip_ooc.ps1 `
  -VivadoRoot C:/Software/AMD/vivado25.2/2025.2/Vivado `
  -OutputRoot $oocOut
```

## Responsibility split and next actions

A-owned implementation in this handoff is complete. A remains responsible for
answering review findings that identify an A-side defect and for issuing new
evidence if A-owned RTL changes.

C/D must independently validate or replace the candidate score golden, freeze
the accepted artifact and shared interface identity, and record hashes. C owns
memory service, bank mapping/lifecycle, DMA, CDC, output, production wrapper,
board integration, and tool-build evidence. B owns Softmax, FP32 weights, and
PV and must prove consumption of the row/score contract.

Review or cherry-pick this evidence into `codex/cats-r4-local-integration` only
after checking the exact commit and interface tag. Do not overwrite A/B-owned
files, change the frozen ports without a documented coordinated diff, force
push the shared branch, modify the production manifest/board files without the
captain's approval, or merge directly to `main` before all release gates pass.
