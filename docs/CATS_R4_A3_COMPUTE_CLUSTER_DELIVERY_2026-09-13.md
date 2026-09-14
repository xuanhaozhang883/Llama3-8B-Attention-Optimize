# CATS-R4 A3 Compute Cluster Delivery

This record retains the implementation-plan date in its filename; evidence was last assembled on 2026-09-14.

## Status and identity

- Stage: member-A-owned single-cluster A3 compute unit and 150 MHz OOC gate.
- Status: **`BLOCKED-WITH-EVIDENCE / NOT READY`**.
- Branch: `codex/a-cats-r4-a3-compute-cluster`.
- Integration base: `f9419e8d30d13f5aeba6cfeb6dd1403028f79d43` on `origin/codex/cats-r4-local-integration`.
- Complete source/evidence HEAD before this delivery record: `7d2560b3d63594507d27cb75ffa15b1327c3d76b`.
- Delivery identity: the commit containing this file (obtain with `git log -1 --format=%H -- docs/CATS_R4_A3_COMPUTE_CLUSTER_DELIVERY_2026-09-13.md`).
- Interface tag object: `abe7492f5cd547d3128707b4b1405fcfca6909be` (`CATS_R4_INTERFACE_V3_COMMIT`).
- Tagged interface commit: `4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`.
- Accepted B commits: contract `678eb5f9b4f65a399690820221787884d0cf341e`, Softmax `9b3dcf225013477aef2d95c17399b55a4367e0ae`, PV `ebdbe7472d6144e7954fd15b7da1cba124c75f08`, integration `d2027924b698baad092873c98903533ca0f46d96`.

Exact upstream provenance is:

| B deliverable | B source commit | Local accepted commit |
|---|---|---|
| Contract | `eb70525918b36573e0ec31a31459c0a3c0120b62` | `678eb5f9b4f65a399690820221787884d0cf341e` |
| B2 | `a59a214711c3b3c9693662c892d011e5026c0419` | `9b3dcf225013477aef2d95c17399b55a4367e0ae` |
| B3 | `07a1c87239349ae7bfe986ad78694f88f1f6fe93` | `ebdbe7472d6144e7954fd15b7da1cba124c75f08` |
| B4 | `18cdd2335bfa60927b1fbb466020561681f725eb` | `d2027924b698baad092873c98903533ca0f46d96` |

Commit `b53902734501738df2a9a467e7907ffe99a11eda` subsequently modifies the B-owned B4 wrapper to align row-error handshake with release arbitration. That owner-boundary change is functionally tested but is **not yet owner-accepted**: before integration, B must return an accepted SHA containing the change, or the lead must explicitly approve an exception. This document does not claim that approval has occurred.

The functional and representative real-IP gates pass, but the complete A3 wrapper has no completed route or final DRC and its intermediate 150 MHz timing is negative. Consequently it cannot be called `A3 compute-unit/OOC READY` and must not be merged directly to `main`.

## Delivered implementation and owner boundaries

Member A owns and changed the Q-slab recovery, score formatter/front end, physical three-slot score memory, A-side/B4 error join, A3 compute wrapper, telemetry, TBs, and A3 OOC runner:

```text
rtl/core/bc/qk/cats_r4_qk_q_slab_client.sv
rtl/core/bc/qk/cats_r4_qk_score_formatter.sv
rtl/core/bc/qk/cats_r4_qk_score_slot_mem.sv
rtl/core/bc/integration/cats_r4_a3_row_frontend.sv
rtl/core/bc/integration/cats_r4_a3_error_join.sv
rtl/core/bc/integration/cats_r4_a3_compute_cluster.sv
tb/tb_cats_r4_a3_*.sv
tests/run_cats_r4_a3_*.ps1
scripts/cats_r4_a3_compute_cluster_ooc.tcl
```

B-owned Softmax/PV commits were consumed as accepted upstream inputs. A3 does not claim ownership of B arithmetic. C still owns weight/V memory service, DMA, CDC, DDR, global drain/recovery, board top and production manifest. D owns independent performance/ablation review.

The frozen row, score, weight, PV, Context, release and unified-error ports are enumerated in `docs/CATS_R4_A3_PORT_MAP_2026-09-13.md`. Row/score/Context/release/error are valid/ready and must hold payload while stalled. The C weight response remains fixed N+2 and non-backpressured per Interface V3.

## Implementation commit map

| Task | Principal commits |
|---|---|
| Contract/baseline | `7aeb53691fb039c74bcabb3da2ba68b3021b08b3`, `b53902734501738df2a9a467e7907ffe99a11eda` |
| Q-slab error recovery | `275b355610d50a5a5b6ded001cac281d7c0bb9e8` |
| Three-slot score memory | `4b77bcfb950dfea537151655bddc1b1ceb0361f4`, `26513737df2b2103d1de9cf02920fec548dd8f1d`, `b62ec05113b31de54bcff8e05d14a54c84d41743` |
| Row frontend/formatter | `0d8a3b1881806e6aba76d9de4d723eb16be69104`, `624d4775ad5837339e1c9a457ca21cfa650d53a4`, `0c7cb94bbf5824084aad98d4b1a2348e40436f7f` |
| Buffered error join | `a54d4bb90007d973522b7a4fef9e01d9aea54579`, `4771e35c4b63b7a53f2f8c661a22eb68cea5c216`, `3b70ffbb092b6c6987638aa884744ad385181c8d` |
| Complete wrapper | `ef60ecf4d247444ee07a263ca1085f7e81a58627`, `70fab85f7612853f41d08451b7130fd71715a1f1`, `d6a344b25ab0bb6f396b529bfb86770e58fc3a17` |
| Stress/error closure | `9ab6f67dd7097fab64d32122d6131d92daf7e097` through `bcbc625b582971d9dcdedc769ae2d0ab91e92088` |
| Full protocol/numeric | `5cb58265c80025f17803d3584578733410bd62a1`, `7b31abf87d8bb972c1af0f2f3c4195ceb246b8d9`, `90cb1a28d8b69aac72bbc454e653587ee815b414` |
| Real-IP/OOC gates | `bda9f739a46cb1cb7f93f6e51445184760785a29`, `6aaebbb196d3cad3f5413c01765bd367167b00ff`, `7d2560b3d63594507d27cb75ffa15b1327c3d76b` |

## Verification evidence

### Full protocol and numerical closure

Both numeric modes passed the full protocol model using seed `3019898881`. This is explicitly `protocol_model`, not real-IP evidence.

| Counter | Expected | Actual |
|---|---:|---:|
| rows | 4096 | 4096 |
| causal scores / valid exp | 264192 | 264192 |
| weight writes | 524288 | 524288 |
| QK valid MAC | 33816576 | 33816576 |
| PV valid MAC | 33816576 | 33816576 |
| Context words | 524288 | 524288 |
| final releases | 4096 | 4096 |
| Q slabs | 256 | 256 |
| engine jobs | 6144 | 6144 |
| normal-path errors | 0 | 0 |

Mode 0 log SHA-256 is `6438C3FD797B13FB903177096B30DC608FEC2CC82DAF88EFDF2053187E15BC05`; Mode 1 is `7F2B07EC8C126EE33533DD38EE79FD309383121DA4BCC92B4A09E390B3C24F4F`.

Both logs were generated after the score RAM single-write-process modification and before that modification was committed as `6aaebbb196d3cad3f5413c01765bd367167b00ff`. No RTL changed after that commit; this follow-up changes documentation/evidence provenance only, so the full protocol runs do not need to be repeated.

Stored-full numeric evidence is `stored_full_numeric`, 4096 rows / 524288 elements, `combined_failures=0`. Report `reports/host_full_gqa_numerical_20260902.json` has SHA-256 `363FD5F76C3C5084F85A6CDF65BC80FBFAC2287C053BDCAD8F85B99FABD59984`. This PASS is not a bit-exact claim.

### Representative real-IP XSim

Vivado 2025.2 current-RTL XSim passed all eight configurations: modes `0/1` × seeds `7/19/73/101`, 16 rows per configuration. Mode 0 seed 7 injects reset; mode 1 seed 19 injects abort. The log contains 8 exact `REAL_IP=1 EVIDENCE_LEVEL=REPRESENTATIVE_REAL_IP_XSIM` markers and has SHA-256 `22543123A14707FAA5B58A4D960721C91CDAF2C9F22182B336CF3D3AE504254E`.

A2 vendor XSim also passes. The standalone B4 OOC reference closes at positive WNS (`+0.707 ns` in the latest Task 9 rerun); it does **not** substitute for complete A3 OOC timing.

### Complete A3 OOC at 150 MHz

- Tool/device: Vivado 2025.2, `xczu15eg-ffvb1156-2-i`.
- Constraint: 6.666 ns / 150.015 MHz.
- Synthesis: complete.
- Synthesis utilization: 67278 LUT, 119659 FF, 0 BRAM, 387 DSP, 0 URAM.
- Synthesis worst path: slack `-40.754 ns`, data path `47.410 ns`, from formatter `scaled_fp32_reg_reg[6]/C` to row assembler `row_max_bf16_reg[0]/D`.
- Route: timed out/incomplete. Latest intermediate estimate: WNS `-26.049 ns`, TNS `-31863.239 ns`; 125 routing overlaps remained.
- Final routed WNS/TNS: unavailable.
- Final route-status/DRC: unavailable.

The route log SHA-256 is `3F56EFE6DC75C8156E7E59C82790AEF7AFEAC6CF73382287B20AA55747B1ED7C`. Synthesis DCP SHA-256 is `DA1FA09AB23AF7767C8C10CA9EF69DAA0B0950B2E5FB35C0614BA20360B08524`. Intermediate estimates are diagnostic only and are never treated as final routed evidence.

## Telemetry and ablation

Production RTL exposes first issue/last commit timestamps, per-slot occupied cycles, row/Context/final-release stalls, epoch drops and error-source counters. Directed TB verifies nonzero activity and `counter_clear`; the full protocol model verifies request/result/commit/release conservation plus score FIFO stall and maximum occupancy behavior.

Row-versus-online status is `comparable=false`: there is no independent online manifest with identical input hash, numeric mode, 32 QK/PV lanes, 150 MHz target and timing boundary. See `docs/CATS_R4_A3_ROW_ONLINE_ABLATION_2026-09-13.md`. No system-performance conclusion is published.

## Commands and disposition

```powershell
# PASS: A2, A3 units, both directed modes, stress matrix and C protocol units
& tests\run_cats_r4_qk_32lane_engine_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_qk_q_slab_client_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_qk_a2_row_pipeline_xsim.ps1 -VivadoRoot 'C:\Software\AMD\vivado25.2\2025.2\Vivado'
& tests\run_cats_r4_a3_row_frontend_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_a3_error_join_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_a3_compute_cluster_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 0
& tests\run_cats_r4_a3_compute_cluster_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 1
& tests\run_cats_r4_c_unit_checks.ps1 -IcarusRoot 'C:\Software\iverilog'

# PASS: 8/8 stress configurations
foreach ($mode in 0,1) { foreach ($seed in 7,19,73,101) {
  & tests\run_cats_r4_a3_compute_cluster_stress_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode $mode -Seed $seed
}}

# PASS: full protocol model, both modes
& tests\run_cats_r4_a3_full_protocol_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 0 -Seed 3019898881
& tests\run_cats_r4_a3_full_protocol_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 1 -Seed 3019898881

# PASS: representative current-RTL real-IP XSim 8/8
& tests\run_cats_r4_a3_realip_vivado.ps1 -OutputRoot <fresh-output-root> -SkipOoc

# FAIL/BLOCKED: complete A3 route timeout and negative intermediate timing
& tests\run_cats_r4_a3_realip_vivado.ps1 -OutputRoot <fresh-output-root> -SkipXsim -ClockPeriodNs 6.666

# Expected FAIL while OOC is incomplete
& 'C:\Users\liuhe\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' `
  tests\check_cats_r4_a3_readiness.py reports\cats_r4_a3_evidence.json
```

No failed functional seed was discarded. Negative reset/abort/error cases passed with only their expected increments. The readiness gate fails closed specifically on incomplete route, absent final DRC/TNS and absent nonnegative final WNS.

## Blockers and next work

1. **A owns timing closure.** Pipeline or otherwise restructure the A-owned formatter-to-row-max combinational path without changing the frozen interfaces or B/C arithmetic. Rerun affected functional/real-IP tests, then require completed route, DRC, WNS >= 0 and TNS = 0.
2. **C/lead owns release identity.** `mem/sin_bf16.hex` actual SHA-256 is `C4615AEE875F66BE8A8458E3F42C8F7AF32541AFFAAA94B809316562F14B4397`, while frozen documents require `C98A462FA05FC69845ACBE8B6175A1EC854AC91E1FB5B4A33E2AA7F84271FC5D`. Resolve provenance explicitly; do not silently bless either file.
3. **B/lead owns acceptance of the B4 wrapper adjustment.** B must return an accepted SHA for `b53902734501738df2a9a467e7907ffe99a11eda`, or the lead must explicitly approve the owner-boundary exception before integration.
4. **C owns C2.** C2 production integration, global abort/drain, DMA/CDC/DDR, production manifest and board top remain open.
5. **D owns independent review.** D must provide same-boundary online evidence before any row/online or system-performance claim.
6. BIT/XSA/ELF generation, board testing and system performance remain open.

## Direct handoff to C

C can inspect and exercise this work without merging it:

```powershell
git fetch origin
git worktree add ..\Llama3-8B-Attention-Optimize-a3-c-review codex/a-cats-r4-a3-compute-cluster
Set-Location ..\Llama3-8B-Attention-Optimize-a3-c-review
git rev-parse HEAD
git rev-parse CATS_R4_INTERFACE_V3_COMMIT^{}
& tests\run_cats_r4_c_unit_checks.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_a3_realip_vivado.ps1 -OutputRoot <fresh-output-root> -SkipOoc
& 'C:\Users\liuhe\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' `
  tests\check_cats_r4_a3_readiness.py reports\cats_r4_a3_evidence.json
```

The last command must currently fail. C should report the exact `sin_bf16` provenance decision and any frozen-port mismatch, but should not modify A/B owner internals in the C integration commit. After A supplies a separate timing-closure commit and this readiness gate passes, review/merge toward `codex/cats-r4-local-integration`; never merge A3 directly to `main`.
