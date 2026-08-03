# FPT Attention v2.4 Board-Test Summary

- Correct measured runs: 10 / 10
- Deterministic measured runs: 10 / 10
- Minimum latency: 1843.688656 ms
- Average latency: 1843.689190 ms
- Maximum latency: 1843.689826 ms
- Latency standard deviation: 0.000338 ms
- Context throughput: 284,368 elements/s
- GQA group rate: 4.339 groups/s
- Effective QK+PV rate: 0.145 GFLOP/s
- Average total PL cycles: 276,550,484.900

## Fine-grained counter averages

| Counter | Average | % of total cycles |
|---|---:|---:|
| rope_busy_cycles | 156,648,571.700 | 56.644% |
| qk_busy_cycles | 133,431,296.000 | 48.248% |
| mask_busy_cycles | 133,266,432.000 | 48.189% |
| softmax_busy_cycles | 4,916,224.000 | 1.778% |
| bc_backend_busy_cycles | 133,712,712.000 | 48.350% |
| capture_busy_cycles | 156,648,555.700 | 56.644% |
| context_transfer_cycles | 524,288.000 | 0.190% |
| bc_pv_overlap_cycles | 0.000 | 0.000% |
| core_idle_cycles | 2.000 | 0.000% |
| repack_stall_cycles | 0.000 | 0.000% |
| pv_feed_stall_cycles | 115,605,520.000 | 41.803% |
| softmax_stall_cycles | 0.000 | 0.000% |
| interstage_wait_cycles | 24.000 | 0.000% |

> Busy, wait, stall and overlap counters are not mutually exclusive and must not be summed as pipeline stages.
