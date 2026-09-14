# CATS-R4 A3 Row / Online Ablation Record

This record retains the implementation-plan date in its filename; evidence was last assembled on 2026-09-14.

## Conclusion

`comparable=false`. No independently generated online candidate was delivered with the same experiment boundary as the A3 row candidate. Therefore this record makes **no** row-versus-online cycle, resource, stall, or system-performance claim.

The comparison gate is `python/cats_r4_a3_ablation_gate.py`. It requires exact equality for:

| Field | Required row candidate | Available online candidate |
|---|---|---|
| `input_sha256` | same saved full input | missing |
| `numeric_mode` | same mode | missing |
| `qk_lanes` | 32 | missing |
| `pv_lanes` | 32 | missing |
| `clock_mhz` | 150 MHz target | missing |
| `timing_start` | first QK issue | missing |
| `timing_end` | last Context commit | missing |

The older v3.1.4 4-lane board result is deliberately excluded: its lane count and timing boundary differ. It is not a valid online baseline for A3.

## Reproduce the gate tests

```powershell
& 'C:\Users\liuhe\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' `
  tests\test_cats_r4_a3_ablation_gate.py
```

The tests prove that every mismatched or missing identity field forces `comparable=false`. Only a fully matching pair returns cycle ratio/delta, LUT/FF/BRAM/DSP/URAM deltas, and per-stall deltas.

## Data required from D

D may independently enable the comparison by producing an online manifest containing all fields below, from the same saved input and the same first-issue-to-last-commit boundary:

```text
input_sha256, numeric_mode, qk_lanes=32, pv_lanes=32,
clock_mhz=150, timing_start, timing_end, cycles,
resources={lut,ff,bram,dsp,uram}, stalls={...}
```

D should run the gate without editing thresholds or substituting board-level timing. Missing D review does not itself block compute-unit/OOC READY, but the current failed A3 OOC timing gate does.
