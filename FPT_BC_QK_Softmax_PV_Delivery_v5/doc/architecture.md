# v4 B + v3 B+C Architecture

## System layer

```text
system start
  -> gqa_group_controller (Group 0..7)
  -> qk_softmax_pv_pipeline_top
  -> bf16_v_cache registered response
  -> p_vec/v_vec valid-ready boundary
```

The V-cache is organized as 65,536 words of two BF16 lanes at the complete
configuration.  Its scalar lane-zero address matches `pv_input_loader`'s
existing `v_req_addr`; shifting right once selects the 32-bit RAM word.

## Group-level chain

```text
group_start + group_id
        |
        v
Q/K loader requests:
req_group_id / req_global_q_head / req_kv_head / row_base / col_base / dim
        |
        v
qk_systolic_gqa_top
        |
        v
causal_mask_stream
        |
        v
score_rowtile_buffer
        |
        v
softmax_bf16
        |
        v
prob_valid/ready + group/local-head/row/col/markers
        |
        v
Responsibility-C P Buffer / PV loader
```

## Global head mapping

For Llama-3.1-8B:

```text
GQA_GROUPS = 8
Q_HEADS_PER_GROUP = 4
KV_HEADS_PER_GROUP = 1

global_q_head = group_id*4 + local_head
global_kv_head = group_id
```

The QK scheduler still operates on local heads 0..3. The outer pipeline shell locks `group_id` and supplies global memory-loader addresses.

## QK output order

For `TILE=4`, each row group is emitted tile-major:

```text
col tile 0: row0 col0..3, row1 col0..3, row2 col0..3, row3 col0..3
col tile 1: row0 col4..7, row1 col4..7, row2 col4..7, row3 col4..7
...
```

Softmax requires complete row-major order:

```text
row0 col0..127
row1 col0..127
row2 col0..127
row3 col0..127
```

The Row Tile Buffer stores `TILE*SEQ_LEN = 512` entries of `{mask, BF16 score}`
in `score_rowtile_payload_bram.sv`.  That helper is an isolated common-clock
simple-dual-port RAM with a registered full-word read.  The parent maintains a
one-entry elastic response so payload and metadata remain stable under stalls.

## B -> C order

For each accepted group:

```text
prob_group_id fixed
local_head 0..3
row 0..127
col 0..127
```

The final accepted element asserts `prob_group_last`, and the same handshake produces B's `group_done`.

## Current throughput structure

The Row Tile Buffer remains single-buffered:

```text
FILL 512 elements -> DRAIN 512 elements -> next row group
```

This is the verified correctness architecture. A later ping-pong implementation can overlap QK fill and Softmax drain.
