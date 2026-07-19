# Scripts

- `run_vivado_v4_quick.tcl`: 10 quick behavioral tests, including group control.
- `run_vivado_v4_all.tcl`: quick tests plus the 65,536-output frontend golden test.
- `run_vivado_v4_full_qk_optional.tcl`: long full real QK -> Adapter test.
- `run_vivado_v4_full_pipeline_optional.tcl`: long complete selected-group real QK -> Softmax test.
- `run_synthesis_frontend_only.tcl`: Adapter + Softmax synthesis/implementation.
- `run_synthesis_full_pipeline.tcl`: real QK + Frontend synthesis/implementation.
- `create_fp32_ips.tcl`: creates `floating_point_0/1/2`.
- `check_v4_vectors.py`: vector counts, coordinates, masks, and small QK arithmetic.
- `check_exp_pipeline_equivalence.py`: v5 four-stage EXP structure plus exhaustive
  Q9.14 LUT-address equivalence.
- `analyze_v4_timing_evidence.py`: verifies the v4 WNS/TNS/endpoints and the
  single-cone classification of all 50 bundled critical paths.
- `check_softmax_rtl_reference.py`: software mirror of the RTL Softmax approximation.
- `check_package_integrity.py`: required files and duplicate runtime-data basenames.
- `summarize_reports.py`: summarizes utilization and timing reports.
- `run_vivado_bc_small.tcl`: original direct Groups 0/7 B+C regression.
- `run_vivado_bc_extended.tcl`: illegal-ID, busy/reset and real-V-cache
  Group 0..7 regressions.
- `run_synthesis_bc_pipeline.tcl`: OOC synthesis/audit of the external-V B+C top.
- `run_synthesis_bc_system.tcl`: OOC synthesis/audit including controller and
  full V-cache.
- `run_synthesis_row_buffer.tcl`: fast OOC check requiring exactly one RAMB for
  the Row Tile Buffer payload.
- `synthesis_bc_common.tcl`: latch/MDRV/BRAM/large-FF/EXP-LUT/timing checks.
- `check_v3_design.py`: v3 BRAM template, named ports, counts and V-cache contract.
- `check_row_buffer_schedule.py`: randomized registered-read/backpressure schedule audit.
- `build_manifest.py`: regenerates `FILE_LIST.txt` and SHA-256 manifest.

Legacy `run_vivado_v3_*.tcl` root wrappers redirect to v4 scripts.
