# A Member Completion Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create one auditable all-member handoff that records member A's completed A2 work, evidence, readiness boundary, and the next actions for B, C, and D.

**Architecture:** Add a single Markdown handoff using the repository delivery template. Treat Git identities and committed manifests as sources of truth, summarize rather than duplicate large logs, and keep A unit/OOC readiness separate from project production readiness.

**Tech Stack:** Markdown, Git, PowerShell, Icarus Verilog, XSim, Vivado 2025.2

**Spec:** `docs/superpowers/specs/2026-09-10-a-member-completion-handoff-design.md`

## Global Constraints

- Create only `docs/CATS_R4_A_MEMBER_COMPLETION_HANDOFF_2026-09-10.md` as the final deliverable.
- Use exact Git and remote-tracking identities observed at execution time.
- Include every field required by `docs/CATS_R4_DELIVERY_TEMPLATE.md`.
- State A unit/OOC READY and production integration NOT READY separately.
- Do not claim B/C/D acceptance, modify the global release checklist, or authorize a direct merge to `main`.
- Name `codex/cats-r4-local-integration` as the shared integration path.

---

### Task 1: Create and verify the all-member handoff

**Files:**
- Create: `docs/CATS_R4_A_MEMBER_COMPLETION_HANDOFF_2026-09-10.md`
- Read: `docs/CATS_R4_DELIVERY_TEMPLATE.md`
- Read: `docs/CATS_R4_TEAM_RULES_2026-09-08.md`
- Read: `docs/CATS_R4_A2_ROW_HANDOFF_DELIVERY_2026-09-09.md`
- Read: `artifacts/cats_r4_a2_regression_2026-09-10/manifest.json`
- Read: `artifacts/cats_r4_a2_ooc_2026-09-09/manifest.json`
- Read: `artifacts/cats_r4_a2_score_golden_2026-09-10/manifest.json`

**Interfaces:**
- Consumes: immutable Git identities, A2 delivery status, regression/OOC/golden manifests, and repository owner boundaries.
- Produces: a standalone Markdown delivery record consumable by A, B, C, and D.

- [ ] **Step 1: Capture immutable identity and evidence values**

Run:

```powershell
git status --short --branch
git rev-parse HEAD
git rev-parse origin/agent/cats-r4-a2-row-handoff
git rev-parse 'CATS_R4_INTERFACE_V3_COMMIT^{commit}'
Get-Content artifacts/cats_r4_a2_regression_2026-09-10/manifest.json -Raw | ConvertFrom-Json
Get-Content artifacts/cats_r4_a2_ooc_2026-09-09/manifest.json -Raw | ConvertFrom-Json
```

Expected: branch and remote identities are printed; manifests parse without an error. If local HEAD is documentation-only and newer than the technical evidence commit, record both identities explicitly.

- [ ] **Step 2: Write the delivery-template fields and technical summary**

Create the final file with owner A; branch/base/head/interface identities; work/sign-off status; exact file and manifest paths; reproduction commands; Vivado 2025.2 device/clock; numeric mode; expected/actual counters; PASS/FAIL/not-run status; failure seed; known issues; and next dependency.

Record these verified values: `4096` rows, `264192` causal scores, `256` Q slabs, `6144` engine jobs, `2048` legacy equivalence scores, candidate golden length `264192`, and OOC 150 MHz WNS `+1.816 ns` with TNS `0.000 ns`.

- [ ] **Step 3: Add per-member consumption actions**

State that B consumes the frozen row/score contract for Softmax/PV; C reviews and stages the evidence on `codex/cats-r4-local-integration` while continuing memory/DMA/CDC/output/board work; D independently validates the candidate golden and evidence chain; A responds only to A-owned review defects or coordinated interface changes.

- [ ] **Step 4: Validate completeness and consistency**

Run:

```powershell
rg -n "owner|branch|base SHA|head SHA|interface tag|work status|signoff|4096|264192|6144|1.816|member B|member C|member D|codex/cats-r4-local-integration" docs/CATS_R4_A_MEMBER_COMPLETION_HANDOFF_2026-09-10.md
rg -n "T[B]D|T[O]DO|PLACE[H]OLDER" docs/CATS_R4_A_MEMBER_COMPLETION_HANDOFF_2026-09-10.md
git diff --check
```

Expected: the first command finds every required identity, evidence item, and member action; the second finds no matches; the diff check returns no error.

- [ ] **Step 5: Commit the handoff**

Run:

```powershell
git add docs/CATS_R4_A_MEMBER_COMPLETION_HANDOFF_2026-09-10.md
git commit -m "docs(qk): hand off member A completion status"
```

Expected: one documentation commit is created on `agent/cats-r4-a2-row-handoff`; no RTL or generated tool directory is included.
