# CATS-R4 A2 QK 32-lane engine OOC checkpoint — 2026-09-06

## Scope

This checkpoint records the synthesis-only result for
`rtl/core/bc/qk/cats_r4_qk_32lane_engine.sv`. It is a local engineering
checkpoint only. It is not an A2 READY result, a board-ready result, or a
bit-exact result.

## Why this run used blackboxes

The standalone worktree does not contain generated Vivado Floating Point IP
cores (`floating_point_0`, `floating_point_1`, and `floating_point_2`). The
OOC run therefore used temporary declarations for the multiply and add IP
instances in:

`D:/Vitis/FPT/c2_qk_engine_ooc_20260906_r2/fp32_ip_blackboxes.sv`

That file belongs to the temporary output directory and must not be added to
the repository or to the production source manifest.

## Observed result

- `synth_design`: completed successfully
- errors: `0`
- critical warnings: `0`
- warnings: `3`
- blackbox instances: `floating_point_0` × 32 and `floating_point_1` × 32
- timing/utilization reports were emitted in the temporary OOC directory
- the run reported a missing `HD.CLK_SRC` annotation; this is expected to be
  treated as an OOC limitation until the real IP and clock constraints are
  present

The emitted synthesis-only report also records:

- setup WNS `+2.772 ns` at `core_clk=150 MHz`;
- setup failing endpoints `0` and internal unconstrained endpoints `0`;
- CLB LUT `8,248`, CLB registers `22,219`;
- Block RAM tiles `0`, DSPs `0`, URAM `0`.

The zero unconstrained-internal count does not remove the OOC limitation: the
run has no generated FP IP timing arcs and no board-level I/O delay or route
evidence.

## Interpretation

The result proves that the engine control/dataflow elaborates and that the
wrapper can be synthesized around abstract FP32 multiply/add interfaces. It
does **not** measure Floating Point IP latency, initiation interval, DSP/BRAM
usage, or timing. It therefore cannot close the A2 real-IP OOC gate.

## Counter correction and repeatable mock checkpoint

The FP32 service counter update was corrected so a cycle's lane-result popcount
is added once per completion cycle, rather than once inside every lane loop
iteration. This preserves the frozen aggregate meaning of
`fp32_mul_products_completed` and `fp32_add_results_completed`.

The following local checks pass after the correction:

- `tests/run_cats_r4_qk_32lane_engine_iverilog.ps1` — integrated scheduler,
  FP32 service, score FIFO, causal mask, and backpressure checkpoint;
- `tb/tb_cats_r4_qk_32lane_fp32_service.sv` — context isolation and score
  commit checkpoint.

The checks use the project's simulation mocks; they are not evidence for the
latency or numerical behavior of generated Vivado Floating Point IP.

## Required next gate

Before any A2 READY decision, generate the project Floating Point IP with
`scripts/create_fp32_ips.tcl` in an isolated Vivado project, then rerun OOC
with the generated `floating_point_0/1/2` products and explicit clock
constraints. The real-IP run must report zero unconstrained paths and must be
paired with the D=128 numeric/protocol regression.

The engine also still requires QK scaling, FP32-to-BF16 score rounding, score
slab ownership/commit metadata, multi-window workload coverage, and the
lane-equivalence and causal-corner regressions listed in the A2 checklist.

## Post-counter rerun

After the counter correction, the same isolated blackbox OOC flow was rerun at:

`D:/Vitis/FPT/c2_qk_engine_ooc_20260906_r3`

- `synth_design`: completed successfully; 0 errors, 0 critical warnings, 3 warnings;
- setup WNS `+2.772 ns`, setup failing endpoints `0`;
- internal unconstrained endpoints `0`;
- CLB LUT `8,184`, CLB registers `22,213`;
- Block RAM tiles `0`, DSPs `0`, URAM `0`;
- blackboxes remain `floating_point_0` × 32 and `floating_point_1` × 32.

This confirms synthesis closure of the corrected control logic only; it does not upgrade the evidence level beyond blackbox mode.

## Real Floating Point IP OOC attempt

The project's `scripts/create_fp32_ips.tcl` was exercised in an isolated
Vivado project at `D:/Vitis/FPT/c2_fp32_ip_gen_20260906_r1/project`. It
generated `floating_point_0/1/2` and their synthesis/simulation targets. Vivado also reported that `B_Precision_Type`, `Has_A_TREADY`, and `Has_B_TREADY` were not exposed by this IP version; those properties and the wrapper handshake must be audited before promotion. The
same engine was then synthesized with those real IP products at:

`D:/Vitis/FPT/c2_qk_engine_realip_ooc_20260906_r1`

Observed result:

- real-IP `synth_design`: completed successfully; 0 errors, 0 critical warnings;
- Vivado synthesis warning count: `673` (including generated-IP trim/unconnected-port warnings);
- setup WNS `+2.528 ns` at `core_clk=150 MHz`; setup failing endpoints `0`;
- internal unconstrained endpoints `0`;
- CLB LUT `20,058`, CLB registers `44,971`;
- Block RAM tiles `0`, DSPs `128`, URAM `0`;
- no blackboxes were reported in the synthesized design;
- the OOC timing report still warns that `HD.CLK_SRC` is absent.

This is the first real-IP synthesis/timing checkpoint and is stronger than the
blackbox run, but it is still not A2 READY: the generated IP configuration and
latency/II need explicit audit, warning cleanup, D=128 numeric regression, QK
scale/BF16 score formatting, score/max slab ownership, and full causal counter
closure before any READY marker.
## Status

`LOCAL CHECKPOINT / REAL-IP OOC + MOCK REGRESSION / NOT READY`
