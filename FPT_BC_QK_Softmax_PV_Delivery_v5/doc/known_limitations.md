# Known Limitations

1. The formal B+C top still processes one GQA Group per launch.  The package adds a
   reference controller/system wrapper that iterates Group 0..7, but owner A
   remains responsible for merging that policy into the final Attention top.
2. Row Tile Buffer is single-buffered and backpressures QK during drain.
3. Softmax is correctness-first and processes rows serially.
4. The Row Tile and P buffers now use synchronous-read block-RAM templates.
   `run_synthesis_bc_pipeline.tcl` deliberately fails if either buffer does not
   infer a RAMB primitive in the user's Vivado build.
5. `exp_lut` is currently a combinational LUT ROM; BRAM conversion adds read latency and requires pipeline changes.
6. Behavioral FP32 models are simulation-only and do not validate complete IEEE-754 exceptional behavior.
7. `xc7a35tcpg236-1` and 100 MHz are provisional development targets, not KV260 signoff.
8. The modified v5 RTL was statically audited here but must be rerun
   in Vivado/XSim by the user.
9. The B+C extension includes C integration through the PV input
    stream, but a real PV MAC/result buffer is still outside this delivery.
10. Joint XSim tests are supplied but must be run by the user because the
    package-generation environment has no Vivado/XSim installation.
11. The included V-cache is a synthesizable on-chip reference store with a
    vector load port.  Final DMA/AXI transfer into that cache remains part of
    the system memory integration.
12. The v5 Softmax timing stages intentionally trade row latency for a shorter
    clock period.  The probability output currently produces one accepted beat
    after three arithmetic preparation states; further throughput optimization
    can replace these states with a fully elastic pipeline if system profiling
    shows Softmax output to be the bottleneck.
    EXP processing also uses four cycles per element (read/address/LUT/accumulate)
    instead of one; this is the direct correction for the v4 50-path report.
13. The OOC constraints define the internal 100 MHz clock but do not assign
    realistic input/output delays.  Full-top implementation must budget every
    external interface and rerun setup/hold analysis.
