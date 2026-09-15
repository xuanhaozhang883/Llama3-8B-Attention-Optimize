# CATS-R4 A4 Compute-Side Interface

Date: 2026-09-15

Status: **A-owned unit-development contract; team acceptance pending**.

This document freezes enough behavior for A to implement and test the group/job adapter and N=1/N=2 compute wrapper. It does not move `CATS_R4_INTERFACE_V3_COMMIT` and does not claim that C has accepted a new production boundary.

## 1. Topology and ownership

- Parameter `CLUSTERS` is restricted to 1, 2, or 4; other values fail elaboration/tests.
- `cluster_id = group % CLUSTERS`.
- `local_group_index = group / CLUSTERS` using integer division.
- `global_q_head = 4 * group + local_head`, `local_head=0..3`.
- Within a group, jobs are issued in `(local_head, row_window)` order, head first and window `0..7` second, for exactly 32 accepted jobs.
- A owns group-to-job expansion, cluster-local control/status, completion/error aggregation, and compute counters.
- C owns when a group and its selected K/V buffer are safe to submit, all physical Q/K/V/weight/output services, canonical output, global drain/reset, and system done.
- B owns Softmax/PV numerical behavior and the B4 wrapper internals.

Every signal below is synchronous to `core_clk`. Active-low `core_rst_n` and synchronous `clear` apply to all A4 adapter state and all A3 instances. `counter_clear` is accepted only while the whole A4 wrapper is quiescent.

## 2. Transaction and group control

### Global transaction start

```text
txn_start_valid / txn_start_ready
txn_epoch[15:0]
txn_numeric_mode[1:0]
```

The wrapper captures one transaction into an internal register, then delivers exactly one start to every enabled A3 instance. `txn_start_ready` means the wrapper can capture the complete payload; it does not require all child ready signals to be high in the same cycle. While `txn_start_valid=1 && txn_start_ready=0`, epoch and mode remain stable. Mode 2/3, a new start while busy, or a same-epoch restart is rejected and reported. Mode is locked until normal global drain or abort/clear completion.

### Per-cluster group command

For each `c=0..CLUSTERS-1`:

```text
group_cmd_valid[c] / group_cmd_ready[c]
group_cmd_epoch[c][15:0]
group_cmd_group[c][2:0]
group_cmd_local_index[c][2:0]
group_cmd_numeric_mode[c][1:0]
group_cmd_kv_buffer[c]
```

Payload holds while stalled. A command is accepted only if:

1. its epoch/mode match the locked transaction;
2. `group % CLUSTERS == c`;
3. `local_index == group / CLUSTERS` and is the next local group;
4. the previous local group is complete and drained;
5. C asserts the command only after the selected K/V buffer is active and safe.

The accepted K/V selector is held for the complete group and is supplied to C's cluster-local K/V service binding. It is not inferred from `group[0]`. Q-slab buffer selection remains independent and arrives on each existing `q_slab_ready` handshake.

### Per-cluster group completion

For each cluster:

```text
group_done_valid[c] / group_done_ready[c]
group_done_epoch[c][15:0]
group_done_group[c][2:0]
group_done_local_index[c][2:0]
group_done_numeric_mode[c][1:0]
group_done_aborted[c]
group_done_error[c]
```

Completion payload holds while stalled and is emitted at most once per accepted command. Normal completion requires all 32 jobs accepted and Q slabs retired, 512 Context rows (65536 words) accepted by C, 512 final releases accepted, all three local score/weight slots free, and no related request/response/error pending. `out_tensor_last` is a coordinate marker and is not group or transaction completion. An errored/aborted group never emits normal completion.

`compute_done` means every assigned group has produced an accepted normal `group_done` and all A-owned streams are idle. DDR BRESP completion and system done remain C-owned.

## 3. Exact per-cluster A3 service replication

For each cluster, A4 preserves one independent copy of the existing A3 boundary. Packed arrays may be flattened mechanically at a board wrapper, but fields and handshakes cannot be shared or dropped.

| Channel | Direction at A4 | Exact fields per cluster |
|---|---|---|
| Q-slab need | A→C | `valid/ready, epoch[15:0], group[2:0], global_q_head[4:0], row_window[2:0]` |
| Q-slab ready | C→A | same token fields plus `buffer` |
| Q-slab retire | A→C | same token fields plus `buffer` |
| Q request | A→C | `valid/ready, context_tag[3:0], d[6:0]` |
| Q response | C→A | `valid, context_tag[3:0], bf16[15:0]` |
| K request | A→C | `valid/ready, context_tag[3:0], key_block[1:0], d[6:0]` |
| K response | C→A | `valid, context_tag[3:0], vec_bf16[511:0]` |
| weight write | A/B→C | `valid/ready, epoch[15:0], group[2:0], global_q_head[4:0], row[6:0], slot_id[1:0], numeric_mode[1:0], key[6:0], mask, data[31:0], last` |
| row commit | A/B→C | `valid/ready`, the same complete token, `sum_fp32[31:0], inv_sum_fp32[31:0]` |
| PV row | C→A/B | `valid/ready`, the same complete token, `sum_fp32[31:0], inv_sum_fp32[31:0]` |
| weight read request | A/B→C | `valid/ready`, complete token, `key[6:0]` |
| weight read response | C→A/B | `valid`, complete token, `key[6:0], mask, data[31:0]` |
| V request | A→C | `valid/ready, context_tag[3:0], key[6:0], feature_block[1:0]` |
| V response | C→A | `valid, context_tag[3:0], vec_bf16[511:0]` |
| Context | A→C | `valid/ready, epoch[15:0], seq[11:0], global_q_head[4:0], row[6:0], feature_block[1:0], data_bf16[511:0], row_last, tensor_last` |
| weight release | A/B→C | `valid/ready`, complete token |

The complete token is `{epoch,group,global_q_head,row,slot_id,numeric_mode}`. Local `slot_id` remains two bits; cross-cluster identity is `{cluster_id, token}`.

All ready/valid payloads remain stable while stalled. Q/K/V responses and the V3 N+2 weight response have no `ready`; each cluster must retain adequate response capacity. Requests from different clusters are independent logical ports. If C maps them onto shared physical service, C must expose the arbitration/backpressure and include it in performance counters.

Q/K/V responses lack a complete epoch token. Therefore an epoch cannot be reused after reset/abort until C proves all old responses have drained or a C-owned isolation layer has discarded them. Comparing only `context_tag` is insufficient.

## 4. Error, halt, reset, and reuse

Each A3 error stream first enters an independent one-entry-or-deeper cluster buffer. The A4 output is a locked round-robin valid/ready stream:

```text
error_valid / error_ready
error_cluster_id[1:0]
error_source[1:0]
error_epoch[15:0]
error_group[2:0]
error_global_q_head[4:0]
error_row[6:0]
error_slot_id[1:0]
error_numeric_mode[1:0]
error_code[3:0]
error_bad_key[6:0]
```

The selected payload is locked while stalled. Simultaneous errors are buffered and eventually reported without overwrite when `error_ready` eventually returns. The faulting cluster stops accepting new commands. Whether other clusters finish in-flight work or halt is controlled by explicit C `halt/drain` policy; A does not publish normal compute done for an errored transaction.

Recovery order is: stop new commands, drain/cancel C outstanding service, assert coordinated clear, establish a new epoch, then restart. A local slot is reusable only after matching final release, no score/weight/Q/K/V outstanding work, and no buffered matching error. RAM data need not be reset; valid/owner/pending state must be reset.

## 5. Status and counters

Each cluster exposes a registered snapshot of the existing A3 counters plus:

```text
groups_accepted, groups_completed, groups_aborted,
last_local_context_accept_cycle, group_wait_cycles,
output_queue_stall_cycles, service_stall_cycles, active_cycles
```

Aggregate counters are sums of one coherent snapshot, not live combinational cross-cluster adders. Required normal full-workload totals are defined in `docs/CATS_R4_A4_FEASIBILITY.md`. Counter overflow is modulo 64 bits and must not occur in the fixed workload.

## 6. Performance boundary

Primary compute cycles are measured in the same `core_clk` domain from the first actual QK issue of the transaction through the cycle in which C accepts the last Context chunk: `cycles=end-start+1`. Release/drain cycles and C DDR transaction cycles are reported separately. N=1/N=2 comparisons require identical inputs, hashes, mode, clock, per-cluster lane count, service latencies, finite queue sizes, shared bandwidth, and output semantics.

The current 32-row canonical-output contract fails the architecture-model 1.6x gate. Full A4-2 performance READY is blocked until `A4-CANONICAL-OUTPUT` is accepted and implemented; small protocol/unit work is allowed.

