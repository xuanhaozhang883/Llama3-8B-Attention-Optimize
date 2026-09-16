# CATS-R4 A4 N=2 Integration Design

Date: 2026-09-16

Branch: `codex/a-cats-r4-a4-2cluster`

## Authority and scope

This design records the C/team-lead decision accepted by the user for continued P6 development. The declared C decision commit is `f3be77417c14c81321e6e8d2b0e8f6957e21ea8a` on `codex/cats-r4-local-integration`. That commit was not yet visible on `origin` when implementation began; the user explicitly authorized A to use it as the temporary frozen interface. This permits N=2 wrapper and protocol-model work, but it does not constitute C production RTL acceptance or A4-2 READY.

## Architecture

- The N=2 top contains two independent real `cats_r4_a4_compute_array` instances with static `CLUSTERS=2` and `CLUSTER_ID=0/1`.
- Transaction epoch and numeric mode are captured once by `cats_r4_a4_txn_fanout` and delivered exactly once to both clusters.
- Each cluster exposes independent Q, K, V, weight, and 512-bit Context logical service ports. These ports are not multiplexed at the compute-facing boundary.
- Each cluster owns complete four-head groups: cluster 0 owns groups 0,2,4,6 and cluster 1 owns groups 1,3,5,7.
- Completion and error events are buffered and joined by the existing reusable event join. Telemetry is captured locally and reduced only from coherent snapshots.

## Finite output model

- The protocol TB models one finite 512-row spool per cluster. A row is four 512-bit Context chunks, so each spool holds 2048 chunks.
- Cluster-local Context order is local group, global head, row, then feature block. Cross-cluster arrival may be globally out of order.
- A single shared canonical sink drains at most one 64-bit beat per cycle. Each 512-bit chunk consumes eight accepted sink beats.
- The A-side final Context-accept boundary is `context_valid[c] && context_ready[c]` at the local spool ingress.
- Full-spool backpressure affects only the owning cluster unless global halt is active.

## Completion and errors

- A normal group produces exactly one terminal `group_done` after 32 jobs, 32 Q-slab retires, 2048 accepted Context chunks, 512 final releases, free slots, no service outstanding state, and cluster quiescence.
- Root failure is reported as `group_done_error=1, group_done_aborted=0`.
- A peer cancelled by global halt is reported as `group_done_error=0, group_done_aborted=1`.
- Error and aborted are mutually exclusive; root error wins if both conditions are observed.
- Any cluster root error triggers global halt, stops new commands and requests, preserves the first root event, drains accepted outstanding work, and prevents normal transaction completion.

## Drain and epoch rules

- Normal `txn_drain_complete` is a registered level and requires all normal group completions, both clusters quiescent, empty request/response sidecars and FIFOs, empty local spools, idle canonical sink, no AXI outstanding work, empty completion/error buffers, and no sticky error.
- Abort drains all accepted requests. Epoch-tagged stale responses are consumed and dropped; responses without epoch use per-cluster per-channel request sidecars and a discard sink.
- Sidecars cannot be cleared and a new epoch cannot start while outstanding work remains.
- The next epoch is exactly the previous epoch plus one. `16'hffff` wrap requires hard reset.
- `counter_clear` is legal only while globally quiescent and changes counters only.

## Verification boundary

P6 protocol-model verification must cover simultaneous progress, asymmetric service stall, local spool full/backpressure, wrong owner/index, root-error global halt, peer abort, mid-flight outstanding requests, tagged and untagged late responses, terminal-event backpressure, drain gating, and epoch-wrap rejection. Aggregate normal-work counters are 8 groups, 256 jobs, 4096 rows, 16384 Context chunks, 524288 BF16 Context words, and 4096 final releases.

The result remains `P6 N=2 integration NOT READY pending C production boundary`. Performance, real-IP, OOC, route, and A4-2 READY claims remain outside this design.
