# v4 Interface Contract

## 1. Processing granularity

One `group_start` processes exactly one GQA group:

```text
1 group = 4 local Q heads + 1 KV head
GQA groups = 8
local_head = 0..3
group_id = 0..7
global_q_head = group_id * 4 + local_head
global_kv_head = group_id
```

The same `group_start` and `group_id` must be delivered to Responsibility B and Responsibility C.

## 2. Group launch interface

| Signal | Direction | Meaning |
|---|---|---|
| `group_start` | in | One-cycle launch pulse for one GQA group |
| `group_id[2:0]` | in | Group / global KV-head number, 0..7 |
| `group_start_ready` | out | B is idle and can accept a launch |
| `active_group_id[2:0]` | out | Group ID locked for the active launch |
| `group_done` | out | Last Softmax probability of this group completed `valid&&ready` |
| `start_while_busy_error` | out | A launch was attempted while B was busy |
| `invalid_group_id_error` | out | Launch used a group ID outside `GQA_GROUPS` |

A launch is accepted only when:

```systemverilog
group_start && group_start_ready
```

`group_id` is locked on the accepted launch and remains unchanged until the group completes.

## 3. Q/K loader requests

| Signal | Meaning |
|---|---|
| `req_head[1:0]` | Local Q head inside the active group |
| `req_group_id[2:0]` | Active GQA group |
| `req_global_q_head[4:0]` | `group_id*4 + req_head`, range 0..31 |
| `req_kv_head[2:0]` | Global KV head, equal to `group_id` |
| `req_row_base[6:0]` | Query row-tile base |
| `req_col_base[6:0]` | Key column-tile base |
| `req_dim[6:0]` | Reduction dimension |
| `vec_valid/vec_ready` | Q/K vector-beat handshake |

The Q loader should index Q by `req_global_q_head`; the K loader should index K by `req_kv_head`.

## 4. QK -> Adapter

The internal stream remains local to one group:

```text
local_head -> row_tile -> col_tile -> local_row -> local_col
```

`qk_global_last` is retained internally for v3 compatibility, but semantically it means the final score of the active group.

## 5. B -> C Softmax probability interface

```systemverilog
output logic        prob_valid;
input  logic        prob_ready;
output logic [15:0] prob_data;
output logic [2:0]  prob_group_id;
output logic [1:0]  prob_head;
output logic [6:0]  prob_row;
output logic [6:0]  prob_col;
output logic        prob_first;
output logic        prob_last;
output logic        prob_group_last;
```

Order for one accepted group:

```text
local_head 0..3 -> row 0..127 -> col 0..127
```

A transfer occurs only on:

```systemverilog
prob_fire = prob_valid && prob_ready;
```

When `prob_valid=1` and `prob_ready=0`, every probability field must remain stable.

Marker definitions:

```systemverilog
prob_first      == (prob_col == 0)
prob_last       == (prob_col == 127)
prob_group_last == (prob_head == 3 && prob_row == 127 && prob_col == 127)
```

`prob_global_last` is retained as a compatibility alias of `prob_group_last`.
`pipeline_done` is retained as a compatibility alias of `group_done`.

## 6. Completion semantics

- `qk_done`: QK has finished the active group's score stream.
- `group_done` / `pipeline_done`: C accepted the active group's final Softmax probability.
- Responsibility C `done`: the active group's final PV vector/result completed.
- The overall Attention controller must use C's final completion, not B's `qk_done` or `group_done`.

## 7. Error signals

- `adapter_protocol_error`: illegal QK tile/head/row/col order.
- `adapter_global_last_error`: QK final-marker coordinate mismatch.
- `softmax_metadata_error`: non-contiguous row metadata or invalid row ending.
- `softmax_row_error`: all elements of a row were masked.
- `start_while_busy_error`: illegal overlapping group launch.
- `invalid_group_id_error`: out-of-range group launch.
