# Single-GQA DMA data and register protocol

Version: `RK0100`

AXI4-Stream width: 128 bits

Scalar format: BF16 stored as an unsigned 16-bit payload

## Input frame

One MM2S DMA transaction carries one complete fixed-shape frame:

| Segment | Shape | BF16 words | Bytes | Byte offset |
|---|---:|---:|---:|---:|
| Q | `[4][128][128]` | 65,536 | 131,072 | 0 |
| K | `[1][128][128]` | 16,384 | 32,768 | 131,072 |
| V | `[1][128][128]` | 16,384 | 32,768 | 163,840 |
| Total | — | 98,304 | 196,608 | — |

The innermost dimension is contiguous:

```text
Q(head, token, dim) = ((head * 128 + token) * 128 + dim)
K(token, dim)       = token * 128 + dim
V(token, dim)       = token * 128 + dim
```

Within a 128-bit AXI beat, lane 0 is bits `[15:0]`, lane 1 is `[31:16]`,
and so on. All 16 `TKEEP` bits must be one. `TLAST` must be asserted only on
the final V beat. Segment position encodes tensor type, head, token and
dimension; `TLAST` is the frame boundary.

The input size is exactly 12,288 beats. Early `TLAST`, missing final `TLAST`
or partial `TKEEP` sets a sticky ingress protocol error.

## Production core memory contract

The bridge converts the DMA layout to the existing one-outstanding Q/K
request interface:

```text
Q x0 = Q(head, token, pair)
Q x1 = Q(head, token, 64 + pair)
K x0 = K(token, pair)
K x1 = K(token, 64 + pair)
```

V is replayed as two BF16 values per `v_load` beat before the core start
pulse. The original ROM self-test remains separate and unchanged.

## Output frame

One S2MM DMA transaction receives:

| Tensor | Shape | BF16 words | Bytes | AXI beats |
|---|---:|---:|---:|---:|
| Context | `[4][128][128]` | 65,536 | 131,072 | 8,192 |

Order:

```text
Context(head, row, col) =
    ((head * 128 + row) * 128 + col)
```

`TLAST` is asserted with the final Context word. The packer supplies the
correct partial `TKEEP` for a general final beat; this fixed shape fills every
beat completely.

## AXI-Lite register map

| Offset | Name | Access | Definition |
|---:|---|---|---|
| `0x00` | CONTROL | W | bit 0 start; bit 1 clear sticky software status |
| `0x04` | STATUS | R | bits 0–5: ready, busy, frame_loaded, protocol_error, done, error |
| `0x08` | KERNEL_LO | R | kernel cycle counter low |
| `0x0C` | KERNEL_HI | R | kernel cycle counter high |
| `0x10` | INPUT_BEATS | R | accepted input beats |
| `0x14` | OUTPUT_BEATS | R | accepted output beats |
| `0x18` | STALL_LO | R | Context backpressure cycles low |
| `0x1C` | STALL_HI | R | Context backpressure cycles high |
| `0x20` | BUILD_ID | R | `0x524B0100` |
| `0x24` | ERROR_VECTOR | R | individual engine error bits |

Start is accepted only when `ready=1` and `frame_loaded=1`. Software must
start S2MM before MM2S so the output path cannot deadlock.

## Measurement boundaries

- `kernel_cycles`: production core start through final Context transfer.
- DMA transaction time: software timestamp immediately before the first DMA
  submission through S2MM completion.
- Application time: Q/K/V preparation, cache maintenance, DMA, kernel,
  output invalidation and Golden comparison.

The three values must be reported separately.
