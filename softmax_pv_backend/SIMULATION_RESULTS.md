# Simulation Results

Date: 2026-07-17

Simulator: Icarus Verilog 13.0, SystemVerilog 2012 mode.

## Verified Configurations

| Q heads | KV heads | Seq | Head dim | TILE | Vectors | Result |
|---:|---:|---:|---:|---:|---:|---|
| 4 | 2 | 8 | 8 | 2 | 512 | PASS |
| 4 | 2 | 8 | 8 | 4 | 128 | PASS |
| 32 | 8 | 8 | 8 | 2 | 4096 | PASS |
| 4 | 1 | 128 | 8 | 2 | 131072 | PASS |
| 4 | 1 | 8 | 128 | 2 | 8192 | PASS |
| 4 | 1 | 128 | 128 | 2 | 2097152 | PASS |
| 4 | 1 | 128 | 128 | 4 | 524288 | PASS |
| 32 | 8 | 128 | 128 | 2 | 16777216 | PASS |

Every run checked:

- idle behavior before `start` (`busy=0`, `prob_ready=0`);
- exact P vector contents for every local row;
- repeated P reads across every feature tile;
- exact V vector contents;
- `kv_head = q_head / group_size`;
- scalar C-order V address generation;
- `vec_first`, `vec_last`, head, row, feature and reduce metadata;
- V request backpressure and registered responses;
- V request address and metadata stability while stalled;
- PV output backpressure and vector stability;
- PV output data and all metadata stability while stalled;
- exactly one `done` pulse, asserted only when `busy=0`;
- exact request/output vector counts.

The testbench also injects an invalid first-beat `softmax_last` and requires the
sticky `protocol_error` output to assert.

## B->C Group Integration

`tb_b_to_c_control.sv` adds a separate self-checking integration result:

| Local Q heads | Global KV heads | Seq | Head dim | TILE | Groups | Result |
|---:|---:|---:|---:|---:|---:|---|
| 4 | 8 | 8 | 8 | 2 | 0..7 | PASS |

This test drives causal score rows through the real `softmax_bf16`, uses
`softmax_metadata_tracker` to generate all `prob_*` fields, and consumes the
result with the Group-mode C backend. It checks all 4,096 V requests and PV
vectors. Each request must satisfy:

```text
v_req_kv_head = group_id
v_req_addr = ((group_id * SEQ_LEN + reduce_index) * HEAD_DIM) + feature_base
```

The test explicitly requires V traffic for both Group 0 and Group 7. Group 7's
first V request is checked against the global KV7 base address
`7 * SEQ_LEN * HEAD_DIM`; an accidental local-KV0 access fails the test. It
also asserts that `b_group_id` remains stable from each `b_group_start` through
the corresponding `group_done` pulse.

After same-edge next-request launch was added, the full target run completed at
587266775 ns of simulated time. The previous implementation required
838863575 ns under the same deterministic backpressure, so this testbench's
cycle time fell by about 30.0%. These are behavioral-simulation cycles, not a
post-route KV260 timing measurement. The timeout is derived from vector count,
so large head counts are not rejected by the old fixed 500 ms limit.

## Remaining Tool Evidence

For `32Q/8KV/SEQ128/HD128/TILE2`, elaboration selected `g_group_shift` and
`g_kv_base_shift`, contained no multiply/divide/modulo operator, and produced a
single logical `p_mem[0:255]` with 32-bit words.

Behavioral correctness is verified. Vivado 2025.2 synthesis must still confirm
physical RAMB18 inference, DSP48 count, timing, and connection to a real PV MAC
array.
