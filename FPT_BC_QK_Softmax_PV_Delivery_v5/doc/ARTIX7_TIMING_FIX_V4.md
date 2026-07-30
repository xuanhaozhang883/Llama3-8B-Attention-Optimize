# Artix-7 100 MHz Timing Fix (B+C Delivery v4)

## Evidence from the v3 synthesis report

The supplied Vivado 2019.2 report for `xc7a35tcpg236-1` showed:

```text
WNS = -9.695 ns
TNS = -1200.289 ns
failing endpoints = 182
```

The worst constrained path was:

```text
Row Tile Buffer RAMB18E1 read
  -> softmax_bf16.bf16_to_fixed()
  -> max_score comparison/update enable
```

Its data-path delay was `19.316 ns`, with 44 logic levels including 32
`CARRY4` primitives.  The root cause was not the BRAM itself: the BRAM clock-to-
output contribution was `2.454 ns`.  The legacy converter used 64-bit variable
shifts and 64-bit saturation comparisons before the 24-bit maximum comparison.

The same report exposed a second long combinational output path of `18.532 ns`:

```text
exp_mem -> probability multiply -> rounding -> Q15-to-BF16 -> prob_data
```

This path was visible at the unconstrained monitor output and also feeds the
internal P Buffer.

## v4 RTL correction

`rtl/softmax/softmax_bf16.sv` now:

1. uses an eight-bit-exponent/24-bit-magnitude BF16-to-Q9.14 converter;
2. registers raw BF16 and converted fixed-point data in separate elastic stages
   before updating `max_score`;
3. splits probability output into registered multiply, rounding and BF16-
   encoding states;
4. preserves `valid/ready` stability and permits input-stage retire/refill on
   one edge.

The narrow converter is exhaustively compared against the legacy algorithm for
all 65,536 BF16 encodings by:

```text
scripts/check_bf16_to_fixed_equivalence.py
```

## Required Vivado rerun

First prove that the added stages did not change functionality:

```tcl
source run_vivado_bc_all.tcl
```

Then rerun the formal B+C synthesis:

```tcl
source run_synthesis_bc_pipeline.tcl
```

In addition to the existing summary, the script now writes:

```text
reports/bc_pipeline_artix7/post_synth_critical_paths.rpt
```

This contains up to 50 maximum-delay paths.  Final 100 MHz acceptance still
requires a non-negative WNS in the new Vivado report; the static checks in this
package do not substitute for that rerun.

The `no_input_delay` and `no_output_delay` messages in an OOC report describe
module-boundary I/O budgeting.  They do not explain the v3 internal WNS, but
the final Attention top must add real interface/board constraints before
implementation signoff.
