# CATS-R4 A compute frontend final evidence — 2026-09-13

Status: **A RTL and portable simulation work complete; A READY TO MERGE is
blocked by the missing current-front-end Vivado/XSim/OOC run.  This is not a
system or board READY claim.**

This record supersedes the earlier same-day frontend checkpoint.  It covers
only the A-owned QK/score frontend on branch `cats-r4-a-frontend`, based on
COMMON_BASE `18cdd2335bfa60927b1fbb466020561681f725eb`.  B4, production
weight/V, DMA, CDC, output reorder, board integration, BIT/XSA/ELF, and board
measurements remain outside this delivery.

## Implementation closure

- `cats_r4_compute_frontend.sv` composes an independently stateful Q-slab
  client, tagged 32-lane QK engine, score formatter, three-slot row pipeline,
  A-to-B handoff, abort path, and final-release owner for each of 1/2/4
  clusters.
- A one-entry FIFO per cluster decouples the single ingress stream.  Static
  `group % CLUSTERS` routing can therefore overlap work in different clusters
  without allowing jobs for a busy cluster to overwrite one another.
- Per-cluster counters now expose jobs, engine jobs, Q/K requests, MAC steps,
  valid MACs, causal bubbles/skips, rows/scores, assignment errors, and owner
  errors.  The end-to-end TB aggregates these counters and turns workload
  conservation, exact load balance, three-slot occupancy, and pairwise
  timestamp overlap into assertions.
- The frontend rejects malformed group/head tokens and stale-epoch jobs
  before a child FIFO.  Unsupported numeric modes remain sticky transaction
  errors in the row pipeline.

## Reproducible results

All tests use deterministic pseudo-random backpressure.  The frontend seed is
`0x1a2b3c4d`; the lane-equivalence seed is `0x6d2b79f5`.

### Full frontend workload

`tests/run_cats_r4_compute_frontend_e2e_iverilog.ps1 -TotalJobs 256`
runs the real frontend RTL with two-cycle Q/K memory models, a score-store
model, random ready/backpressure, and real final-release return for
`CLUSTERS=1,2,4`.

Every configuration passes with the same total workload:

- jobs `256`;
- Q-slab engine jobs `6144/6144`;
- Q requests / K requests `40960/40960`;
- MAC steps issued/completed `40960/40960`;
- causal valid MACs `1,056,768` at the TB's practical `HEAD_DIM=4`;
- rows `4096`, row transfers `4096`, scores `264192`;
- owner errors `0`, assignment errors `0`, aborts `0`;
- max slot occupancy exactly `3` in every active cluster.

The cluster job split is exactly `256`, `128/128`, and `64/64/64/64` for the
1/2/4-cluster runs.  The per-cluster first/last row timestamps overlap for
every cluster pair; this proves concurrent cluster execution rather than only
balanced serial assignment.  Exact counters and timestamps are in
`artifacts/cats_r4_a_frontend_20260913/full/*_counters.log`.

The dedicated full-size scheduler regression separately passes at
`HEAD_DIM=128`: jobs `6144`, valid QK MACs `33,816,576`.  This prevents the
shortened frontend arithmetic depth from being misreported as the production
MAC total.

### Protocol and lifecycle stress

- The 1/2/4 routing regression exercises every legal group, rejects one
  group/head mismatch and one stale-epoch job, and rejects unsupported modes.
- The negative E2E run injects an old-epoch/non-finite score response.  It
  observes `row_abort`, then deliberately repeats a completed final release;
  the owner checker counts the invalid duplicate and no deadlock occurs.
- The reset E2E run clears queued/in-flight Q/K/score state, restarts the same
  epoch transaction, and completes under random backpressure.
- The legacy independent arithmetic regression now passes lane `1/2/4/8`
  equivalence for non-causal and causal cases, including request/output
  backpressure stability and equal 2,048-score results.

Compile, runtime, counter, lane, and scheduler logs are retained below
`artifacts/cats_r4_a_frontend_20260913/`.  `SHA256SUMS.txt` binds the retained
logs and all changed A-owned source/test files.

## Honest limitation / merge gate

Vivado 2025.2 executables are not installed or discoverable in the current
environment.  `Get-Command` found no `vivado`, `xvlog`, `xelab`, or `xsim`,
and the previously documented path
`C:/Software/AMD/vivado25.2/2025.2/Vivado/bin` is absent.  Consequently there
is no new real-Xilinx-IP XSim, current frontend OOC synthesis, utilization,
WNS/TNS, timing-constraint, or CDC report for this source revision.

The frontend is single-clock and contains no internal CDC, but that does not
replace a Vivado CDC report or C-owned system CDC validation.  Historical
Vivado results for the scheduler/engine/row subblocks are not relabeled as a
result for this new composition.  Therefore this branch must remain
**NOT READY TO MERGE** until the current frontend is run with the restored
Vivado toolchain and those reports pass.  No failing random seed is hidden;
the only open gate is recorded in the artifact limitation files.
