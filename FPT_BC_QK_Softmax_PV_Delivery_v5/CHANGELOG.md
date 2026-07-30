# Changelog

## B+C Delivery v5

- Analyzed the v4 50-path report: all remaining worst paths traverse Softmax
  score read, EXP address/decode, and `sum_exp` accumulation in one cycle.
- Split EXP processing into registered score-read, address, LUT, and
  accumulation states while retaining `ST_EXP` as enum value 1 for reset tests.
- Replaced the 32-bit EXP address integer with `SCORE_W+1` arithmetic and
  removed the mathematically redundant address clamp.
- Added exhaustive address-equivalence and structural pipeline auditing.
- Bundled the user-provided v4 behavior and synthesis timing evidence.
- Recorded the v4 improvement to WNS `-5.643 ns`, TNS `-239.439 ns`, and 58
  failing endpoints; a new Vivado rerun remains required for v5 signoff.

## B+C Delivery v4

- Replaced the Softmax BF16-to-Q9.14 converter's 64-bit variable-shift and
  saturation datapath with an equivalent width-bounded implementation.
- Added raw-BF16 and converted-fixed elastic stages between the Row Tile Buffer
  BRAM and the running maximum comparison.
- Split probability generation into registered multiply, round and BF16-
  encoding stages.
- Added exhaustive equivalence checking for all 65,536 BF16 encodings.
- Added a 50-path post-synthesis timing report for follow-up timing closure.
- Recorded the v3 Artix-7 failure evidence: WNS `-9.695 ns`, with the worst
  `19.316 ns` path located in Softmax input conversion/max comparison.

## B+C Delivery v3

- Replaced the Row Tile Buffer's FSM-embedded array access with a dedicated
  common-clock simple-dual-port BRAM module.
- Added an explicit one-entry elastic read response so the registered BRAM
  output and row/head/column metadata remain aligned under backpressure.
- Added a fast `run_synthesis_row_buffer.tcl` audit that requires exactly one
  RAMB primitive before the complete B+C synthesis is attempted.
- Retained all v2 B+C, V-cache, robustness and Group 0..7 interfaces.

## B+C Delivery v2

- Fixed the packaged XSim completion-counter sampling point.
- Added a synthesizable vectorized BF16 V-cache.
- Added a reference Group 0..7 launcher and combined system wrapper.
- Added illegal-ID, busy-start and three-point reset-recovery tests.
- Added an all-Group test that preloads and reads the real V-cache.
- Reworked synthesis as 100 MHz OOC structural/resource audits.
- Added latch, MDRV-1, Row/P/V BRAM and EXP-LUT checks.
- Added a full-V-cache `xc7a100t` provisional synthesis target.
- Added static v2 contract auditing and section-five completion mapping.
- Fixed Vivado 2019.2 OOC-property parsing with dictionary-form assignment.
- Attempted to improve Row Tile Buffer inference with one whole-word
  synchronous RAM read; v3 replaces this with the stricter dedicated template.
- Switched floating-point IPs to global top-level synthesis and reject any
  unresolved synthesis black boxes before reporting resource/timing PASS.
- Split P Buffer storage by 16-bit lane to eliminate the 26-RAMB18 expansion
  caused by variable part-select writes in Vivado 2019.2.
- Added a provisional Artix-7 OOC `HD.CLK_SRC` constraint for clock-skew
  estimation; the KV260 top must replace it with its actual clock source.

## B+C Delivery v1

- Directly connected B's `prob_*` stream to C's generic
  `softmax_pv_backend` without adding a second Softmax.
- Fixed the formal C configuration to `Q_HEADS=4`, `V_KV_HEADS=8`,
  `USE_GROUP_ID_FOR_KV=1`, and `PV_TILE=2`.
- Added `qk_softmax_pv_pipeline_top` as the single-Group joint shell.
- Added locked Group metadata through the complete C drain interval.
- Added global-Q-head metadata on the PV input stream.
- Added read-only B->C probability monitor ports for D-side verification.
- Distinguished `prob_input_done` from final PV-loader `done`.
- Added combined protocol/error reporting and illegal-start/ID rejection.
- Added a self-checking joint test for Groups 0 and 7 with V/PV stalls.
- Added an optional full-size Group-6 joint test configuration.
- Added Vivado 2019.2 TCL entry points and A/D handoff documentation.

## v4

- Added one-group-per-launch control with `group_start`, `group_id`, and `group_start_ready`.
- Added locked `active_group_id` for the complete active transaction.
- Added Q/K loader metadata: `req_group_id`, `req_global_q_head`, and `req_kv_head`.
- Added complete B -> C metadata: `prob_group_id`, local head, row, col, first, last, and group-last.
- Renamed the semantic final marker to `prob_group_last`.
- Added `group_done`, meaning the final probability completed `valid&&ready`.
- Retained `prob_global_last` and `pipeline_done` as v3 compatibility aliases.
- Added `start_while_busy_error` and `invalid_group_id_error`.
- Extended the small numerical pipeline test to use a non-zero selected group and to check Q/K global addressing.
- Added `tb_qk_softmax_group_control` for sequential groups, busy-start rejection, ID locking, and addressing.
- Extended the full 65,536-output real-QK-to-Softmax test to validate group metadata.
- Added a formal B -> C handoff checklist and updated all interface documentation.
- Added v4 Vivado scripts; legacy v3 wrappers redirect to v4.
- Removed stale generated Vivado project directories from the deliverable.

## v3

- Added real QK RTL, Adapter/Softmax integration, complete golden tests, reset recovery, strict ordering checks, and synthesis/report scripts.
