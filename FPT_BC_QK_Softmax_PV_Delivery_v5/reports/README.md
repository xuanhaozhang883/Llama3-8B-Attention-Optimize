# Reports

`v3_baseline_frontend_only/` contains the previous Artix-7 v3 implementation reports. They are retained only as a historical baseline and do **not** sign off v4 group-interface changes.

Run the synthesis scripts again to create current reports:

```tcl
source run_synthesis_frontend_only.tcl
source run_synthesis_full_pipeline.tcl
```

Final KV260/K26 resource and timing signoff requires a Vivado release with K26 device support.

No B+C v3 synthesis report is pre-bundled.  First run the Row Buffer audit,
then the complete pipeline audit:

```tcl
source run_synthesis_row_buffer.tcl
source run_synthesis_bc_pipeline.tcl
```

This creates a provisional Artix-7 structural report under
`reports/bc_pipeline_artix7/`.  It is not KV260 signoff.

`reports/bc_pipeline_artix7/v4_user_evidence/` is immutable input evidence for
the v5 EXP correction.  It records the v4 13-PASS behavior run and the remaining
`WNS=-5.643 ns` EXP/accumulation path.  A new v5 synthesis run writes alongside
that directory and must not be confused with the historical evidence.

The complete system audit is:

```tcl
source run_synthesis_bc_system.tcl
```

It writes `reports/bc_system_artix7/` for the controller+B+C+full-V-cache
wrapper on temporary `xc7a100t`.  New report directories include hierarchical
utilization, timing, methodology, RAM utilization when supported, MDRV-1,
`check_timing`, a DCP and `SYNTHESIS_AUDIT_SUMMARY.txt`.
