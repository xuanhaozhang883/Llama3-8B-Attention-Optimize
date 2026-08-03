# v2.3 Hardware Profiling Summary

- Runs: 10
- Average total PL cycles: 276,550,520.600

| Counter | Average cycles/count | % of total cycles |
|---|---:|---:|
| v_load_cycles | 101,929.700 | 0.037% |
| core_run_cycles | 276,448,589.900 | 99.963% |
| bc_busy_cycles | 156,648,602.700 | 56.644% |
| pv_busy_cycles | 119,799,808.000 | 43.319% |
| raw_wait_cycles | 325,930.700 | 0.118% |
| raw_busy_cycles | 320,810.700 | 0.116% |
| ddr_read_busy_cycles | 412,493.400 | 0.149% |
| context_busy_cycles | 276,448,587.900 | 99.963% |
| context_backpressure_cycles | 0.000 | 0.000% |
| ddr_write_busy_cycles | 156,926.200 | 0.057% |

## Traffic

- raw_req_count: 327,680.000
- read_command_count: 5,121.000
- read_beat_count: 196,608.000
- write_command_count: 1,024.000
- write_beat_count: 131,072.000
- context_word_count: 524,288.000
- error_detail: 0.000

## Per-group cycles

- Group 0: 34,556,034.000
- Group 1: 34,556,042.300
- Group 2: 34,556,061.400
- Group 3: 34,556,060.700
- Group 4: 34,556,059.000
- Group 5: 34,556,061.300
- Group 6: 34,556,061.700
- Group 7: 34,556,056.300

> Busy/wait counters overlap and must not be added as exclusive phases.
