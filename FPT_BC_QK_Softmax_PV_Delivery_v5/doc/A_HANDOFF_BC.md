# Handoff to Responsibility A

Instantiate only:

```text
qk_softmax_pv_pipeline_top
```

Do not separately instantiate B's `qk_softmax_pipeline_top` or C's
`softmax_pv_backend`, because the joint shell already owns both.

## Launch

1. Wait for `group_start_ready==1`.
2. Drive `group_id` and assert `group_start` for exactly one clock.
3. Keep Q/K loader and V-memory response interfaces operational.
4. Wait for `done` before launching the next Group.

The controller iterates Group 0 through Group 7.  Do not launch the next Group
at `prob_input_done`; C may still be replaying P and delivering PV vectors.

## External interfaces A must connect

- Q/K vector-loader request and response ports.
- V-memory `v_req_*` and `v_rsp_*` ports.
- PV input `p_vec_bf16`, `v_vec_bf16`, `pv_vec_valid/ready` and metadata.
- Start, busy, done and error ports.

The `mon_prob_*` ports are optional read-only verification taps.  They must not
be used to create a second ready path.

## PV metadata

`pv_vec_head` is local 0..3.  `pv_vec_global_q_head` is already calculated as
`active_group_id*4 + pv_vec_head` and should be used to place the future PV
result into the global Q-head output array.

## Error policy

Any asserted `protocol_error` invalidates the current Group.  A should stop or
reset/retry rather than consuming the Group result.

## v2 reference controller

`rtl/integration/gqa_group_controller.sv` is supplied as a directly usable
reference for A.  It issues Group 0 through Group 7, waits for the C-side
`done` of each Group, and emits one final `done`.  The combined wrapper is
`qk_softmax_pv_system_top.sv`.

A may instantiate that wrapper or copy its policy into the final
`attention_controller.sv`.  Once the real PV MAC is connected, the final
Attention `done` must use PV-result completion; current B+C `done` means only
that the last PV input vector was accepted.
