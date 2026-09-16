# CATS-R4 A4 Integration Requests

Date: 2026-09-15

These requests are owner decisions, not work silently assigned to member A. Reply with exact branch and complete commit SHA where applicable.

## To C / team lead

### IR-A4-01 — canonical output capacity (blocks full A4-2 performance gate)

The executable model predicts only 1.058x for two clusters with 32 rows of local output buffering and strict global sequence, versus 1.951x in the 512-row sensitivity case. Please select a realizable production mechanism and return:

1. per-cluster finite row/beat capacity and physical memory choice;
2. whether Context acceptance occurs into a local queue, shared out-of-order spool, or another structure;
3. canonical commit arbitration, total shared bandwidth, and backpressure point;
4. epoch/reset/drain behavior and error handling;
5. resource estimate or measured SHA, plus the exact C interface commit.

Acceptance must state which cycle is A's final Context-accept boundary. Until then, A will not claim full A4-2 speedup READY or begin A4-4 replication.

### IR-A4-02 — group command/service binding

Please accept or redline `docs/CATS_R4_A4_INTERFACE.md`, especially per-cluster `group_cmd_*`, `group_done_*`, the K/V buffer selector, Q/K/V response drain, and whether C presents physically independent logical service ports. Return an accepted interface commit; do not move the V3 tag.

### IR-A4-03 — resource budget

Please provide current C post-synthesis/post-route use if available, reserved BRAM/URAM/LUT/FF, and the accepted full-board budget. The linear 4-cluster compute risk is 247868 LUT, 460100 FF, 1548 DSP before C logic, above the older 230k LUT/380k FF planning targets.

### IR-A4-04 — A3 integration and release identity

Please return:

- A3 review/accepted integration SHA for `codex/a-cats-r4-a3-compute-cluster` at `9be65351193608b2b1c1597ede166b1534437496`;
- authoritative path or replacement for the missing handoff total-plan document;
- decision and provenance for `mem/sin_bf16.hex`: documented expected `C98A462FA05FC69845ACBE8B6175A1EC854AC91E1FB5B4A33E2AA7F84271FC5D` versus current `C4615AEE875F66BE8A8458E3F42C8F7AF32541AFFAAA94B809316562F14B4397`.

## To B

### IR-A4-05 — B4 owner acceptance and scaled numeric review

Return an accepted complete SHA containing the row-error/release arbitration change from `b53902734501738df2a9a467e7907ffe99a11eda`, or explicitly reject it with a replacement patch. Also confirm that the same accepted B4 arithmetic is used independently per cluster and that A4 does not change accumulation order or numerical thresholds.

## To D

### IR-A4-06 — independent performance boundary review

Please accept or redline the first-QK-issue through last-C-accepted-Context-chunk boundary, the exact `speedup2 >= 1.6` automatic gate, the `<5%` normal-load imbalance equation, and evidence comparability requirements. Review the model configuration and do not treat its prediction as measurement.

## Response record

| Request | Owner | Status | Accepted SHA/decision |
|---|---|---|---|
| IR-A4-01 | C/lead | TEMPORARY FROZEN / PRODUCTION OPEN | `f3be77417c14c81321e6e8d2b0e8f6957e21ea8a`; 512-row/cluster finite spool and shared 64-bit/cycle sink accepted for A-side P6 development; C production RTL pending |
| IR-A4-02 | C/lead | TEMPORARY FROZEN / PRODUCTION OPEN | `f3be77417c14c81321e6e8d2b0e8f6957e21ea8a`; independent compute-facing service arrays, global halt, sidecar drain, and exact drain gate accepted; C production RTL pending |
| IR-A4-03 | C/lead | OPEN | — |
| IR-A4-04 | C/lead | OPEN | — |
| IR-A4-05 | B/lead | OPEN | — |
| IR-A4-06 | D | OPEN | — |
