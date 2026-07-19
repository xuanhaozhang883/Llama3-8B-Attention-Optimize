# v5 Validation Plan

## Required functional order

1. `source run_vivado_v4_quick.tcl`
2. `source run_vivado_v4_all.tcl`
3. `source run_vivado_v4_full_pipeline_optional.tcl`

The quick suite validates modules, reset recovery, selected-group numerical behavior, B->C backpressure stability, sequential groups, busy-start rejection, and global Q/K addressing.

The all suite adds the complete 65,536-output frontend golden test.

The optional full-pipeline test runs a non-zero group through real QK -> Mask -> Row Buffer -> Softmax and checks 65,536 QK scores, 65,536 probabilities, and 512 rows.

## B + C joint validation

1. Use small SEQ_LEN/HEAD_DIM parameters.
2. Deliver the same `group_start/group_id` to B and C.
3. Randomly stall C with `prob_ready=0`.
4. Check all probability fields remain stable while stalled.
5. Check P-buffer contents against the Softmax golden matrix.
6. Check `prob_group_id` selects the expected V/KV head.
7. Check C `prob_input_done` after accepting `prob_group_last`.
8. Check C final `done` after the last PV output.
9. Repeat with `Q_HEADS=4, KV_HEADS=1, SEQ_LEN=128, HEAD_DIM=128`.

## Implementation validation

The v4 Artix-7 report is retained as evidence for the EXP correction. Rerun v5
behavior and synthesis after RTL changes, then rerun on K26/KV260 for final
signoff.
