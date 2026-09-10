# A2-to-C Handoff Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce an auditable A2 factual handoff and a self-contained prompt that lets C start its review and integration work immediately.

**Architecture:** Keep evidence and instructions separate. The factual handoff records only repository-backed A2 facts at implementation/evidence commit `d06d999a409a68dd89d1e4db8d78d3eb8f5574cb`; the prompt consumes that handoff and tells C's Codex how to verify, integrate, and report without claiming unverified B/C status.

**Tech Stack:** Markdown, Git, PowerShell, Vivado 2025.2, Icarus Verilog, XSim

**Spec:** `docs/superpowers/specs/2026-09-09-a2-to-c-handoff-design.md`

## Global Constraints

- State PASS only for evidence present in the repository or reproduced locally.
- Do not commit generated Vivado projects or caches as source.
- Do not infer acceptance, READY status, or approval from B or C.
- Preserve A/B/C ownership boundaries and the frozen A-to-B interface.
- Use `codex/cats-r4-local-integration` before `main`; production integration remains C/captain-owned.
- Use full commit SHA `d06d999a409a68dd89d1e4db8d78d3eb8f5574cb` as the A2 implementation/evidence anchor.

---

### Task 1: Create the factual A2-to-C handoff

**Files:**
- Create: `docs/CATS_R4_A2_HANDOFF_TO_C_2026-09-09.md`
- Read: `docs/CATS_R4_A2_ROW_HANDOFF_DELIVERY_2026-09-09.md`
- Read: `docs/CATS_R4_TEAM_RULES_2026-09-08.md`
- Read: `docs/CATS_R4_RELEASE_GATE.md`

**Interfaces:**
- Consumes: A2 evidence at commit `d06d999a409a68dd89d1e4db8d78d3eb8f5574cb` and repository role/release rules.
- Produces: a standalone Markdown handoff used as the source of truth by Task 2.

- [ ] **Step 1: Record immutable delivery identity**

Add owner A, branch `agent/cats-r4-a2-row-handoff`, implementation/evidence commit `d06d999a409a68dd89d1e4db8d78d3eb8f5574cb`, base commit `7a36930a83ec716349b3dbc6b0bca2856cce7011`, target integration branch `codex/cats-r4-local-integration`, Vivado `2025.2`, and part `xczu15eg-ffvb1156-2-i`.

- [ ] **Step 2: Record files and frozen channels**

List actual A2 RTL, TB, runner, and delivery-document paths. Spell out the row channel as `valid/ready, epoch[15:0], group[2:0], global_q_head[4:0], row[6:0], slot_id[1:0], numeric_mode[1:0], row_max_bf16[15:0]` and the score channel as the same token plus `key[6:0], score_bf16[15:0], last`.

- [ ] **Step 3: Record verified evidence**

Include full-workload rows `4096`, causal scores `264192`, jobs `6144`, valid MACs `33,816,576`, OOC WNS `+1.816 ns`, TNS `0.000 ns`, CLB LUTs `20,166`, CLB registers `44,983`, DSPs `128`, BRAM `0`, URAM `0`, synthesis errors `0`, and critical warnings `0`. Identify the legacy lane timeout as FAIL/not accepted evidence.

- [ ] **Step 4: Record reproducible commands and responsibilities**

Include the existing A2 test runner commands and this exact license setup before the real-IP OOC command:

```powershell
$env:XILINXD_LICENSE_FILE = 'C:/Software/AMD/lic/25.2/vivado.lic'
$env:LM_LICENSE_FILE = $env:XILINXD_LICENSE_FILE
```

Separate A-owned remaining work, C/D inputs, and C-owned production integration. State that A unit/OOC READY is distinct from production integration READY.

- [ ] **Step 5: Validate the factual handoff**

Run:

```powershell
rg -n "d06d999a409a68dd89d1e4db8d78d3eb8f5574cb|4096|264192|1.816|agent/cats-r4-a2-row-handoff|codex/cats-r4-local-integration" docs/CATS_R4_A2_HANDOFF_TO_C_2026-09-09.md
rg -n "TBD|TODO|PLACEHOLDER" docs/CATS_R4_A2_HANDOFF_TO_C_2026-09-09.md
git diff --check
```

Expected: the first command finds every required identity/evidence item; the second command returns no matches; `git diff --check` returns no errors.

### Task 2: Create the paste-ready C Codex prompt

**Files:**
- Create: `docs/CATS_R4_C_NEXT_TASK_PROMPT_2026-09-09.md`
- Read: `docs/CATS_R4_A2_HANDOFF_TO_C_2026-09-09.md`

**Interfaces:**
- Consumes: the factual handoff produced by Task 1.
- Produces: one complete prompt that C can paste into a Codex task without the design/plan documents.

- [ ] **Step 1: Define C's starting context and mandatory reads**

Tell C's Codex to inspect the team rules, release gate, A2 factual handoff, and exact remote commit before changing files. Require it to report any interface-tag or ownership mismatch before integration.

- [ ] **Step 2: Define C's parallel work and safety boundaries**

Request C-owned memory-service, banking, DMA, CDC, output, board, and tool-build work; A2 review; interface/golden freeze; and staged shared-branch integration. Forbid overwriting A/B-owned files, changing frozen ports without a documented minimal diff, force-pushing shared branches, or merging `main` before release gates pass.

- [ ] **Step 3: Define required verification and response schema**

Require unit/OOC/integration checks applicable to C, followed by 150 MHz synthesis, implementation, timing, and DRC only when dependencies are ready. Require the response to contain branch, base/head full SHA, consumed interface tag, file list, commands, tool/part, input/report hashes, expected/actual counters, PASS/FAIL/not-run status, failing seeds/logs, known issues, and the next dependency.

- [ ] **Step 4: Validate prompt completeness and consistency**

Run:

```powershell
rg -n "d06d999a409a68dd89d1e4db8d78d3eb8f5574cb|CATS_R4_TEAM_RULES|CATS_R4_RELEASE_GATE|codex/cats-r4-local-integration|READY|NOT READY|SHA" docs/CATS_R4_C_NEXT_TASK_PROMPT_2026-09-09.md
rg -n "TBD|TODO|PLACEHOLDER" docs/CATS_R4_C_NEXT_TASK_PROMPT_2026-09-09.md
git diff --check
```

Expected: the first command finds every mandatory control item; the second command returns no matches; `git diff --check` returns no errors.

### Task 3: Review, commit, and publish the handoff package

**Files:**
- Review: `docs/CATS_R4_A2_HANDOFF_TO_C_2026-09-09.md`
- Review: `docs/CATS_R4_C_NEXT_TASK_PROMPT_2026-09-09.md`

**Interfaces:**
- Consumes: both validated Markdown deliverables.
- Produces: a traceable GitHub checkpoint on `agent/cats-r4-a2-row-handoff`.

- [ ] **Step 1: Check scope and repository state**

Run:

```powershell
git diff --check
git status --short --branch
git diff --stat
```

Expected: only the two requested handoff documents and this approved plan are in scope; no generated Vivado directory is staged.

- [ ] **Step 2: Commit the two deliverables**

Run:

```powershell
git add docs/CATS_R4_A2_HANDOFF_TO_C_2026-09-09.md docs/CATS_R4_C_NEXT_TASK_PROMPT_2026-09-09.md
git commit -m "docs(qk): hand off A2 evidence and C integration prompt"
```

Expected: Git creates one documentation commit on `agent/cats-r4-a2-row-handoff`.

- [ ] **Step 3: Push and verify remote identity**

Run:

```powershell
git push origin agent/cats-r4-a2-row-handoff
git rev-parse HEAD
git rev-parse origin/agent/cats-r4-a2-row-handoff
```

Expected: push succeeds and the two printed full SHAs are identical.
