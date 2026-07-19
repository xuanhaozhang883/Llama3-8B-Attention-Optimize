# Softmax to PV Backend

This folder bridges the row-stream output of Softmax to the vector input of a
TILE x TILE Probability x V engine.

## Structure

```text
softmax_pv_backend/
├── constraints/
│   └── kv260_ooc_200mhz.xdc
├── rtl/
│   ├── softmax_metadata_tracker.sv
│   ├── softmax_output_buffer.sv
│   ├── pv_input_loader.sv
│   ├── softmax_pv_backend.sv
│   ├── b_to_c_control.sv
│   └── softmax_pv_backend_kv260_ooc.sv
├── tb/
│   ├── tb_softmax_pv_backend.sv
│   └── tb_b_to_c_control.sv
├── README.md
└── SIMULATION_RESULTS.md
```

## Two Operating Modes

`softmax_pv_backend` remains a reusable C backend. Its default mode maps a
local Q head to a local KV head with `kv_head = q_head / group_size`, which is
useful for the 32Q/8KV OOC resource wrapper.

The formal Llama3 B->C integration uses `b_to_c_control` instead:

```text
one group = 4 local Q heads + one global KV head
group_id = 0..7
global_q_head = group_id * 4 + local_head
global_kv_head = group_id
```

It sends the same one-clock `group_start` to the metadata tracker and C
backend. Both latch `group_id`; the C backend then requests V from that global
KV head for the whole group. This prevents Groups 1..7 from accidentally
reading V0.

## Required PV Vectors

For one output tile and one reduction beat:

```text
p_vec[i] = P[q_head][row_base+i][reduce_index]
v_vec[j] = V[kv_head][reduce_index][feature_base+j]

standalone/OOC: kv_head = q_head / group_size
formal Group mode: kv_head = group_id
```

Packing is little-lane-first inside the RTL bus:

```text
p_vec_bf16[i*16 +: 16] = p_vec[i]
v_vec_bf16[j*16 +: 16] = v_vec[j]
```

## Scheduling

The loader uses this fixed schedule:

```text
for q_head:
  for row_base in steps of TILE:
    keep TILE complete P rows in the P buffer
    for feature_base in steps of TILE:
      for reduce_index in 0..SEQ_LEN-1:
        read the same P row tile at reduce_index
        request V[kv_head][reduce_index][feature_base : feature_base+TILE]
        send one atomic P/V vector pair to PV
```

This is the required P replay: after one feature tile finishes, `reduce_index`
returns to zero and the same P rows are read again for the next V feature tile.
The P bank is released only after all `HEAD_DIM/TILE` feature tiles finish.

## Formal Softmax-to-C Interface

| Port | Connection | Meaning |
|---|---|---|
| `prob_valid` / `prob_ready` | ready/valid | probability beat handshake |
| `prob_data` | Softmax `out_data` | BF16 probability |
| `prob_group_id` | tracker output | group number 0..7 |
| `prob_head` / `prob_row` / `prob_col` | tracker output | local Q head and row-major P coordinate |
| `prob_first` / `prob_last` | tracker output | first/final K column of one P row |
| `prob_group_last` | tracker output | final element of local head 3, row 127, col 127 |

`softmax_bf16` itself emits only `out_valid/out_ready/out_data/out_last`.
`softmax_metadata_tracker` sits around the real Softmax: it accepts the B-side
score row stream, stores the completed row's `group_id/head/row`, and then
creates `prob_col/first/last/group_last` as each probability beat is accepted.
The current Softmax completes one row before accepting the next, so one metadata
entry is sufficient. `softmax_output_buffer` checks every `prob_*` coordinate;
a missing, stale, interleaved, or wrongly ordered beat raises `protocol_error`.

All `prob_*` fields must stay stable while `prob_valid=1 && prob_ready=0`.

## Interface for the PV/Top Owner

The four primary signals requested by the top owner are:

```systemverilog
output logic [TILE*16-1:0] p_vec_bf16;
output logic [TILE*16-1:0] v_vec_bf16;
output logic               vec_valid;
input  logic               vec_ready;
```

The pair is atomic: both vectors and all metadata remain stable while
`vec_valid=1 && vec_ready=0`.

Additional control/metadata is provided so a PV array can clear, accumulate and
place its output correctly:

```text
vec_first          reduce_index == 0, clear/start this PV tile
vec_last           reduce_index == SEQ_LEN-1, final accumulation beat
vec_head           Q head
vec_row_base       first Q row in the TILE-row output block
vec_feature_base   first output feature in the TILE-column block
vec_reduce_index   current K token/reduction index
```

## V Memory Request Interface

`pv_input_loader` supports one outstanding V request:

```text
v_req_valid / v_req_ready
v_req_kv_head
v_req_reduce_index
v_req_feature_base
v_req_addr

v_rsp_valid / v_rsp_ready
v_rsp_data[TILE*16-1:0]
```

`v_req_addr` is the scalar BF16 index of the first requested feature in C-order:

```text
v_req_addr = ((kv_head * SEQ_LEN + reduce_index) * HEAD_DIM)
           + feature_base
```

The memory adapter must return TILE consecutive BF16 values packed lane-first.
P and V responses may arrive on different cycles; the loader stores both and
asserts `vec_valid` only after both are present.

When PV accepts a vector and another reduction/feature vector remains in the
same P tile, the loader launches that next P/V request on the same clock edge.
It still permits only one outstanding request and requires ordered responses;
no response FIFO or tag is added.

## Buffer and Control

- The P buffer has two banks and stores `2*TILE*SEQ_LEN*16` bits.
- At `SEQ_LEN=128`, this is 8192 bits for TILE=2 or 16384 bits for TILE=4.
- `start` is a one-cycle pulse issued while idle to begin a new matrix. Before
  `start`, `busy=0` and `prob_ready=0`, so stale probability beats cannot be
  accepted accidentally.
- `done` pulses after the final vector is accepted and its P bank is released.
- `protocol_error` is sticky until reset/start and detects malformed row endings,
  invalid metadata/order, early responses and invalid bank release.
- `SEQ_LEN` and `HEAD_DIM` must be divisible by power-of-two `TILE`.

## `b_to_c_control` Top-Level Contract

This is the integration point for the owner of the QK->Softmax frontend.
Its B-side input is the existing row-major score stream:

```text
row_valid / row_ready
row_head / row_index
row_data / row_mask / row_last
```

When its external `start` is accepted, it automatically executes eight groups
in order. It exposes the corresponding upstream launch signals:

```text
b_group_start     one clock for every Group
b_group_id         stable Group number 0..7
```

For each group, `group_done` pulses after both the real Softmax/metadata path
and the C/PV vector path complete. At the end of the eighth group, `done`
pulses, `groups_completed` is eight, and `group_error[7:0]` reports the
per-Group result. Top-level `protocol_error` also remains asserted if any
completed group failed.

## Vivado 2025.2 GUI Simulation

For the standalone C backend test, add these files as Design Sources:

```text
softmax_pv_backend/rtl/softmax_output_buffer.sv
softmax_pv_backend/rtl/pv_input_loader.sv
softmax_pv_backend/rtl/softmax_pv_backend.sv
```

Add `softmax_pv_backend/tb/tb_softmax_pv_backend.sv` as a Simulation Source and
set `tb_softmax_pv_backend` as simulation top. Run Behavioral Simulation. The
default test checks two KV heads, GQA mapping, V addresses, P replay, V contents,
vector metadata, input/output backpressure, stall stability and malformed
metadata detection.

For the formal B->C integration test, additionally add:

```text
softmax_pv_backend/rtl/softmax_metadata_tracker.sv
softmax_pv_backend/rtl/b_to_c_control.sv
softmax_module/rtl/exp_lut.sv
softmax_module/rtl/unsigned_restoring_divider.sv
softmax_module/rtl/softmax_bf16.sv
```

Set `tb_b_to_c_control` as the simulation top, and run from the repository
root so `softmax_module/rtl/exp_lut_q15.mem` resolves. The test uses small
`SEQ_LEN=8` and `HEAD_DIM=8`, but the real `4Q/8KV` group topology. It feeds
causal score rows through the actual Softmax and checks all eight groups, every
global-V address, returned V vectors, eight completion pulses, and aggregate
error status. In particular, Group 7 must start at global V address
`7 * SEQ_LEN * HEAD_DIM`.

The backend finishes at the PV vector input. A real PV MAC array is not yet in
the repository, so current tests use a self-checking ready/valid PV sink.

## KV260 OOC Synthesis

For a reproducible module resource check in Vivado 2025.2, add
`softmax_output_buffer.sv`, `pv_input_loader.sv`, `softmax_pv_backend.sv`, and
`softmax_pv_backend_kv260_ooc.sv` as Design Sources and add
`constraints/kv260_ooc_200mhz.xdc` as a Constraint Source. Set
`softmax_pv_backend_kv260_ooc` as the synthesis top, select the KV260 board (or
`XCK26-SFVC784-2LV-C` for OOC only), and run synthesis.

Check the hierarchical utilization for one logical 256x32-bit P RAM, no DSP in
the address/control path, and the timing summary at 5 ns. This wrapper is only a
resource probe; do not use it as the final board-level `attention_top`.
