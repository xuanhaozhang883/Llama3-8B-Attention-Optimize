# v4 Modification Summary

## RTL changes

### `rtl/integration/qk_softmax_pipeline_top.sv`

- Replaced the group launch boundary with `group_start` and `group_id`.
- Added `group_start_ready` and locked `active_group_id`.
- Added `req_group_id`, `req_global_q_head`, and `req_kv_head` for the external Q/K loader.
- Added the complete B->C output metadata: `prob_group_id`, local head, row, col, first, last, and group-last.
- Added `group_done` for the final accepted probability.
- Added busy-start and invalid-group error flags.
- Retained `prob_global_last` and `pipeline_done` as compatibility aliases.

### `rtl/integration/qk_softmax_frontend.sv`

- Added the semantically correct `prob_group_last` and `group_done` outputs.
- Retained v3 aliases.

### Unchanged compute cores

No algorithm changes were required in:

```text
causal_mask_stream.sv
score_rowtile_buffer.sv
qk_softmax_adapter.sv
softmax_bf16.sv
exp_lut.sv
unsigned_restoring_divider.sv
qk_systolic_gqa_top.sv
qk_systolic_tile.sv
qk_systolic_pe.sv
```

## Verification changes

- Updated the small real-QK-to-Softmax numerical test for a non-zero group ID.
- Added global Q-head/KV-head request checking.
- Added complete B->C output stability checking under backpressure.
- Added `tb_qk_softmax_group_control` for two sequential groups and illegal busy launch rejection.
- Updated the full 65,536-output real-QK-to-Softmax test for group metadata.
- Added v4 quick/all/optional Tcl flows.

## Documentation changes

- Replaced the interface contract with the group-aware v4 contract.
- Added the Responsibility B->C handoff checklist.
- Updated architecture, limitations, test matrix, validation plan, quick start, and merge map.
- Archived old Artix-7 reports as v3 baseline reports.
