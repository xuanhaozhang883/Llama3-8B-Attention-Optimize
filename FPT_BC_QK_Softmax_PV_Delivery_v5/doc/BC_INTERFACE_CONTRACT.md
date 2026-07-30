# B+C Direct Interface Contract

## Processing unit

One accepted launch processes one GQA Group:

```text
4 local Q heads share one global KV/V head
group_id = global KV/V head = 0..7
global_q_head = group_id*4 + local_head
```

An accepted launch is:

```systemverilog
group_start && group_start_ready && group_id < 8
```

`active_group_id` remains locked until the C backend finishes draining the final
P tile.

## Internal B->C connection

The joint top wires these signals directly and exclusively:

| B signal | C signal | Meaning |
|---|---|---|
| `prob_valid` | `prob_valid` | Probability is valid |
| `prob_ready` | `prob_ready` | P buffer can accept the probability |
| `prob_data[15:0]` | `prob_data[15:0]` | BF16 probability |
| `prob_group_id[2:0]` | `prob_group_id[2:0]` | Global KV/V head |
| `prob_head[1:0]` | `prob_head[1:0]` | Local Q head 0..3 |
| `prob_row[6:0]` | `prob_row[6:0]` | Query row |
| `prob_col[6:0]` | `prob_col[6:0]` | Key/reduction column |
| `prob_first` | `prob_first` | `prob_col==0` |
| `prob_last` | `prob_last` | `prob_col==127` |
| `prob_group_last` | `prob_group_last` | Head 3,row 127,col 127 |

All probability fields remain stable while `prob_valid && !prob_ready`.

## V memory interface

```text
v_req_addr = ((group_id*SEQ_LEN + reduce_index)*HEAD_DIM) + feature_base
```

`v_rsp_data[15:0]` is feature `feature_base`; `v_rsp_data[31:16]` is feature
`feature_base+1`.  The interface permits one outstanding, ordered request.

v2 includes `bf16_v_cache.sv`, whose load port uses the same two-lane layout:

```text
v_load_addr = scalar address of feature_base (must be even)
v_load_data[15:0]  = feature_base
v_load_data[31:16] = feature_base+1
```

Memory payload is not reset.  The system loader must write every V word that
the next run may access before asserting start.

## PV input interface

For `PV_TILE=2`:

```text
p_vec_bf16[15:0]  = P[local_head][row_base+0][reduce_index]
p_vec_bf16[31:16] = P[local_head][row_base+1][reduce_index]
v_vec_bf16[15:0]  = V[group_id][reduce_index][feature_base+0]
v_vec_bf16[31:16] = V[group_id][reduce_index][feature_base+1]
```

The schedule is:

```text
local_head -> row_base(step 2) -> feature_base(step 2) -> reduce_index
```

The P tile is replayed for every feature tile.  All vector data and metadata
remain stable while `pv_vec_valid && !pv_vec_ready`.

## Completion semantics

| Signal | Meaning |
|---|---|
| `qk_done` | QK produced the final raw score |
| `prob_input_done` | C accepted the final Softmax probability |
| `done` | C's final PV input vector was accepted and P storage was released |

The future system Attention completion must come from the real PV result path,
not from this loader `done` pulse.

For `qk_softmax_pv_system_top`, one system `start` launches Group 0 through 7.
`group_complete/completed_group_id` report per-Group progress, while system
`done` pulses once after Group 7's loader `done`.
