# A2-to-C handoff document design

Date: 2026-09-09

## Objective

Create two complementary documents that let the C owner review A2 evidence and
start the C-side work without waiting for further explanation from A.

## Deliverables

### 1. A2 factual handoff

File: `docs/CATS_R4_A2_HANDOFF_TO_C_2026-09-09.md`

This document is the auditable source of truth. It will contain:

- A2 owner, branch, base/head commits, and interface baseline;
- actual RTL, testbench, runner, and delivery-document paths;
- frozen A-to-B row and score channels;
- completed simulation and Vivado OOC evidence, counters, timing, utilization,
  tool/part information, and reproducible commands;
- an explicit distinction between A unit/OOC readiness and production
  integration readiness;
- remaining A-owned work, inputs required from C/D, and C-owned integration
  actions;
- restrictions against overwriting B/C-owned files, changing frozen interfaces
  without coordination, or merging directly to `main` before release gates pass.

### 2. Paste-ready C Codex prompt

File: `docs/CATS_R4_C_NEXT_TASK_PROMPT_2026-09-09.md`

This document will contain one self-contained prompt that C can paste into its
Codex task. The prompt will instruct Codex to:

- inspect repository rules and the A2 factual handoff before changing files;
- fetch and review the exact A2 commit rather than relying on screenshots;
- verify the shared interface tag and report any mismatch before integration;
- continue C-owned memory, DMA, CDC, output, board, and tool-build work in
  parallel;
- run the applicable unit, OOC, integration, timing, and DRC checks;
- preserve owner boundaries and use the shared integration branch before
  `main`;
- return a structured result with branch, full SHA, file list, commands, logs,
  report hashes, counters, failures, and READY/NOT READY status.

## Source-of-truth rules

- Only evidence present in the repository or reproduced locally is stated as
  PASS.
- Generated Vivado projects and caches are not committed as source.
- Unknown C/B status is described as awaiting evidence, never inferred.
- The prompt may request actions from C but cannot claim that C has accepted the
  handoff or approved production integration.

## Acceptance criteria

- Both documents are valid Markdown and contain no placeholders.
- Every commit identifier is a full SHA where an exact handoff identity is
  required.
- Commands are copyable PowerShell commands and name their required license
  environment for Vivado 2025.2.
- Responsibilities match `CATS_R4_TEAM_RULES_2026-09-08.md` and gates match
  `CATS_R4_RELEASE_GATE.md`.
- The C prompt can be used without reading this design document.
