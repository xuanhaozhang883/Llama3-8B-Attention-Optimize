# RoPE to QK Integration

## Implemented path

```text
raw split-half Q/K pairs
  -> rope_group_prepare
  -> one shared two-stage BF16 rope_pair_pipeline
  -> banked group-local rope_qk_group_cache
  -> existing qk_systolic_gqa_top
  -> existing Mask / Softmax / P buffer / PV loader
```

No arithmetic or scheduling logic in the existing QK, Mask, Softmax or PV
modules was changed.

## Raw-memory contract

A request is transferred on `raw_req_valid && raw_req_ready`. Only one request
is outstanding. The responder returns the matching pair on
`raw_rsp_valid && raw_rsp_ready`:

```text
raw_rsp_x0 = vector[raw_req_pair]
raw_rsp_x1 = vector[raw_req_pair + HEAD_DIM/2]
```

`raw_req_is_k=0` selects a global Q head and `raw_req_is_k=1` selects a global
K head. For Group `g`, request heads are Q `g*4 ... g*4+3`, followed by K `g`.

## Resource behavior

- One RoPE pair datapath is time-shared by all four Q heads and the K head.
- The pair datapath time-shares one Vivado FP multiplier IP and one FP adder
  IP across four multiplies and two add/subtracts. Each multiplication result
  is rounded to BF16 before it enters the adder.
- Each cache bank stores `{rotated_upper, rotated_lower}` in one 32-bit word,
  requiring one write per completed pair.
- Q and K are banked by `token % QK_TILE`; synchronous registered reads are
  used to support BRAM inference and stable output under backpressure.
- The loader intentionally inserts a read bubble between accepted QK vector
  beats. This first version prioritizes BRAM inference and correctness over
  maximum feed bandwidth.

The design intentionally does not instantiate six parallel floating-point IP
blocks. Time-sharing two IP instances reduces DSP use while their AXI-stream
pipelines remove the long custom BF16 combinational path. The existing QK
FP32 MAC/scaler continues to use the same generated Floating-Point IP set.

## Tops

- `rope_qk_softmax_pv_pipeline_top`: one externally selected GQA Group,
  external raw Q/K and V-memory interfaces.
- `rope_qk_softmax_pv_system_top`: one system start, Groups 0 through 7,
  external raw Q/K interface and the existing loadable V cache.

## Verification

`tb_rope_qk_pipeline_small.sv` uses an exact 90-degree rotation:

```text
Q pair (1,2) -> (-2,1)
K pair (3,4) -> (-4,3)
```

With two pairs and scale 1, every QK result is 22 (`BF16 0x41B0`). The test
also verifies Group 7 maps to Q28..Q31/K7, cache vectors, request counts, score
count and the final marker.

Run in Vivado:

```tcl
source run_vivado_rope_qk_small.tcl
```

Generate the persistent synthesis project and reports:

```tcl
source run_synthesis_rope_qk_pipeline.tcl
```

The latter creates:

```text
vivado_synth_rope_qk_pipeline/fpt_bc_ooc_synth.xpr
reports/rope_qk_pipeline_artix7/
```
