# Paste-ready prompt for member C's Codex

Copy the text below into member C's Codex task.

---

You are assisting member C, the CATS-R4 captain and C-side owner. Work from the
repository, not screenshots or chat summaries.

Before changing files, read these documents completely:

- `docs/CATS_R4_TEAM_RULES_2026-09-08.md`
- `docs/CATS_R4_LEAD_ACCEPTANCE_ADDENDUM.md`
- `docs/CATS_R4_RELEASE_GATE.md`
- `docs/CATS_R4_CURRENT_TEAM_BASELINE.md`
- `docs/CATS_R4_A2_HANDOFF_TO_C_2026-09-09.md`

Fetch `origin/agent/cats-r4-a2-row-handoff` and verify technical evidence commit
`051559ef1edf03e7b3aeed9010c1b4c5bfa577a5`. Verify that
`CATS_R4_INTERFACE_V3_COMMIT` resolves to
`4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`. Report any SHA, interface-port,
numeric-mode, token, ownership, or responsibility mismatch before integrating.
Do not infer acceptance from the existence of the branch.

Review A's row/score handoff and its manifests. Independently validate or
replace the candidate full-size golden at
`artifacts/cats_r4_a2_score_golden_2026-09-10/`, then freeze the accepted input,
numeric mode, ordering, hashes, and interface tag. Confirm that B consumes the
same row/score contract.

Continue the work owned by C without waiting for A: memory service, bank
mapping and buffer lifecycle, active-write rejection, Q/KV/weight read service,
DMA and 4 KiB/short-tail handling, CDC and one-sided-reset behavior, output
reorder/writeback, epoch/abort/error propagation, production compute wrapper,
and staged board/tool integration. Run applicable unit and OOC tests first.
Only when dependencies are ready, run 150 MHz elaboration, synthesis,
implementation, timing, and DRC. Verify expected normal counters including
`rd_beats=196608`, `wr_beats=131072`, and `rows_committed=4096`, with conflict,
protocol, error, underflow, and overflow counters equal to zero.

Integrate through `codex/cats-r4-local-integration`, not directly to `main`.
Do not overwrite A- or B-owned files; do not change frozen ports without a
documented minimal coordinated diff; do not force-push a shared branch; do not
edit the production manifest, board top, BD, or constraints without the
captain's explicit integration decision. A unit/OOC READY does not mean the
whole project is production READY.

Return a structured report containing:

1. working branch, base full SHA, head full SHA, dirty/clean state;
2. consumed interface tag and its resolved full SHA;
3. reviewed/cherry-picked A commit(s) and exact file list;
4. C-side files changed, with ownership justification;
5. every command, tool version, FPGA part, and input/report/log SHA-256;
6. expected and actual counters, with PASS, FAIL, or not-run per test;
7. failing seed, first mismatch, and log path for every failure;
8. A unit, B unit, C unit/OOC, and production-integration status separately;
9. known issues, remaining dependency, and the next safe integration action.

Use READY only when the corresponding repository gate has auditable evidence.
Otherwise report NOT READY and state the exact missing evidence.

---
