# Llama Attention FPGA

FPGA implementation of the Llama3-style GQA attention core for the XCZU15EG-FFVB1156-2-I.

The implemented scope reads precomputed Q/K/V from DDR and executes RoPE, QK, causal masking, online Softmax/context fusion, and BF16 Context writeback. It is not a complete Llama3-8B inference system: embeddings, projections, RMSNorm, MLP, residuals, KV-cache orchestration, LM head, and token sampling are outside the current design.

Chinese documentation: [README_CN.md](README_CN.md)

## Current status

- v3.1.4 is the stable board-tested fallback. The recorded result is 303.120724 ms at 150 MHz, with 10/10 correct and deterministic runs.
- The numerical gate passes the project tolerance but is not bit-exact.
- CATS-R4 is in unit development. Its interface is frozen for development, but A/B/C units, the compute wrapper, and the new full-board build are not yet release-ready.
- Predicted CATS-R4 latency ranges are targets, not measured hardware results.

See:

- [WORKSPACE_STATUS.md](WORKSPACE_STATUS.md) for the v3.1.4 evidence baseline;
- [docs/CATS_R4_NEXT_WORK_PLAN_2026-09-09.md](docs/CATS_R4_NEXT_WORK_PLAN_2026-09-09.md) for the current execution plan;
- [docs/CANONICAL_REPOSITORY_PATHS.md](docs/CANONICAL_REPOSITORY_PATHS.md) for authoritative paths and cleanup rules;
- [docs/CATS_R4_RELEASE_GATE.md](docs/CATS_R4_RELEASE_GATE.md) for release gates.

## Authoritative paths

| Purpose | Path |
|---|---|
| Project configuration | project_config.json |
| Production source manifest | scripts/source_manifest.tcl |
| Board top | rtl/board/attention_board_top.sv |
| Canonical numerical model | python/flash_attention_tile_model.py |
| Numerical regression | tests/run_v31_flash_numerical_model.ps1 |
| Frozen Q/K/V and expected Context | vitis/data/ |
| Derived bare-metal header | vitis/src/fpt_golden_vectors.h |
| Production ROMs | mem/ |
| Bare-metal application | vitis/src/fpt_attention_board_test.c |
| Board-log signoff | python/signoff_v31_board_log.py |

The scripts and JSON files under docs/architecture_study_20260905 are historical architecture-study evidence. They are not additional release golden models.

## Repository layout

| Directory | Responsibility |
|---|---|
| rtl/board | AXI/DDR and board-level integration |
| rtl/core | Attention datapath and CATS-R4 candidates |
| tb | RTL testbenches |
| tests | Reproducible regression entry points |
| scripts | Vivado/Vitis builds, constraints, and source manifest |
| python | Numerical model and verification utilities |
| vitis/data | Frozen BF16 board vectors |
| vitis/src | Bare-metal application and derived vector header |
| mem | Production lookup tables |
| reports | Structured report summaries |
| export | Manifest-controlled hardware exports |
| artifacts | Artifact manifests and append-only raw evidence |
| docs | Current policies, gates, handoffs, and historical evidence |

Generated Vivado/Vitis workspaces, caches, root-level ROM copies, and workspace ZIP backups must not be committed.

## Basic checks

From PowerShell:

    python tests/check_repository_hygiene.py
    python tests/check_cats_r4_lead_release.py
    python tests/test_cats_r4_v3_capacity.py
    python tests/check_cats_r4_gate_manifest.py
    powershell -ExecutionPolicy Bypass -File tests/run_v313_qk4_system_checks.ps1

The repository-hygiene check verifies canonical paths, rejects duplicated/generated tracked sources, and confirms that the bare-metal golden header is byte-identical to a fresh generation from vitis/data.

## Build

Vivado and Vitis 2025.2 are required:

    01_check_rtl.bat
    02_build_bitstream.bat
    03_build_vitis.bat

03_build_vitis.bat regenerates vitis/src/fpt_golden_vectors.h from the canonical vitis/data vectors before creating the application.

Formal board results require a matching Git commit, BIT/XSA/ELF hashes, build ID, input hashes, raw UART log, one warm-up run, and ten measured runs. Do not reuse an old XSA, BSP, ELF, or report as evidence for changed RTL.

## Change discipline

1. Keep each architecture, numeric, frequency, or cluster-count change in a separate commit.
2. Run direct unit tests, randomized latency/backpressure tests, one system regression, and git diff --check.
3. Preserve failure seeds and raw logs.
4. Label evidence as software, RTL simulation, OOC synthesis, post-route, or board measurement.
5. Do not move a frozen interface tag or force-push a shared branch.

## License

This repository is for research and educational use.
