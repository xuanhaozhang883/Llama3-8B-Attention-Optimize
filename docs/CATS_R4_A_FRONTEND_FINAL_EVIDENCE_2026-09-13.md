# CATS-R4 A compute frontend final evidence — 2026-09-13

Status: **A frontend READY TO MERGE.  This is not a system, board, or release
READY claim.**

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

### Vivado 2025.2 real-IP and OOC closure

The final source revision was also checked with Vivado 2025.2 Build 6299465
from `E:/vivado_25_2/2025.2/Vivado`:

- real-Xilinx-Floating-Point-IP XSim passes for `CLUSTERS=1`, `HEAD_DIM=4`,
  and `TOTAL_JOBS=1`, producing 16 rows and 136 scores;
- synthesized OOC at the production arithmetic depth (`CLUSTERS=1`,
  `HEAD_DIM=128`) for `xczu15eg-ffvb1156-2-i` at 6.666 ns (150 MHz);
- WNS `+1.932 ns`, TNS `0.000 ns`, setup failing endpoints `0`;
- WHS `+0.037 ns`, THS `0.000 ns`, hold failing endpoints `0`;
- CDC: `All paths are Safely Timed.`;
- every `check_timing` category is `0`, and methodology checks found `0`;
- synthesis completed with 0 errors, 0 critical warnings, and 0 synthesis
  warnings.  The prior static out-of-range index warning is absent.

The synthesized one-cluster frontend uses 28,552 LUTs, 60,265 FFs, and 192
DSP blocks in the hierarchical utilization report.  These are OOC synthesis
figures, not placed-and-routed system PPA.  The retained text-only reports and
the exact OOC XDC are under
`artifacts/cats_r4_a_frontend_20260913/vivado/`; no DCP or temporary Vivado
project is included.

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

## Scope boundary

All A-owned functional and implementation gates in the parallel plan are now
closed, so the frontend handoff is **READY TO MERGE**.  The frontend remains a
single-clock OOC composition; its clean CDC report does not replace C-owned
system CDC validation.  B4 numeric RTL, production weight/V and DMA services,
output reorder, board integration, BIT/XSA/ELF generation, and board
measurements remain outside this delivery.  Consequently this statement must
not be promoted to a whole-system or board-ready claim.
