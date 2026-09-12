# CATS-R4 B→C Counter Dictionary

**冻结日期：2026-09-12**
**适用范围：IF_V3 weight-slot service、C/PV single-cluster candidate、output/abort integration**

本文档冻结计数器名称、所有者、递增条件、清零条件和正常负载目标。计数器均为 64-bit saturating-free monotonic counters；除非另有说明，只在对应 owner clock domain 递增。`clear` 或对应 reset 将计数器清零；abort/drain 不自动清零，只有新 epoch 的显式 clear 才开始新的统计窗口。

## B→C / slot-service counters

| Counter | Owner | Increment condition | Normal single-row target |
|---|---|---|---:|
| `weight_wr_accept` | `cats_r4_weight_slot_mem` / core | `weight_wr_valid && weight_wr_ready` | 128 |
| `row_commit_count` | slot service / core | `row_commit_valid && row_commit_ready` | 1 |
| `weight_rd_request` | slot service / core | `weight_rd_req_valid && weight_rd_req_ready` | 128 |
| `weight_rd_response` | slot service / core | response token accepted for the matching request | 128 |
| `weight_release_count` | slot service / core | `weight_release_valid && weight_release_ready` | 1 |
| `owner_error` | slot service / core | owner/group/head token mismatch | 0 |
| `mask_error` | slot service / core | mask does not equal `key > row`, or masked data is non-zero | 0 |
| `last_error` | slot service / core | `last` disagrees with final key | 0 |
| `mode_error` | slot service / core | numeric mode is outside frozen mode set or mismatches slot | 0 |
| `numeric_error` | slot service / core | sum/inverse-sum numeric contract violation | 0 |
| `epoch_drop` | slot service / core | stale-epoch write/read/commit/release dropped | 0 in normal run; non-zero only in stale-epoch tests |
| `bank_conflict` | slot service / core | illegal simultaneous bank access | 0 |
| `outstanding_max` | slot service / core | high-water mark of accepted requests minus responses | implementation-dependent; must remain bounded |

Required equalities for a normal row are:

```text
weight_wr_accept = 128
weight_rd_request = weight_rd_response = 128
row_commit_count = pv_row_count = weight_release_count = 1
```

## C/PV counters

| Counter | Owner | Increment condition | Normal single-row target |
|---|---|---|---:|
| `rows_started` | `cats_r4_weight_pv_wrapper` | PV row-start handshake | 1 |
| `weights_forwarded` | weight/PV wrapper | weight token accepted by PV consumer | 128 |
| `product_accept_count` | PV product/accumulator path | product token accepted by accumulator | 512 (128 keys × 4 blocks) |
| `add_commit_count` | PV accumulator | one lane-add result committed | 512 |
| `context_emit_count` | PV accumulator | one 512-bit context chunk accepted by output | 4 |
| `rows_released` | weight/PV wrapper | release handshake completed | 1 |
| `protocol_error_count` | C/PV integration | sticky protocol error observed | 0 |

For a full 32-head × 128-row tensor, multiply the per-row targets by 4096 where applicable: 524288 weight writes, 524288 requests/responses, 4096 row commits, 16384 context chunks, and 4096 releases.

## Output counters

| Counter | Owner | Increment condition | Normal single-row target |
|---|---|---|---:|
| `output_chunks_accepted` | output CDC/reorder boundary | one 512-bit context chunk accepted | 4 |
| `output_beats_committed` | AXI/DDR writer | one 64-bit writer beat accepted by `wr_ready` | 32 |
| `rows_written` | output writer | final beat of one row committed | 1 |
| `payload_push_count` / `payload_pop_count` | output CDC | one 64-bit FIFO payload write/read | 32 / 32 |
| `tag_push_count` / `tag_pop_count` | output CDC | one row tag write/read | 1 / 1 |
| `outstanding_max` | slot/output owner | high-water mark of in-flight work | bounded and documented per build |

The writer must hold address, data, row-last and tensor-last stable while `wr_valid && !wr_ready`. `output_beats_committed` counts only the ready-qualified transfer, not merely presentation of `wr_valid`.

## Abort / epoch / reset rules

- `abort_valid` starts drain; `core_accept_enable` and `axi_accept_enable` close before clear pulses are issued.
- No new weight write, row commit, PV read, output payload or writer beat may be accepted while its domain is closed.
- `current_epoch` advances exactly once per accepted abort. Stale tokens are consumed/dropped and counted in `epoch_drop`; they must not produce output or release a new slot.
- `core_clear` and `axi_clear` clear in-flight state and per-window counters only when asserted by the abort controller or explicit test clear.
- A released slot returns to `FREE`; the next epoch must be able to allocate the same slot without duplicate release.
- `abort_done_valid` is asserted only after both core and AXI outstanding counts are zero and clear pulses have completed.

## Gate interpretation

The Icarus candidate gate proves protocol/counter behavior for the replay stimulus. It does **not** prove Vivado XSim, OOC utilization, WNS/TNS, CDC methodology, or board release. Those gates remain mandatory after the real B2 RTL and target Vivado installation are available.