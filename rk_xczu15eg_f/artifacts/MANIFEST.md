# RK-XCZU15EG-F Stage 1 artifact manifest

| Field | Value |
|---|---|
| Board | RK-XCZU15EG-F V1.0 |
| Device | `xczu15eg-ffvb1156-2-i` |
| Tool | Vivado 2025.2, build 6299465 |
| Source branch | `rk-xczu15eg-pl-selftest` |
| Source/build commit | `5a128c8` |
| Datapath | RoPE -> QK -> Scale/Mask -> Softmax -> PV |
| Configuration | PL-only, one GQA group, 4 Q heads, 1 shared K/V head |
| Clock | 200 MHz differential input, 100 MHz Attention |
| Post-route WNS | `+2.221 ns` |
| Post-route WHS | `+0.011 ns` |
| DRC errors | 0 |
| Hardware status | `HARDWARE VALIDATION PENDING` |

## Matched files

| File | Bytes | SHA-256 |
|---|---:|---|
| `rk_xczu15eg_f_pl_selftest.bit` | 28,700,902 | `92856247B6AE241B762683537636CF76BF58405C0B4D0B9AEA688C9EA1104D90` |
| `rk_xczu15eg_f_pl_selftest.ltx` | 31,229 | `646C76E45C14F294479AB94FB9AA08F9781B48AA8BD165AE170A60C9D8B3EF40` |

These two files must remain paired. They are local build artifacts intended
for a GitHub Release, Git LFS, or a controlled artifact store. They are not
included in the ordinary source commit.

The source/build commit identifies the exact RTL, XDC, IP-generation Tcl,
rebuild flow, and sign-off reports used for the artifacts. This manifest is
added in a later documentation-only commit.
