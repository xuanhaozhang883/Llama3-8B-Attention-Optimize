# CATS-R4 A4 P5 N=1 Compute Array Checkpoint

Date: 2026-09-15

Branch: `codex/a-cats-r4-a4-2cluster`

Implementation commit: `99efa2545cc0807ce93ef046514204bcf399bc7f`

Status: **P5 functional/protocol READY**. This is not A4-2 performance READY and does not remove the P1 canonical-output STOP.

## Delivered composition

- `cats_r4_a4_compute_array.sv` composes one real A3 cluster with one P4 group/job adapter.
- C-owned Q/K/V, weight-memory, output, and error services remain outside the wrapper.
- A3 now exposes `cluster_quiescent` from public A-owned state; the wrapper does not inspect A3 hierarchy.
- Transaction epoch and numeric mode are latched at start. The group adapter validates the frozen values.
- A group expands to exactly 32 jobs and completes only after 32 retires, 65536 Context words, 512 releases, free slots, and cluster quiescence.

## Independent scoreboard

The A4 TB validates:

- A-to-B score token fields, `key=0..row`, `last` only at `key=row`, exact per-row score count, and payload stability under backpressure;
- Context output as a token set with exactly four locally ordered feature blocks per row;
- release uniqueness and token validity;
- all group completion fields and aggregate conservation counters.

The set-based Context check is intentional. The real C three-slot memory may publish different rows out of global order; canonical global ordering remains C/lead-owned and is still the P1 STOP item.

## Exact-commit full protocol evidence

Both full runs use implementation commit `99efa2545cc0807ce93ef046514204bcf399bc7f`, seed `3019898881`, the same protocol service model, and the same workload.

| Mode | Rows | Causal scores | Weight writes / Context words | Releases | Groups | RTL cycles |
|---:|---:|---:|---:|---:|---:|---:|
| 0 | 4096 | 264192 | 524288 / 524288 | 4096 | 8 | 3055666 |
| 1 | 4096 | 264192 | 524288 / 524288 | 4096 | 8 | 3055666 |

Evidence is explicitly `A4_N1_PROTOCOL_MODEL_NOT_REAL_IP`.

## Real C weight-memory integration

A current-commit mode-0 slice calls `rtl/core/cluster/cats_r4_weight_slot_mem.sv` rather than the test service model. It passed 32 jobs, 512 rows, 33024 causal scores, 65536 Context words, and 512 releases in 369371 RTL cycles. This proves the N=1 wrapper can call the current C weight-memory boundary; it is not full C service or DDR acceptance.

## Fair A3 comparison

The reference A3 run uses the same mode, seed, workload, Q/K/V models, weight service, and random backpressure:

| Candidate | Cycles |
|---|---:|
| A3 direct jobs | 3056384 |
| A4 N=1 group wrapper | 3055666 |
| Delta | -718 (-0.023492%) |

The tiny negative delta is attributable to ready/LFSR phase changes at group boundaries and is below this protocol model's run-to-run service-phase resolution. The supported conclusion is **no measurable N=1 adapter regression**, not a speedup claim. PowerShell runtime is not used for performance.

## Commands

```powershell
& tests\run_cats_r4_a4_compute_array_iverilog.ps1 -IcarusRoot C:\Software\iverilog -Mode 0 -JobCount 256 -OutputRoot <unique-dir>
& tests\run_cats_r4_a4_compute_array_iverilog.ps1 -IcarusRoot C:\Software\iverilog -Mode 1 -JobCount 256 -OutputRoot <unique-dir>
& tests\run_cats_r4_a4_compute_array_iverilog.ps1 -IcarusRoot C:\Software\iverilog -Mode 0 -JobCount 32 -UseRealCWeightMem -OutputRoot <unique-dir>
```

Tracked hashes are in `artifacts/a4_p5_20260915/evidence_index.json`. Raw logs remain in the ignored local archive and are not portable until uploaded to a team artifact store.

## Remaining boundary

P5 functional/protocol work is closed. Physical resource delta is deferred to the same-tool A4 OOC comparison rather than inferred from source lines. P6/P7 can only proceed as non-production experiments while `A4-CANONICAL-OUTPUT` remains unresolved; no A4-2 performance/production READY claim is allowed.

