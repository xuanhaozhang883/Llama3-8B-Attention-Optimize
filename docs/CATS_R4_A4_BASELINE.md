# CATS-R4 A4 Baseline

Date: 2026-09-15

## Development identity

- A4 branch: `codex/a-cats-r4-a4-2cluster`.
- A4 worktree: `C:\lhm\2_Work\Llama3-8B-Attention-Optimize\a4-2cluster`.
- Exact parent: `9be65351193608b2b1c1597ede166b1534437496` on `codex/a-cats-r4-a3-compute-cluster`.
- A3 tested source/tool head: `1372b0bb8f1264311d4e9bffd1b656bceea05c68`.
- Interface tag object: `abe7492f5cd547d3128707b4b1405fcfca6909be`.
- Peeled interface commit: `4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`.
- A4 target: `xczu15eg-ffvb1156-2-i`, Vivado 2025.2, 6.666 ns.

The A4 branch intentionally starts from the pushed A3 checkpoint while team integration is pending. It does not imply that A3 has been accepted into the integration branch or `main`.

## Remote audit

The following values were read directly from GitHub with `git ls-remote` on 2026-09-15:

| Remote branch | SHA |
|---|---|
| `codex/a-cats-r4-a3-compute-cluster` | `9be65351193608b2b1c1597ede166b1534437496` |
| `codex/cats-r4-local-integration` | `f9419e8d30d13f5aeba6cfeb6dd1403028f79d43` |
| `main` | `eb530f835f9a80920522a02e08f1f8ad4728d023` |

The GitHub pull-request API returned no PR whose head is `codex/a-cats-r4-a3-compute-cluster`. Therefore A3 is pushed and technically ready, but review/integration has not started through a PR.

## A3 evidence audit

The original routed DCP hash is unchanged:

`F551F4C083279652F3A3F07FD5F08D50730FF77B7D5D0F47E5E81BF8FCDB7B07`.

The original A3 summary used `report_timing_summary -delay_type max`, so it proved setup but displayed hold as `NA`. A4 P0 updated the existing routed-checkpoint validator to request `min_max` and checked the same DCP without synthesis or route repetition. The supplementary result is:

| Gate | Result |
|---|---:|
| WNS | +0.640 ns |
| TNS | 0.000 ns |
| setup failing endpoints | 0 |
| WHS | +0.010 ns |
| THS | 0.000 ns |
| hold failing endpoints | 0 |
| pulse-width worst slack | +2.801 ns |
| route | complete |
| DRC errors | 0 |

The min/max timing report hash is `F19F743A4951135C559836C552C903119960D9610F7D11672A08F161665E8CD8`.

Evidence classes are frozen as follows:

- `tests/run_cats_r4_a3_full_protocol_iverilog.ps1`: full-workload protocol model using FP32 mocks; not vendor-IP arithmetic proof.
- `tests/run_cats_r4_qk_a2_row_pipeline_xsim.ps1`: XSim protocol/formatter regression using `tb_qk_fp32_mocks.sv`; not real vendor-IP arithmetic proof.
- `tests/run_cats_r4_a3_realip_vivado.ps1`: representative real Floating Point Operator XSim and complete A3 routed OOC.
- `reports/host_full_gqa_numerical_20260902.json`: stored full numerical evidence; not bit-exact RTL evidence.

The A3 full-protocol runner previously deleted stdout/stderr in `finally`. It now accepts an optional unique `-OutputRoot` and retains all evidence on pass, failure, and timeout. The two old closeout summaries remain valid counters/results, but their raw logs are unavailable and must not be represented as retained raw evidence.

Local raw artifacts are preserved below the ignored directory `artifacts/local_archive/a3_20260915/`. The tracked hash/index is `artifacts/a3_baseline_20260915/evidence_index.json`. The 66 MB DCP is not committed to Git; it needs a team artifact store or GitHub release asset before another machine can retrieve it.

## Open owner dependencies

| ID | Owner | Required response | Blocks |
|---|---|---|---|
| `A3-INTEGRATION-ACCEPTANCE` | C/lead | accepted integration SHA or review result for A3 | production adoption, final A4 integration |
| `B4-OWNER-ACCEPTANCE` | B/lead | accepted SHA containing `b53902734501738df2a9a467e7907ffe99a11eda`, or explicit owner-boundary exception | production A3/A4 integration |
| `SIN-BF16-IDENTITY` | C/lead | select frozen expected SHA or current actual SHA with provenance | production release identity |
| `A4-CANONICAL-OUTPUT` | C/lead | realizable queue/spool/commit contract that can meet the 2-cluster performance gate | full A4-2 implementation/performance READY |
| `A4-RESOURCE-BUDGET` | C/lead | current C usage/reservation and accepted 2/4-cluster full-board budget | 4-cluster implementation decision |
| `A4-PERFORMANCE-REVIEW` | D | accept timing boundary and 1.6x/fairness calculation | A4 performance sign-off |

These dependencies do not block the A-owned assignment model, interface proposal, reusable runners, or minimal scheduler unit tests. They do block claims of production A4 readiness.

## P0 disposition

- Branch, parent, remote SHAs, interface tag and evidence hashes: complete.
- Setup/hold/route/DRC audit from the same DCP: complete.
- Evidence classification and stale A3 wording correction: complete.
- Raw full-protocol logs: old logs unavailable; runner fixed, selective retained reruns pending.
- Team acceptance/interface decisions: explicitly open above.

