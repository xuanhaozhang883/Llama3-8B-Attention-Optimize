# Repository Merge Map

## Responsibility-B core

```text
rtl/adapter/causal_mask_stream.sv
rtl/adapter/score_rowtile_buffer.sv
rtl/adapter/qk_softmax_adapter.sv
rtl/softmax/softmax_bf16.sv
rtl/softmax/exp_lut.sv
rtl/softmax/exp_lut_q15.mem
rtl/softmax/unsigned_restoring_divider.sv
rtl/integration/qk_softmax_frontend.sv
rtl/integration/qk_softmax_pipeline_top.sv
```

The existing QK files remain under the team QK/PV directory or can be copied from `rtl/qk/`.

## Recommended B + C integration boundary

Use `qk_softmax_pipeline_top.sv` as B's exported shell and connect its complete `prob_*` interface to C's `softmax_output_buffer`.

B and C must share:

```text
group_start
group_id[2:0]
```

C should not infer the global KV head from local `prob_head`; it must use `prob_group_id`.

See `doc/B_TO_C_HANDOFF.md` for the exact connection list.
