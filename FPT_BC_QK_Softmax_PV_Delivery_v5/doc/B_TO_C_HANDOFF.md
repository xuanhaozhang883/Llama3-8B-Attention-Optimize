# Responsibility B -> C Handoff Checklist

## Files from B

Core files:

```text
rtl/integration/qk_softmax_pipeline_top.sv
rtl/integration/qk_softmax_frontend.sv
rtl/adapter/qk_softmax_adapter.sv
rtl/adapter/causal_mask_stream.sv
rtl/adapter/score_rowtile_buffer.sv
rtl/softmax/softmax_bf16.sv
rtl/softmax/exp_lut.sv
rtl/softmax/exp_lut_q15.mem
rtl/softmax/unsigned_restoring_divider.sv
```

Interface and verification:

```text
doc/interface_contract.md
tb/tb_qk_softmax_pipeline_small.sv
tb/tb_qk_softmax_group_control.sv
tb/tb_qk_softmax_pipeline_full_optional.sv
```

## Signals C must receive

```systemverilog
prob_valid
prob_ready
prob_data[15:0]
prob_group_id[2:0]
prob_head[1:0]
prob_row[6:0]
prob_col[6:0]
prob_first
prob_last
prob_group_last
```

## Shared launch signals

B and C receive the same:

```systemverilog
group_start
group_id[2:0]
```

The launcher must assert `group_start` for one cycle only when both sides are idle/ready.

## C-side required behavior

1. Receive only on `prob_valid && prob_ready`.
2. Pull `prob_ready` low whenever the P buffer cannot accept data.
3. Check all metadata and row/group markers.
4. Lock `group_id` at launch and verify it equals `prob_group_id`.
5. Use `prob_group_id` as the global KV/V head number.
6. Generate `prob_input_done` after accepting `prob_group_last`.
7. Keep C `done` for the final PV completion, not probability-input completion.

## Direct signal mapping

```systemverilog
c.prob_valid      <- b.prob_valid
b.prob_ready      <- c.prob_ready
c.prob_data       <- b.prob_data
c.prob_group_id   <- b.prob_group_id
c.prob_head       <- b.prob_head
c.prob_row        <- b.prob_row
c.prob_col        <- b.prob_col
c.prob_first      <- b.prob_first
c.prob_last       <- b.prob_last
c.prob_group_last <- b.prob_group_last
```

## First joint test

Use small parameters first, then the full group:

```text
small: Q_HEADS=2 or 4, SEQ_LEN=8, HEAD_DIM=8
full : Q_HEADS=4, KV_HEADS=1, SEQ_LEN=128, HEAD_DIM=128
```

Check probability count, P-buffer contents, backpressure stability, metadata, V-head selection, PV loader output, and C final `done`.
