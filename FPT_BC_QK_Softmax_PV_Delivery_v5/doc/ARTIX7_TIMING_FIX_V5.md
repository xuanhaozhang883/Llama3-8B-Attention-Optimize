# Artix-7 100 MHz Timing Fix — EXP Pipeline (B+C Delivery v5)

## Evidence from the v4 rerun

The v4 behavioral regression completed with all 13 expected PASS messages.
Its formal B+C OOC synthesis also retained the required structure:

```text
latch cells = 0
black-box cells = 0
Row/P/V-cache RAMB counts = 1/2/0
```

The first timing correction improved setup timing from the v3 result of
`WNS=-9.695 ns, TNS=-1200.289 ns, 182 failing endpoints` to:

```text
WNS = -5.643 ns
TNS = -239.439 ns
failing endpoints = 58
```

The remaining worst path was `15.495 ns`, with `6.274 ns` logic and `9.221 ns`
routing across 25 logic levels.  All 50 paths in the supplied critical-path
report have the same source cone and destination family:

```text
proc_idx
  -> distributed score_mem read
  -> max_score - score
  -> EXP address rounding/clamp
  -> combinational exp_lut decode
  -> 24-bit sum_exp addition
```

The path groups differ only by the destination `sum_exp` bit:

| Paths | Slack | Destination | Levels |
|---:|---:|---|---:|
| 10 | -5.643 ns | `sum_exp[23]` | 25 |
| 10 | -5.529 ns | `sum_exp[19]` | 24 |
| 10 | -5.415 ns | `sum_exp[15]` | 23 |
| 10 | -5.398 ns | `sum_exp[22]` | 25 |
| 10 | -5.355 ns | `sum_exp[21]` | 25 |

This is a single Softmax EXP/accumulation root cause, not a QK, floating-point
IP, P-buffer, V-loader, or external-I/O path.

## v5 RTL correction

`rtl/softmax/softmax_bf16.sv` now holds `proc_idx` stable while each element
passes through four registered states:

1. `ST_EXP`: read `score_mem` and `mask_mem` into registers;
2. `ST_EXP_ADDR`: subtract from `max_score`, round/clamp, and register the LUT
   address/forced-zero flag;
3. `ST_EXP_LUT`: decode and register the EXP value;
4. `ST_EXP_ACCUM`: write `exp_mem` and add the registered value to `sum_exp`.

The former 32-bit `integer exp_addr_int` is also removed.  EXP address math is
kept at `SCORE_W+1` bits, and the redundant `>512` clamp is eliminated: the
existing `magnitude<=8.0` guard proves the rounded address cannot exceed 512.

`scripts/check_exp_pipeline_equivalence.py` exhausts all 131,072 positive
Q9.14 magnitude codes in `[0, 8.0]` plus masked and out-of-range boundaries,
and requires the new pipeline tokens in the RTL.

The change deliberately trades row latency for timing margin.  For
`SEQ_LEN=128`, EXP processing grows from 128 to 512 clocks per row.  Output
values, ordering, metadata, valid/ready behavior, and the external interface do
not change.

## Acceptance sequence

Run in Vivado 2019.2 from a fresh v5 extraction:

```tcl
source run_vivado_bc_all.tcl
source run_synthesis_bc_pipeline.tcl
```

Do not run the larger system synthesis until both commands pass.  Final 100 MHz
acceptance requires the new pipeline report to show non-negative WNS while the
existing latch/BlackBox/RAMB audits remain unchanged.

The bundled `reports/bc_pipeline_artix7/v4_user_evidence/` directory contains
the exact v4 behavior console, synthesis console, timing summary, and 50-path
report used for this correction.
