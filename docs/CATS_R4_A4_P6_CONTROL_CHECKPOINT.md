# CATS-R4 A4 P6 Control-Unit Checkpoint

Date: 2026-09-15

Branch: `codex/a-cats-r4-a4-2cluster`

Implementation commits:

- event join and telemetry: `232ee0fbf8fc2093b99b41f40615296f3f27ca5b`
- transaction start fanout: `e17a223adb3239459e5137d2e882f9e56f8c4a9e`
- dual-adapter control-plane TB: `fbefb61a9fe5f20f6545478672e55d2631d494e8`

Exact evidence source commit: `982f98e2e631b8df82119e5fcbd3a2f576d2dcd9`

Status: **P6 reusable control units READY; P6 N=2 integration NOT READY**.

## Delivered units

- `cats_r4_a4_event_join.sv` provides one buffered entry per cluster, locked round-robin arbitration, stable output under backpressure, per-source accepted counters, emitted/stall counters, and simultaneous-accept telemetry.
- `cats_r4_a4_telemetry.sv` captures a coherent cluster-local snapshot before reduction. It reports minimum first issue, maximum last local commit, aggregate group/wait/stall/active counters, and conservative `all_done` fault/completion gating.
- `cats_r4_a4_txn_fanout.sv` captures epoch/mode before presenting per-cluster starts, tracks independent child acceptance, rejects busy starts/illegal modes/epoch reuse, and unlocks only after explicit drain completion plus global quiescence.
- Both units support the planned cluster counts 1, 2, and 4. This checkpoint exercises the P6 N=2 telemetry path and the stricter four-source event arbitration case.

## Independent TB evidence

Event-join PASS proves:

- two sources can be accepted in the same cycle without loss;
- the selected source and payload stay stable for three blocked cycles;
- pending sources drain in locked round-robin order;
- source/emission/stall/simultaneous counters match and clear correctly;
- state `clear` discards buffered events without silently clearing counters.

Telemetry PASS proves:

- reductions use the captured snapshot even when live inputs change immediately afterward;
- snapshot fields stay stable for three blocked cycles;
- first/last and all aggregate sums are exact for two clusters;
- a faulted/incomplete cluster prevents `all_done`;
- `clear` discards a held snapshot and returns the unit to request-ready state.

Transaction-fanout PASS proves:

- child clusters may accept start asynchronously and exactly once;
- the captured epoch/mode stay stable while one child is blocked;
- a held busy request is reported once rather than producing an error storm;
- global drain cannot unlock the transaction before every cluster is quiescent;
- same-epoch reuse and modes 2/3 are rejected, while coordinated clear removes active/pending state.

Dual-adapter control-plane PASS proves:

- group 0 and group 1 are accepted concurrently by their statically assigned adapters under one locked transaction;
- different per-cluster job backpressure produces 32 correctly tokenized jobs and retires per cluster without cross-coupling;
- cluster 0 may hold a stable completion while cluster 1 independently reaches completion;
- a group routed to the wrong adapter raises only that adapter's owner error;
- aggregate conservation is two groups, 64 jobs, 64 retires, and two normal completions.

PASS markers:

```text
PASS A4 EVENT JOIN clusters=4 emitted=3 locked_stalls=3 simultaneous=1
PASS A4 TELEMETRY clusters=2 coherent_stall=3 fault_gating=1 clear=1 first=100 last=900 groups=8 active=1500
PASS A4 TXN FANOUT clusters=2 async_start=1 stall_stable=3 busy_once=1 drain_gate=1 epoch_reuse=1 invalid_mode=1 clear=1
PASS A4 CONTROL PLANE clusters=2 groups=2 jobs=64 retires=64 async_completion=1 done_stall=3 wrong_route_isolated=1
```

Commands:

```powershell
& tests\run_cats_r4_a4_event_join_iverilog.ps1
& tests\run_cats_r4_a4_telemetry_iverilog.ps1
& tests\run_cats_r4_a4_txn_fanout_iverilog.ps1
& tests\run_cats_r4_a4_control_plane_iverilog.ps1
& tests\run_cats_r4_a4_suite.ps1 -Clusters 2 -Mode 1 -Seed 19 -Suite Unit -OutputRoot <unique-dir> -TimeoutSeconds 300
& <python> tests\check_cats_r4_a4_checkpoint.py artifacts\a4_p6_control_20260915\evidence_index.json
```

## Remaining P6 work and boundary

The two real group adapters have now been composed and verified at the control-plane boundary, but they are not yet connected to two real A3 instances. N=2 independent C-service wiring, actual start/event/halt/drain integration, data-plane progress under peer stall, and full-workload aggregate conservation remain open.

The exact unit-suite evidence records `dirty=false`, `status=PASS`, `exit_code=0`, and empty stderr for source commit `982f98e2e631b8df82119e5fcbd3a2f576d2dcd9`. Raw evidence is stored in the ignored local archive at `artifacts/local_archive/a4_p6_control_plane_982f98e_20260915`; tracked hashes are in the evidence index.

Checkpoint validator commit `28dede11043dea9e197ba1480934c4f522f4906e` verifies the tracked source hashes and exact-suite metadata. Its negative tests reject hash tampering, dirty/failed runs, removal of the canonical-output blocker, and any attempt to label this unit checkpoint final READY. The stricter final A4 readiness validator remains unchanged.

`A4-CANONICAL-OUTPUT` remains a P1 STOP for production N=2 integration and performance/OOC claims. This checkpoint does not claim P6 completion, A4-2 readiness, speedup, real-IP coverage, or C system acceptance.
