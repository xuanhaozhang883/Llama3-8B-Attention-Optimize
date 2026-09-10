# A member completion handoff design

Date: 2026-09-10

## Objective

Create one concise, auditable handoff document for all CATS-R4 members that
states member A's current completion status and tells B, C, and D how to consume
the delivery.

## Deliverable

File: `docs/CATS_R4_A_MEMBER_COMPLETION_HANDOFF_2026-09-10.md`

The document will follow `docs/CATS_R4_DELIVERY_TEMPLATE.md` and include:

- member A as owner, the feature branch, base/head full SHA, and resolved
  `CATS_R4_INTERFACE_V3_COMMIT` identity;
- work status and sign-off as separate fields;
- completed A2 RTL scope and frozen row/score handoff contract;
- reproducible test commands, Vivado version/device/clock, numerical mode,
  full-workload counters, OOC timing/utilization, and evidence manifests;
- an explicit distinction between A unit/OOC READY and production-integration
  NOT READY;
- remaining B-, C-, and D-owned actions and the shared integration path;
- known limitations, including that the full-size score golden is still a
  candidate pending independent C/D freeze.

## Source-of-truth rules

- Use only repository-backed evidence and the current remote branch identity.
- Keep detailed implementation material in existing A2 delivery and evidence
  manifests; link to them instead of duplicating every log hash.
- Do not claim B/C/D acceptance or project-level readiness.
- Do not authorize a direct merge to `main`; name
  `codex/cats-r4-local-integration` as the next integration branch.
- Do not modify the global release checklist in this documentation-only task.

## Acceptance criteria

- The handoff is understandable without prior chat context.
- All mandatory delivery-template fields are present.
- Exact branch and full SHA identities match Git and the remote tracking ref.
- Key evidence includes 4096 rows, 264192 causal scores, 6144 jobs, Vivado
  2025.2 OOC at 150 MHz, and the corresponding repository paths.
- B, C, and D each have an explicit next action.
- The file contains no unresolved markers or placeholder text and passes
  `git diff --check`.
