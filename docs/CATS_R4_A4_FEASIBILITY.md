# CATS-R4 A4 Feasibility Gate

Date: 2026-09-15

Evidence level: `architecture_model`. Nothing in this file is RTL, post-route, or board-performance evidence.

Reproduce with:

```powershell
& 'C:\Users\liuhe\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' `
  -m unittest tests\test_cats_r4_a4_scaling_model.py
& 'C:\Users\liuhe\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' `
  python\cats_r4_a4_scaling_model.py
```

Machine-readable output: `reports/cats_r4_a4_feasibility.json`.

## Work assignment and invariant

The model enumerates all 256 `(global_q_head, window)` jobs and 4096 rows. It proves a bijection and uses `cluster_id = group % N`:

- N=1: cluster 0 gets groups 0,1,2,3,4,5,6,7.
- N=2: cluster 0 gets 0,2,4,6; cluster 1 gets 1,3,5,7.
- N=4: cluster 0 gets 0,4; cluster 1 gets 1,5; cluster 2 gets 2,6; cluster 3 gets 3,7.

For N=1/2/4, aggregate work is invariant: 4096 rows/releases, 264192 causal scores/valid exp, 524288 weight writes/Context words, 33816576 valid QK MACs, 33816576 valid PV MACs, 256 Q slabs, and 6144 internal engine jobs.

## V3 capacity and resource risk

The V3 per-cluster logical capacity is 154520 bytes. It retains 768 bytes of three BF16 score rows and adds 1536 bytes of three FP32 weight rows plus 24 bytes of token metadata, a 1560-byte increase over C1.

Each cluster therefore requires independent peak compute-side service ports: scalar 16-bit Q response, 512-bit K response, 512-bit V response, 512-bit Context output, and simultaneous scalar 32-bit weight write/read paths as allowed by V3. K and V can each consume 64 bytes/core-cycle, for 128 bytes/core-cycle of local K+V bandwidth. These are local bank bandwidths, not extra DDR traffic. Aggregate system DDR work remains 196608 read beats and 131072 write beats; the ideal even share is divided by N.

Linear multiplication of the measured A3 compute OOC is only a risk estimate:

| Clusters | compute LUT | compute FF | compute DSP |
|---:|---:|---:|---:|
| 1 | 61967 | 115025 | 387 |
| 2 | 123934 | 230050 | 774 |
| 4 | 247868 | 460100 | 1548 |

The 4-cluster compute estimate alone exceeds the older team full-board targets of about 230k LUT and 380k FF before C infrastructure. This is not proof that the device cannot implement A4-4, but it is a mandatory budget-review gate. A4-4 must not be started by blindly cloning the A3 instance four times.

## Canonical output sensitivity

Model assumptions:

- ideal local memory service and identical cluster start;
- one produced Context row every 320 cycles, derived from the existing QK floor;
- 32 cycles to serialize a 128-element BF16 output row on the 64-bit path;
- C1 global canonical sequence and a finite per-cluster row queue;
- no Softmax, fill/drain, DDR latency, or arbitration penalty.

Because the model omits real penalties, it is a feasibility upper-bound/sensitivity tool, not a performance promise.

| Configuration | N=1 cycles | N=2 cycles | N=2 speedup | N=4 cycles | N=4 speedup |
|---|---:|---:|---:|---:|---:|
| independent infinite sink | 1310752 | 655392 | 2.000x | 327712 | 4.000x |
| current 32-row queue + canonical output | 1310752 | 1239296 | 1.058x | 1239296 | 1.058x |
| 512-row full-group queue sensitivity | 1310752 | 671776 | 1.951x | 376864 | 3.478x |

With the current 32-row queue, the N=2 model accumulates 1014176 cluster queue-stall cycles. A later group cannot commit before the preceding global group, so the non-owner cluster fills 32 rows and stalls. N=4 does not improve the modeled completion time.

## Gate decision

Status: **STOP before full A4-2 replication/OOC performance work** under the current 32-row canonical-output contract.

This STOP does not block P2/P3, the group/job adapter, N=1 wrapper baseline, or small N=2 protocol tests. It blocks claiming or investing in full A4-2 performance readiness until C/lead selects and accepts a realizable remedy, for example:

1. at least one complete group of local row buffering per active cluster;
2. a non-DDR intermediate spool that accepts out-of-order cluster rows and later commits canonically;
3. a different C-owned scheduling/commit mechanism with equivalent finite-capacity proof.

The selected solution must include actual capacity, shared bandwidth, backpressure, epoch/reset behavior, resource cost, and the precise performance end boundary. After it exists, rerun the model with the accepted parameters, then continue to the full 2-cluster RTL/OOC gate.
