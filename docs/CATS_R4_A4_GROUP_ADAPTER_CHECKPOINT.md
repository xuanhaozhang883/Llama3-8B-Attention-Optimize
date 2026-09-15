# CATS-R4 A4 Group/Job Adapter Checkpoint

Date: 2026-09-15

Branch: `codex/a-cats-r4-a4-2cluster`

Status: **P4 unit READY**. This is not A4-2 system/performance READY.

## Delivered files

```text
rtl/core/bc/integration/cats_r4_a4_group_job_adapter.sv
tb/tb_cats_r4_a4_group_job_adapter.sv
tests/run_cats_r4_a4_group_job_adapter_iverilog.ps1
tests/run_cats_r4_a4_unit.ps1
```

The adapter is instantiated once per cluster with constant `CLUSTERS` and `CLUSTER_ID`. It consumes a C-side group command, validates static ownership and local sequence, latches epoch/mode/KV selector, and emits exactly 32 A3 jobs in `(local_head,row_window)` order.

Normal group completion requires:

- 32 jobs accepted;
- 32 matching Q-slab retires accepted;
- an exact +65536 Context-word delta;
- an exact +512 final-release delta;
- all three score slots free (`slot_owner==0`);
- explicit `cluster_quiescent`.

Error or abort produces a terminal record marked error/aborted; it never increments the normal-completed counter. Completion and protocol-error records hold all payload fields while stalled.

## Verification

```powershell
foreach ($n in 1,2,4) {
  & tests\run_cats_r4_a4_unit.ps1 -Clusters $n -Mode 1 -Seed 19 `
    -OutputRoot <unique-output-root> -TimeoutSeconds 300
}
```

PASS matrix:

| CLUSTERS | cluster IDs tested | result |
|---:|---|---|
| 1 | 0 | PASS |
| 2 | 0,1 | PASS |
| 4 | 0,1,2,3 | PASS |

Every instance verifies:

- invalid owner/local-index command rejection;
- duplicate command blocked while busy;
- exact 32-job head/window mapping and job payload stability;
- retire backpressure and mismatched-retire fault;
- no done after all Context until final releases also complete;
- done payload stability under backpressure;
- mode/epoch control lock while busy, single error notification;
- external abort and coordinated clear;
- rejection of `counter_clear` while busy;
- counter reset only while idle.

## Integration boundary disposition

P5 resolved `cluster_quiescent` by exposing A-owned state from the real A3
instance without hierarchy references; see `docs/CATS_R4_A4_P5_N1_CHECKPOINT.md`.
C still must accept the proposed group command, K/V selector, response-drain,
and canonical-output contract. The P1 32-row output-queue STOP remains active
for full A4-2 performance work.
