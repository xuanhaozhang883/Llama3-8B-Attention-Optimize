# CATS-R4 A4 P6 Control-Unit Checkpoint

Date: 2026-09-15

Branch: `codex/a-cats-r4-a4-2cluster`

Implementation commit: `232ee0fbf8fc2093b99b41f40615296f3f27ca5b`

Status: **P6 reusable control units READY; P6 N=2 integration NOT READY**.

## Delivered units

- `cats_r4_a4_event_join.sv` provides one buffered entry per cluster, locked round-robin arbitration, stable output under backpressure, per-source accepted counters, emitted/stall counters, and simultaneous-accept telemetry.
- `cats_r4_a4_telemetry.sv` captures a coherent cluster-local snapshot before reduction. It reports minimum first issue, maximum last local commit, aggregate group/wait/stall/active counters, and conservative `all_done` fault/completion gating.
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

PASS markers:

```text
PASS A4 EVENT JOIN clusters=4 emitted=3 locked_stalls=3 simultaneous=1
PASS A4 TELEMETRY clusters=2 coherent_stall=3 fault_gating=1 clear=1 first=100 last=900 groups=8 active=1500
```

Commands:

```powershell
& tests\run_cats_r4_a4_event_join_iverilog.ps1
& tests\run_cats_r4_a4_telemetry_iverilog.ps1
```

## Remaining P6 work and boundary

These reusable units are not yet connected to two real A3/adapter instances. N=2 start locking, independent C-service wiring, actual event/halt/drain integration, cluster progress under peer stall, and aggregate conservation remain open.

`A4-CANONICAL-OUTPUT` remains a P1 STOP for production N=2 integration and performance/OOC claims. This checkpoint does not claim P6 completion, A4-2 readiness, speedup, real-IP coverage, or C system acceptance.
