# CATS-R4 A3 Compute Cluster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and verify the member-A-owned single-cluster A3 wrapper that connects the Q-slab/QK path, A2 whole-row score handoff, a real three-slot BF16 score memory, B4 Softmax/PV, and frozen C-owned services, reaching A3 compute-unit/OOC READY.

**Architecture:** Keep arithmetic and owner boundaries intact: existing A2 produces formatted whole rows into an A-owned three-slot memory, existing B4 consumes the frozen row/score streams and talks to C-owned weight/V/Context services, and B4 `final_release` returns ownership to A2. The production wrapper contains no behavioral arithmetic substitutes; lightweight QK/B2/B3 models are compiled only in the full-workload protocol TB, while representative XSim and OOC use the real RTL and Floating Point IP.

**Tech Stack:** SystemVerilog 2012, PowerShell, Icarus Verilog, AMD Vivado/XSim 2025.2, Python 3.12, CATS-R4 Interface V3, BF16/FP32 Floating Point IP.

**Spec:** `docs/superpowers/specs/2026-09-13-cats-r4-a3-compute-cluster-design.md`

## Global Constraints

- Work only on branch `codex/a-cats-r4-a3-compute-cluster` in `C:\lhm\2_Work\Llama3-8B-Attention-Optimize-a3`.
- Integration base is `f9419e8d30d13f5aeba6cfeb6dd1403028f79d43`; preserve annotated tag `CATS_R4_INTERFACE_V3_COMMIT`, tag object `abe7492f5cd547d3128707b4b1405fcfca6909be`, tagged commit `4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`.
- Device is `xczu15eg-ffvb1156-2-i`; target clock is 150 MHz with period `6.666 ns`; Vivado root is `C:\Software\AMD\vivado25.2\2025.2\Vivado`.
- Icarus root is `C:\Software\iverilog`.
- Use `C:\Users\liuhe\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe`; plain `python` currently resolves to GTKWave's incomplete runtime and must not be used.
- Parameters remain `S=128`, `D=128`, `32Q/8KV`, `R=16`, QK/PV lanes `32`, score slots `3`, BF16 input/output.
- Do not modify B-owned Softmax/PV numeric internals, C-owned DMA/AXI/CDC/DDR/board modules, D-owned golden data or thresholds, the production manifest, or the Interface V3 tag.
- Every feature or defect fix follows red-green-refactor: add a failing test, observe the expected failure, add the minimum implementation, rerun the direct test and affected regressions, then commit.
- Full protocol/model evidence and representative real-IP evidence must be reported separately.
- A3 READY means compute-unit/OOC READY only; it does not mean C2 board/system, BIT/XSA/ELF, board test, or system performance READY.

---

## File Map

| Responsibility | File |
|---|---|
| Frozen design | `docs/superpowers/specs/2026-09-13-cats-r4-a3-compute-cluster-design.md` |
| A3 implementation plan | `docs/superpowers/plans/2026-09-13-cats-r4-a3-compute-cluster.md` |
| Actual B4↔V3 port mapping and accepted upstream SHAs | `docs/CATS_R4_A3_PORT_MAP_2026-09-13.md` |
| Q-slab engine-error recovery | `rtl/core/bc/qk/cats_r4_qk_q_slab_client.sv` |
| Q-slab recovery unit test | `tb/tb_cats_r4_qk_q_slab_client.sv` |
| Three-slot score storage | `rtl/core/bc/qk/cats_r4_qk_score_slot_mem.sv` |
| Score memory unit test | `tb/tb_cats_r4_qk_score_slot_mem.sv` |
| A2 + score-memory composition | `rtl/core/bc/integration/cats_r4_a3_row_frontend.sv` |
| Row frontend unit test | `tb/tb_cats_r4_a3_row_frontend.sv` |
| A-side/B4 error queue | `rtl/core/bc/integration/cats_r4_a3_error_join.sv` |
| Error queue unit test | `tb/tb_cats_r4_a3_error_join.sv` |
| Complete production compute cluster | `rtl/core/bc/integration/cats_r4_a3_compute_cluster.sv` |
| Directed real-module integration TB | `tb/tb_cats_r4_a3_compute_cluster.sv` |
| Random reset/abort/error TB | `tb/tb_cats_r4_a3_compute_cluster_stress.sv` |
| Test-only QK full protocol model | `tb/tb_cats_r4_a3_qk_protocol_model.sv` |
| Full 4096-row protocol TB | `tb/tb_cats_r4_a3_full_protocol.sv` |
| Icarus runners | `tests/run_cats_r4_a3_*.ps1` |
| Real-IP XSim/OOC runner | `tests/run_cats_r4_a3_realip_vivado.ps1` |
| OOC synthesis/route flow | `scripts/cats_r4_a3_compute_cluster_ooc.tcl` |
| Evidence consistency gate | `tests/check_cats_r4_a3_readiness.py` |
| Evidence consistency unit tests | `tests/test_check_cats_r4_a3_readiness.py` |
| Row/online comparison gate | `python/cats_r4_a3_ablation_gate.py` |
| Delivery record | `docs/CATS_R4_A3_COMPUTE_CLUSTER_DELIVERY_2026-09-13.md` |

## Task 1: Accept B4 and Freeze the Actual Integration Baseline

**Files:**
- Create: `docs/CATS_R4_A3_PORT_MAP_2026-09-13.md`
- Verify: `docs/CATS_R4_B4_DELIVERY_2026-09-13.md`
- Verify: `rtl/core/bc/integration/cats_r4_b4_softmax_pv_cluster.sv`

**Interfaces:**
- Consumes: B contract `eb70525918b36573e0ec31a31459c0a3c0120b62`, B2 `a59a214711c3b3c9693662c892d011e5026c0419`, B3 `07a1c87239349ae7bfe986ad78694f88f1f6fe93`, B4 `18cdd2335bfa60927b1fbb466020561681f725eb`, Interface V3 tagged commit `4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`.
- Produces: a fixed post-cherry-pick HEAD, an exact port ownership table, and clean pre-A3 regression evidence.

- [ ] **Step 1: Verify the branch and clean worktree**

Run:

```powershell
git branch --show-current
git status --short
git rev-parse HEAD
git rev-parse 'CATS_R4_INTERFACE_V3_COMMIT^{commit}'
```

Expected: branch is `codex/a-cats-r4-a3-compute-cluster`, status is clean, and the interface commit is `4d386e0f8f39c9f3c6de5ffa2ced408f254146ee`.

- [ ] **Step 2: Cherry-pick the four accepted B commits in order**

Run:

```powershell
git cherry-pick eb70525918b36573e0ec31a31459c0a3c0120b62
git cherry-pick a59a214711c3b3c9693662c892d011e5026c0419
git cherry-pick 07a1c87239349ae7bfe986ad78694f88f1f6fe93
git cherry-pick 18cdd2335bfa60927b1fbb466020561681f725eb
```

Expected: four successful cherry-picks. Do not cherry-pick `a26cdc5ee64e12884fc9e529213ba6630202356b`; the integration lineage already contains the corresponding A-side abort/cancel repair.

- [ ] **Step 3: Audit accepted paths and identities**

Run:

```powershell
git log --oneline --decorate -8
git diff --name-status f9419e8d30d13f5aeba6cfeb6dd1403028f79d43..HEAD
git show -s --format='%H %P %s' HEAD
```

Expected: B-owned changes are under `rtl/core/bc/softmax`, `rtl/core/bc/pv`, `rtl/core/bc/integration`, their TB/scripts/docs/model paths, plus the already committed A3 documents. No C board/CDC/DMA path is newly modified.

- [ ] **Step 4: Run the pre-A3 A/B/C protocol baseline**

Run:

```powershell
$a3Icarus = 'C:\Software\iverilog'
& tests\run_cats_r4_qk_32lane_engine_iverilog.ps1 -IcarusRoot $a3Icarus
& tests\run_cats_r4_qk_q_slab_client_iverilog.ps1 -IcarusRoot $a3Icarus
& tests\run_cats_r4_qk_score_formatter_iverilog.ps1 -IcarusRoot $a3Icarus
& tests\run_cats_r4_qk_row_handoff_wrapper_iverilog.ps1 -IcarusRoot $a3Icarus
& tests\run_cats_r4_qk_ab_handoff_iverilog.ps1 -IcarusRoot $a3Icarus
& tests\run_cats_r4_b4_multicluster_iverilog.ps1 -IcarusRoot $a3Icarus -Clusters 1 -Mode 0 -GlobalHeads 4 -RowsPerHead 2
& tests\run_cats_r4_b4_multicluster_iverilog.ps1 -IcarusRoot $a3Icarus -Clusters 1 -Mode 1 -GlobalHeads 4 -RowsPerHead 2
& tests\run_cats_r4_c_unit_checks.ps1 -IcarusRoot $a3Icarus
```

Expected markers include A Q-slab `slabs=256 engine_jobs=6144`, A→B `rows=4096 causal_scores=264192`, two B4 arithmetic-smoke PASS lines, and `C unit suite: 16` PASS.

- [ ] **Step 5: Run the pre-A3 A2 vendor-simulator baseline**

Run:

```powershell
& tests\run_cats_r4_qk_a2_row_pipeline_xsim.ps1 `
  -VivadoRoot 'C:\Software\AMD\vivado25.2\2025.2\Vivado'
```

Expected: `PASS: CATS-R4 A2 raw FP32 through BF16 RNE row/max A-to-B pipeline`.

- [ ] **Step 6: Write the exact port map**

Create `docs/CATS_R4_A3_PORT_MAP_2026-09-13.md` with these sections and facts:

```markdown
# CATS-R4 A3 Port Map

## Accepted identities
- integration base: f9419e8d30d13f5aeba6cfeb6dd1403028f79d43
- B source head: 18cdd2335bfa60927b1fbb466020561681f725eb
- interface tagged commit: 4d386e0f8f39c9f3c6de5ffa2ced408f254146ee
- local accepted head: output of `git rev-parse HEAD`

## Direct connections
| Producer | Consumer | Channels |
|---|---|---|
| q_slab_client | qk_32lane_engine | engine_start, engine_done |
| qk_32lane_engine | a3_row_frontend | raw score vector and context_tag 0..2 |
| a3_row_frontend | b4_softmax_pv_cluster | row, score |
| b4_softmax_pv_cluster | a3_row_frontend | final_release |
| b4_softmax_pv_cluster | C service | weight write/commit/read/release, pv_row, V, Context |
| A-side arbiter and B4 | a3_error_join | tokenized error streams |

## Latency and backpressure
- score memory response: one registered response, held until ready
- C weight response: fixed N+2, non-backpressured response as frozen by Interface V3
- V response: tagged response; request is backpressured, response is consumed by B4
- Context, row, score, final_release and unified error hold all payload fields while stalled
```

Add the following exact frozen field lists below the table; do not rename any of them in the production wrapper:

```text
A→B row: row_valid,row_ready,row_epoch,row_group,row_global_q_head,
         row_index,row_slot_id,row_numeric_mode,row_max_bf16
A→B score: score_valid,score_ready,score_epoch,score_group,
           score_global_q_head,score_row,score_slot_id,
           score_numeric_mode,score_key,score_bf16,score_last
B→C weight write: weight_wr_valid,weight_wr_ready,weight_wr_epoch,
                  weight_wr_group,weight_wr_global_q_head,weight_wr_row,
                  weight_wr_slot_id,weight_wr_numeric_mode,weight_wr_key,
                  weight_wr_mask,weight_wr_data,weight_wr_last
B→C row commit: row_commit_valid,row_commit_ready,row_commit_epoch,
                row_commit_group,row_commit_global_q_head,row_commit_row,
                row_commit_slot_id,row_commit_numeric_mode,
                row_commit_sum_fp32,row_commit_inv_sum_fp32
C→B PV row: pv_row_valid,pv_row_ready,pv_row_epoch,pv_row_group,
            pv_row_global_q_head,pv_row_row,pv_row_slot_id,
            pv_row_numeric_mode,pv_row_sum_fp32,pv_row_inv_sum_fp32
B↔C weight read: weight_rd_req_valid,weight_rd_req_ready,
                 weight_rd_req_epoch,weight_rd_req_group,
                 weight_rd_req_global_q_head,weight_rd_req_row,
                 weight_rd_req_slot_id,weight_rd_req_numeric_mode,
                 weight_rd_req_key,weight_rd_rsp_valid,
                 weight_rd_rsp_epoch,weight_rd_rsp_group,
                 weight_rd_rsp_global_q_head,weight_rd_rsp_row,
                 weight_rd_rsp_slot_id,weight_rd_rsp_numeric_mode,
                 weight_rd_rsp_key,weight_rd_rsp_mask,weight_rd_rsp_data
V service: v_req_valid,v_req_ready,v_req_context_tag,v_req_key,
           v_req_feature_block,v_rsp_valid,v_rsp_context_tag,v_rsp_vec_bf16
Context: out_valid,out_ready,out_epoch,out_seq,out_global_q_head,out_row,
         out_feature_block,out_data_bf16,out_row_last,out_tensor_last
Release: weight_release_valid,weight_release_ready,weight_release_epoch,
         weight_release_group,weight_release_global_q_head,
         weight_release_row,weight_release_slot_id,
         weight_release_numeric_mode,final_release_valid,
         final_release_ready,final_release_epoch,final_release_group,
         final_release_global_q_head,final_release_row,
         final_release_slot_id,final_release_numeric_mode
Unified error: error_valid,error_ready,error_source,error_epoch,error_group,
               error_global_q_head,error_row,error_slot_id,
               error_numeric_mode,error_code,error_bad_key
```

- [ ] **Step 7: Commit the baseline record**

Run:

```powershell
git add docs/CATS_R4_A3_PORT_MAP_2026-09-13.md
git diff --cached --check
git commit -m "docs(a3): record accepted B4 integration baseline"
```

## Task 2: Make Q-slab Engine Errors Recoverable

**Files:**
- Modify: `rtl/core/bc/qk/cats_r4_qk_q_slab_client.sv`
- Modify: `tb/tb_cats_r4_qk_q_slab_client.sv`
- Verify: `tests/run_cats_r4_qk_q_slab_client_iverilog.ps1`

**Interfaces:**
- Consumes: existing `engine_done_*` handshake.
- Produces: `engine_error_valid/ready`, failure job token, `engine_errors`, `error_reports`; error code `3'd7` is assigned later by the A-side arbiter.

- [ ] **Step 1: Add a failing matched-error test**

Add ports to the TB and instantiate them by name. After one legal engine start, send a matching completion with `engine_done_error=1`. Keep `engine_error_ready=0` for three cycles and assert:

```systemverilog
if (!engine_error_valid ||
    engine_error_epoch != 16'h3303 ||
    engine_error_group != 3'd2 ||
    engine_error_global_q_head != 5'd9 ||
    engine_error_row_window != 3'd5 ||
    engine_error_row_offset != 4'd0 ||
    engine_error_row_count != 5'd3 ||
    engine_error_key_block != 2'd0)
    $fatal(1, "matched engine error payload mismatch");
if (engine_start_valid || q_slab_retire_valid)
    $fatal(1, "engine error advanced before report acceptance");
```

Then accept the error, accept exactly one Q-slab retire, verify `job_ready==0` until `clear`, pulse `clear`, and verify `job_ready==1`, `engine_errors==1`, `error_reports==1`.

- [ ] **Step 2: Run the test and observe the intended failure**

Run:

```powershell
& tests\run_cats_r4_qk_q_slab_client_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
```

Expected: compile failure because `engine_error_*` ports do not exist, or runtime failure because the old implementation remains in `ST_WAIT_DONE`.

- [ ] **Step 3: Add explicit error and fault states**

Extend the state enum with `ST_ERROR=3'd6` and `ST_FAULT=3'd7`. Add these exact ports:

```systemverilog
output logic        engine_error_valid,
input  logic        engine_error_ready,
output logic [15:0] engine_error_epoch,
output logic [2:0]  engine_error_group,
output logic [4:0]  engine_error_global_q_head,
output logic [2:0]  engine_error_row_window,
output logic [3:0]  engine_error_row_offset,
output logic [4:0]  engine_error_row_count,
output logic [1:0]  engine_error_key_block,
output logic [63:0] engine_errors,
output logic [63:0] error_reports,
```

Separate token matching from success:

```systemverilog
assign done_token_match =
    engine_done_epoch == token_epoch &&
    engine_done_group == token_group &&
    engine_done_global_q_head == token_head &&
    engine_done_row_window == token_window &&
    engine_done_row_offset == row_offset &&
    engine_done_row_count == row_count &&
    engine_done_key_block == key_block;

assign engine_error_valid = state == ST_ERROR;
assign engine_error_epoch = token_epoch;
assign engine_error_group = token_group;
assign engine_error_global_q_head = token_head;
assign engine_error_row_window = token_window;
assign engine_error_row_offset = row_offset;
assign engine_error_row_count = row_count;
assign engine_error_key_block = key_block;
```

On `engine_done_valid && engine_done_ready && done_token_match && engine_done_error`, increment `engine_errors` once and enter `ST_ERROR`. On the error handshake, increment `error_reports` and enter `ST_RETIRE`. After the retire handshake enter `ST_FAULT`; only reset/clear leaves `ST_FAULT`. A stale token still increments the existing protocol/epoch counters and remains in `ST_WAIT_DONE`.

- [ ] **Step 4: Run direct and neighboring regressions**

Run:

```powershell
& tests\run_cats_r4_qk_q_slab_client_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_qk_32lane_engine_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
```

Expected: both PASS, including the unchanged full lifecycle `slabs=256 engine_jobs=6144` and the new matched-error recovery case.

- [ ] **Step 5: Commit**

Run:

```powershell
git add rtl/core/bc/qk/cats_r4_qk_q_slab_client.sv tb/tb_cats_r4_qk_q_slab_client.sv
git diff --cached --check
git commit -m "fix(a3): retire q-slab jobs on engine error"
```

## Task 3: Implement the Three-slot BF16 Score Memory

**Files:**
- Create: `rtl/core/bc/qk/cats_r4_qk_score_slot_mem.sv`
- Create: `tb/tb_cats_r4_qk_score_slot_mem.sv`
- Create: `tests/run_cats_r4_qk_score_slot_mem_iverilog.ps1`

**Interfaces:**
- Consumes: A2 `store_wr_*` vector writes and `score_rd_req_*` scalar reads.
- Produces: A2 `score_rd_rsp_*`, one held response, and counters `write_vectors`, `write_scores`, `read_requests`, `read_responses`, `read_stall_cycles`, `protocol_errors`.

- [ ] **Step 1: Write the failing score-memory TB**

The TB must write distinct values to all three slots, issue scalar reads, and verify token/data stability for four stalled cycles. Use this value rule:

```systemverilog
function automatic logic [15:0] expected_score(
    input logic [1:0] slot,
    input logic [6:0] key
);
    expected_score = 16'h3c00 + {7'd0, slot, key};
endfunction
```

For each slot and key block, drive `wr_lane_valid[lane] = key_base+lane <= row`, then read `key=0..row`. Assert `read_requests==read_responses`, `write_scores` equals the number of set lane bits, an invalid slot never handshakes, and `clear` removes a pending response without requiring RAM payload reset.

- [ ] **Step 2: Run the test and observe the missing-module failure**

Run:

```powershell
& tests\run_cats_r4_qk_score_slot_mem_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
```

Expected: compile failure naming missing module `cats_r4_qk_score_slot_mem`.

- [ ] **Step 3: Implement the storage and registered response**

Use the A2 port names without an adapter. The storage is three independent 128-entry BF16 arrays:

```systemverilog
(* ram_style = "distributed" *) logic [15:0] slot_mem_0 [0:127];
(* ram_style = "distributed" *) logic [15:0] slot_mem_1 [0:127];
(* ram_style = "distributed" *) logic [15:0] slot_mem_2 [0:127];

assign rsp_can_accept = !score_rd_rsp_valid || score_rd_rsp_ready;
assign score_rd_req_ready = rsp_can_accept && score_rd_req_slot_id < 3;
assign store_wr_ready = store_wr_slot_id < 3 &&
                        store_wr_key_base[4:0] == 5'd0;
```

On a write handshake, loop over the 32 lanes and write only set `store_wr_lane_valid` bits. On a read handshake, capture every request token and selected memory value into the response register. When `score_rd_rsp_valid && !score_rd_rsp_ready`, do not change any response field. Reset/clear only `score_rd_rsp_valid` and counters/state; do not reset the payload arrays.

- [ ] **Step 4: Add simulation assertions**

Under `` `ifndef SYNTHESIS ``, assert:

```systemverilog
if (held_rsp && (!score_rd_rsp_valid || rsp_payload != held_rsp_payload))
    $fatal(1, "A3 score response changed while stalled");
if (store_wr_valid && store_wr_slot_id >= 3)
    $fatal(1, "A3 score write used invalid slot");
if (score_rd_req_valid && score_rd_req_slot_id >= 3)
    $fatal(1, "A3 score read used invalid slot");
```

- [ ] **Step 5: Run the direct test and A2 handoff regression**

Run:

```powershell
& tests\run_cats_r4_qk_score_slot_mem_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_qk_ab_handoff_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
```

Expected: score memory PASS and A→B `rows=4096 causal_scores=264192` PASS.

- [ ] **Step 6: Commit**

Run:

```powershell
git add rtl/core/bc/qk/cats_r4_qk_score_slot_mem.sv tb/tb_cats_r4_qk_score_slot_mem.sv tests/run_cats_r4_qk_score_slot_mem_iverilog.ps1
git diff --cached --check
git commit -m "feat(a3): add three-slot score memory"
```

## Task 4: Compose A2 with the Physical Score Memory

**Files:**
- Create: `rtl/core/bc/integration/cats_r4_a3_row_frontend.sv`
- Create: `tb/tb_cats_r4_a3_row_frontend.sv`
- Create: `tests/run_cats_r4_a3_row_frontend_iverilog.ps1`

**Interfaces:**
- Consumes: `txn_start_*`, raw QK vector stream, B4 `final_release_*`.
- Produces: frozen B4 `row_*` and `score_*`, A2 `row_abort_*`, `slot_owner`, and score-memory/A2 counters.

- [ ] **Step 1: Write a failing three-row frontend test**

Drive raw score vectors for rows 0, 1, and 2 with context tags 0, 1, and 2. For each row send key blocks 0 through 3; lane validity is `key<=row`. Check:

```systemverilog
if (b_score_key != expected_key)
    $fatal(1, "A3 frontend score order mismatch");
if (b_score_last != (b_score_key == b_score_row))
    $fatal(1, "A3 frontend last mismatch");
if (b_row_max_bf16 != expected_max[b_row_slot_id])
    $fatal(1, "A3 frontend row max mismatch");
```

After releasing slot 0, drive row 127 through that slot with its largest finite score at key 127 and assert that `row_max_bf16` equals the formatted key-127 value. Stall `b_row_ready`, `b_score_ready`, and `final_release_ready` independently; verify all payloads remain stable. Verify a slot cannot accept a new row until its matching final release handshakes.

- [ ] **Step 2: Run and observe missing-module failure**

Run:

```powershell
& tests\run_cats_r4_a3_row_frontend_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
```

Expected: compile failure naming `cats_r4_a3_row_frontend`.

- [ ] **Step 3: Instantiate A2 and score memory with direct named wiring**

`cats_r4_a3_row_frontend` must instantiate exactly:

```systemverilog
cats_r4_qk_a2_row_pipeline #(
    .SEQ_LEN(128), .LANES(32), .SLOTS(3), .SCALE_FP32(SCALE_FP32)
) u_a2 (
    .clk, .rst_n, .clear, .counter_clear,
    .txn_start_valid, .txn_start_ready, .txn_epoch,
    .txn_numeric_mode,
    .raw_score_valid(raw_score_to_a2_valid),
    .raw_score_ready(raw_score_to_a2_ready),
    .raw_score_epoch, .raw_score_group,
    .raw_score_global_q_head, .raw_score_row,
    .raw_score_key_block, .raw_score_context_tag,
    .raw_score_lane_valid, .raw_score_fp32,
    .store_wr_valid, .store_wr_ready, .store_wr_slot_id,
    .store_wr_key_base, .store_wr_lane_valid,
    .store_wr_score_bf16,
    .score_rd_req_valid, .score_rd_req_ready,
    .score_rd_req_epoch, .score_rd_req_group,
    .score_rd_req_global_q_head, .score_rd_req_row,
    .score_rd_req_key, .score_rd_req_slot_id,
    .score_rd_req_numeric_mode,
    .score_rd_rsp_valid, .score_rd_rsp_ready,
    .score_rd_rsp_epoch, .score_rd_rsp_group,
    .score_rd_rsp_global_q_head, .score_rd_rsp_row,
    .score_rd_rsp_key, .score_rd_rsp_slot_id,
    .score_rd_rsp_numeric_mode, .score_rd_rsp_bf16,
    .b_row_valid, .b_row_ready, .b_row_epoch, .b_row_group,
    .b_row_global_q_head, .b_row_index, .b_row_slot_id,
    .b_row_numeric_mode, .b_row_max_bf16,
    .b_score_valid, .b_score_ready, .b_score_epoch,
    .b_score_group, .b_score_global_q_head, .b_score_row,
    .b_score_key, .b_score_slot_id, .b_score_numeric_mode,
    .b_score_bf16, .b_score_last,
    .final_release_valid, .final_release_ready,
    .final_release_epoch, .final_release_group,
    .final_release_global_q_head, .final_release_row,
    .final_release_slot_id, .final_release_numeric_mode,
    .row_abort_valid, .row_abort_ready, .row_abort_epoch,
    .row_abort_group, .row_abort_global_q_head,
    .row_abort_row, .row_abort_error_key, .row_abort_slot_id,
    .row_abort_numeric_mode, .row_abort_error_code,
    .slot_owner, .rows_completed, .scores_transferred,
    .rows_transferred, .aborts, .owner_errors,
    .scale_requests_accepted, .scale_products_completed,
    .score_format_transfers, .formatter_protocol_errors,
    .protocol_error_sticky(a2_protocol_error_sticky)
);

cats_r4_qk_score_slot_mem u_score_mem (
    .clk, .rst_n, .clear, .counter_clear,
    .store_wr_valid, .store_wr_ready,
    .store_wr_slot_id, .store_wr_key_base,
    .store_wr_lane_valid, .store_wr_score_bf16,
    .score_rd_req_valid, .score_rd_req_ready,
    .score_rd_req_epoch, .score_rd_req_group,
    .score_rd_req_global_q_head, .score_rd_req_row,
    .score_rd_req_key, .score_rd_req_slot_id,
    .score_rd_req_numeric_mode,
    .score_rd_rsp_valid, .score_rd_rsp_ready,
    .score_rd_rsp_epoch, .score_rd_rsp_group,
    .score_rd_rsp_global_q_head, .score_rd_rsp_row,
    .score_rd_rsp_key, .score_rd_rsp_slot_id,
    .score_rd_rsp_numeric_mode, .score_rd_rsp_bf16,
    .write_vectors(score_write_vectors),
    .write_scores(score_write_scores),
    .read_requests(score_read_requests),
    .read_responses(score_read_responses),
    .read_stall_cycles(score_read_stall_cycles),
    .protocol_errors(score_memory_errors),
    .protocol_error_sticky(score_memory_error_sticky)
);
```

Use explicit named connections in the actual file; do not use positional ports or `.*`.

- [ ] **Step 4: Encode and assert the scheduler-to-slot invariant**

The Q-slab client launches row counts `3,3,3,3,3,1`; therefore valid engine score context tags are `0..2`. Add:

```systemverilog
assign raw_score_to_a2_valid = raw_score_valid && raw_score_context_tag < 3;
assign raw_score_ready = raw_score_context_tag < 3 ?
                         raw_score_to_a2_ready : 1'b0;

always_ff @(posedge clk)
    if (rst_n && !clear && raw_score_valid && raw_score_context_tag >= 3)
        context_slot_errors <= context_slot_errors + 1'b1;
```

The invalid-tag negative test must observe the counter/sticky error and no score-memory write. Task 6 intercepts the same invalid engine-score tag before the frontend and converts it into A-side error code `3'd7`; it must never remap tag 3 to slot 0.

- [ ] **Step 5: Run direct and A2 regressions**

Run:

```powershell
& tests\run_cats_r4_a3_row_frontend_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_qk_row_handoff_wrapper_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_qk_slot_lifecycle_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
```

Expected: frontend PASS, normal A2 handoff PASS, and three-slot abort/reuse PASS.

- [ ] **Step 6: Commit**

Run:

```powershell
git add rtl/core/bc/integration/cats_r4_a3_row_frontend.sv tb/tb_cats_r4_a3_row_frontend.sv tests/run_cats_r4_a3_row_frontend_iverilog.ps1
git diff --cached --check
git commit -m "feat(a3): bind A2 to physical score slots"
```

## Task 5: Implement the Buffered A-side/B4 Error Join

**Files:**
- Create: `rtl/core/bc/integration/cats_r4_a3_error_join.sv`
- Create: `tb/tb_cats_r4_a3_error_join.sv`
- Create: `tests/run_cats_r4_a3_error_join_iverilog.ps1`

**Interfaces:**
- Consumes: one A-side valid/ready stream with 3-bit code and one B4 stream with 4-bit code.
- Produces: one unified valid/ready stream with `source=0` for A-side and `source=1` for B4; two independent one-entry input buffers.

- [ ] **Step 1: Write simultaneous-error and stall tests**

Present A-side and B4 errors in the same cycle while `out_ready=0`. Verify both input handshakes occur when both buffers are empty, the first output is A-side, the second output is B4, and all output fields remain unchanged during four stalled cycles. Then keep both sources continuously valid for eight accepted outputs and assert neither source waits for more than one opposing transfer.

- [ ] **Step 2: Run and observe the missing-module failure**

Run:

```powershell
& tests\run_cats_r4_a3_error_join_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
```

Expected: compile failure naming `cats_r4_a3_error_join`.

- [ ] **Step 3: Implement two skid buffers and fair deterministic arbitration**

Use one payload register per source. Reset arbitration prefers A-side. When both buffers are occupied, choose A-side if `prefer_b==0`, otherwise B4. Toggle preference only after a successful output transfer:

```systemverilog
assign a_ready = !a_buf_valid || (out_fire && select_a);
assign b_ready = !b_buf_valid || (out_fire && select_b);
assign select_a = a_buf_valid && (!b_buf_valid || !prefer_b);
assign select_b = b_buf_valid && (!a_buf_valid ||  prefer_b);
assign out_valid = select_a || select_b;
assign out_source = select_b ? 2'd1 : 2'd0;
assign out_error_code = select_b ? b_buf_code : {1'b0, a_buf_code};
```

Capture a replacement input in the same cycle its selected buffer drains. If both arrive into empty buffers on the same cycle, both are retained and A-side appears first. The complete payload tuple is `{epoch,group,head,row,slot,mode,code,bad_key}`.

- [ ] **Step 4: Add counter and stability assertions**

Provide `a_errors_accepted`, `b_errors_accepted`, `errors_delivered`, `simultaneous_errors`, and `error_stall_cycles`. Assert:

```systemverilog
if (out_was_stalled && (!out_valid || out_payload != held_out_payload))
    $fatal(1, "A3 unified error changed while stalled");
if (errors_delivered > a_errors_accepted + b_errors_accepted)
    $fatal(1, "A3 unified error counter conservation failed");
```

- [ ] **Step 5: Run and commit**

Run:

```powershell
& tests\run_cats_r4_a3_error_join_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
git add rtl/core/bc/integration/cats_r4_a3_error_join.sv tb/tb_cats_r4_a3_error_join.sv tests/run_cats_r4_a3_error_join_iverilog.ps1
git diff --cached --check
git commit -m "feat(a3): join A-side and B4 errors"
```

Expected: simultaneous capture, A-side-first ordering, fairness, and stalled-payload tests PASS.

## Task 6: Build the Complete A3 Production Wrapper

**Files:**
- Create: `rtl/core/bc/integration/cats_r4_a3_compute_cluster.sv`
- Create: `tb/tb_cats_r4_a3_compute_cluster.sv`
- Create: `tests/run_cats_r4_a3_compute_cluster_iverilog.ps1`

**Interfaces:**
- Consumes: transaction/job control, Q-slab service, Q/K/V services, C weight service, Context backpressure, clear/reset.
- Produces: Context output, C weight transactions, unified error, completion/retire, slot owner and A/B telemetry.

- [ ] **Step 1: Write the failing directed integration TB**

Compile the real Q-slab client, QK engine, row frontend, B4 wrapper, B2/B3 RTL, A3 error join, and B4 C weight model. Use Q/K responses that make all scores zero and V responses of BF16 `1.0`. Drive one head/window and both numeric modes in separate reset-clean runs. Check three rows in flight, ordered Context chunks, three matching final releases, and no normal errors.

- [ ] **Step 2: Run and observe the missing-top failure**

Run:

```powershell
& tests\run_cats_r4_a3_compute_cluster_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 0
```

Expected: compile failure naming `cats_r4_a3_compute_cluster`.

- [ ] **Step 3: Instantiate the six production stages**

The top must instantiate these exact production modules and no test model:

| Instance | Module | Exact connection groups |
|---|---|---|
| `u_q_slab_client` | `cats_r4_qk_q_slab_client` | `job_*`, `q_slab_need_*`, `q_slab_ready_*`, `engine_start_*`, `engine_done_*`, `engine_error_*`, `q_slab_retire_*`, client counters |
| `u_qk_engine` | `cats_r4_qk_32lane_engine` | client `engine_start_*`, client `engine_done_*`, external `q_req_*`, external `q_rsp_*`, external `k_req_*`, external `k_rsp_*`, frontend raw-score stream, engine counters |
| `u_row_frontend` | `cats_r4_a3_row_frontend` | transaction mode, engine raw-score stream, B4 row/score stream, B4 final release, A2 row abort, slot owner and A2/memory counters |
| `u_a_side_error_arbiter` | `cats_r4_qk_row_abort_arbiter` | input `a` is A2 row abort, input `b` is combined QK/client invariant error, output is A-side error stream |
| `u_error_join` | `cats_r4_a3_error_join` | A-side error stream, B4 `row_error_*`, unified stable C-facing error stream, error counters |
| `u_b4` | `cats_r4_b4_softmax_pv_cluster` | frontend row/score, C `weight_wr_*`, `row_commit_*`, `pv_row_*`, `weight_rd_req_*`, `weight_rd_rsp_*`, `v_req_*`, `v_rsp_*`, `out_*`, `weight_release_*`, frontend `final_release_*`, B4 counters |

Every instance must use explicit named connections. Positional ports and wildcard `.*` are prohibited in this wrapper.

Wire `u_q_slab_client.engine_start_*` to the engine. Because the engine done interface omits row offset/count, feed the still-held client launch fields into the matching done fields:

```systemverilog
assign client_done_row_offset = client_start_row_offset;
assign client_done_row_count  = client_start_row_count;
```

Wire engine scores directly to the row frontend. Wire frontend row/score to B4, B4 `final_release_*` back to the frontend, and every B4 C-owned port unchanged to the top-level external service interface.

- [ ] **Step 4: Merge QK and A2 errors inside A-side ownership**

Connect QK engine error as input `b` of `cats_r4_qk_row_abort_arbiter`, giving it priority over a simultaneous A2 row abort. Derive its diagnostic token as:

```systemverilog
assign qk_error_row = {qk_error_row_window, 4'b0000} + qk_error_row_offset;
assign qk_error_slot = 2'd0;
assign qk_error_mode = txn_numeric_mode_locked;
assign qk_error_code = 3'd7;
assign qk_error_key = {qk_error_key_block, 5'b00000};
```

Build `qk_error_valid` from a matched client engine error or an invalid engine score context. A matched client error has priority. For an invalid context, use the engine score token, error code `3'd7`, and `bad_key={raw_score_key_block,5'b0}`. Connect readiness exactly as follows:

```systemverilog
assign invalid_context_valid = engine_score_valid &&
                               engine_score_context_tag >= 3;
assign qk_error_valid = client_engine_error_valid || invalid_context_valid;
assign client_engine_error_ready = qk_error_ready;
assign engine_score_ready = invalid_context_valid ?
                            (!client_engine_error_valid && qk_error_ready) :
                            frontend_raw_score_ready;
assign frontend_raw_score_valid = engine_score_valid &&
                                  !invalid_context_valid &&
                                  !qk_fault_hold;
```

Set `qk_fault_hold` on the QK error handshake. While held, reject new jobs and raw score transfers. Clear it only on reset/clear. Feed the A-side arbiter output to `cats_r4_a3_error_join`; feed B4 `row_error_*` to the B4 input.

- [ ] **Step 5: Lock numeric mode and add transaction assertions**

Capture mode only on `txn_start_valid && txn_start_ready`. Keep it unchanged until clear. Assert that accepted job/error/row/release tokens use the locked mode and that accepted engine launches have `row_count<=3`.

- [ ] **Step 6: Add base telemetry**

Implement a free-running 64-bit cycle counter cleared by reset/counter_clear. Capture `first_issue_cycle` on the first engine-start handshake and `last_commit_cycle` on `out_valid && out_ready && out_tensor_last`. Count occupancy for each slot from `slot_owner[1:0]`, `[3:2]`, and `[5:4]`; count row/score, weight, V, output, error, and final-release stalls from their valid-without-ready conditions. Export the existing counters with unambiguous top-level names: `q_slab_jobs_accepted`, `engine_jobs_started`, `qk_valid_macs`, `rows_transferred`, `scores_transferred`, `b2_exp_commit`, `b2_weight_writes`, `b3_pv_commit`, `b3_context_words`, and `final_release_count`.

- [ ] **Step 7: Run both modes and direct component regressions**

Run:

```powershell
& tests\run_cats_r4_a3_compute_cluster_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 0
& tests\run_cats_r4_a3_compute_cluster_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 1
& tests\run_cats_r4_a3_row_frontend_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_a3_error_join_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
```

Expected: both modes produce ordered Context and final-release PASS; direct frontend and error-join tests remain PASS.

- [ ] **Step 8: Commit**

Run:

```powershell
git add rtl/core/bc/integration/cats_r4_a3_compute_cluster.sv tb/tb_cats_r4_a3_compute_cluster.sv tests/run_cats_r4_a3_compute_cluster_iverilog.ps1
git diff --cached --check
git commit -m "feat(a3): connect single-cluster compute pipeline"
```

## Task 7: Close Random Backpressure, Reset, Abort, and Error Paths

**Files:**
- Create: `tb/tb_cats_r4_a3_compute_cluster_stress.sv`
- Create: `tests/run_cats_r4_a3_compute_cluster_stress_iverilog.ps1`
- Modify: `rtl/core/bc/integration/cats_r4_a3_compute_cluster.sv`

**Interfaces:**
- Consumes: complete A3 wrapper from Task 6.
- Produces: reproducible stress evidence for seeds `7`, `19`, `73`, `101` and both numeric modes.

- [ ] **Step 1: Write the failing stress scenarios**

The TB must run these named phases in order and print a PASS marker per phase:

```text
fill_three_slots
independent_weight_v_output_release_backpressure
reset_with_pending_score_response
clear_with_old_epoch_qk_response
qk_engine_error_report_retire_clear_restart
a2_nonfinite_score_abort
b4_score_token_error
simultaneous_a_side_and_b4_error
slot_reuse_after_final_release
```

The normal phases must include row 0, row 127, a three-row batch, and a final one-row batch. Use a 32-bit LFSR seeded from the runner. Whenever any output valid is stalled, save and compare its full payload on every following cycle. Track allocate/handoff/release/abort counts per slot and assert no count becomes negative and no allocation occurs while ownership is non-FREE.

- [ ] **Step 2: Run the new stress suite and record the first real failure**

Run:

```powershell
& tests\run_cats_r4_a3_compute_cluster_stress_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 0 -Seed 7
```

Expected: at least one phase fails before the top-level control is hardened; retain the failing phase and seed in the log.

- [ ] **Step 3: Add only wrapper-owned recovery gates required by the failures**

Permitted changes are limited to A3 top-level gating, A-side error arbitration, pending-output holds, and telemetry. Do not change B2/B3 arithmetic or C memory semantics. Required invariants are:

```systemverilog
assert (!(job_valid && job_ready && qk_fault_hold));
assert (!(raw_score_valid && raw_score_ready && qk_fault_hold));
assert (!(final_release_valid && final_release_ready && final_release_slot_id >= 3));
assert (slot0_allocations == slot0_releases + slot0_aborts + slot0_live);
assert (slot1_allocations == slot1_releases + slot1_aborts + slot1_live);
assert (slot2_allocations == slot2_releases + slot2_aborts + slot2_live);
```

If a failure requires a B/C internal change, stop that phase with a minimal reproducer and owner-facing issue; do not patch the owner module in this commit.

- [ ] **Step 4: Run the full seed/mode matrix**

Run:

```powershell
foreach ($a3Mode in 0,1) {
  foreach ($a3Seed in 7,19,73,101) {
    & tests\run_cats_r4_a3_compute_cluster_stress_iverilog.ps1 `
      -IcarusRoot 'C:\Software\iverilog' -Mode $a3Mode -Seed $a3Seed
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
}
```

Expected: 8 runs PASS, every named phase appears once per run, normal phases have zero error counters, and negative phases report only their specified increment.

- [ ] **Step 5: Commit**

Run:

```powershell
git add rtl/core/bc/integration/cats_r4_a3_compute_cluster.sv tb/tb_cats_r4_a3_compute_cluster_stress.sv tests/run_cats_r4_a3_compute_cluster_stress_iverilog.ps1
git diff --cached --check
git commit -m "test(a3): close reset abort and backpressure gates"
```

## Task 8: Close Full-workload Protocol Counters and Numeric Evidence

**Files:**
- Create: `tb/tb_cats_r4_a3_qk_protocol_model.sv`
- Create: `tb/tb_cats_r4_a3_full_protocol.sv`
- Create: `tests/run_cats_r4_a3_full_protocol_iverilog.ps1`
- Create: `tests/check_cats_r4_a3_readiness.py`
- Create: `tests/test_check_cats_r4_a3_readiness.py`
- Verify: B full numeric model/tests accepted in Task 1.

**Interfaces:**
- Consumes: production A3 wrapper, test-only QK/B2/B3 models, C weight model, stored full numeric reports.
- Produces: 4096-row protocol counts and machine-readable evidence classification.

- [ ] **Step 1: Write the test-only QK protocol model**

Define a module named `cats_r4_qk_32lane_engine` with the exact production engine port list, compiled instead of the production engine only by this runner. For each accepted start, emit one zero-valued score vector for each active context `0..start_row_count-1`, with:

```systemverilog
score_row = start_row_window*16 + start_row_offset + emit_context;
score_context_tag = emit_context[3:0];
score_lane_valid[lane] = start_key_block*32 + lane <= score_row;
score_fp32 = '0;
```

After all active score vectors handshake, emit one matching done token. Implement every engine counter using the same handshake definitions as the real engine; do not label its results as arithmetic evidence.

- [ ] **Step 2: Write the full protocol TB**

Drive all `32 heads × 8 row windows`, both numeric modes in separate runs, randomized Q-slab/C/output/error ready signals, and test-only all-zero scores/all-one V data. Check exact aggregate targets:

```systemverilog
if (rows_transferred != 64'd4096 ||
    scores_transferred != 64'd264192 ||
    b2_exp_commit != 64'd264192 ||
    b2_weight_writes != 64'd524288 ||
    b3_pv_commit != 64'd33816576 ||
    b3_context_words != 64'd524288 ||
    final_release_count != 64'd4096 ||
    q_slab_jobs_accepted != 64'd256 ||
    engine_jobs_started != 64'd6144)
    $fatal(1, "A3 full protocol aggregate mismatch");
```

Require all normal protocol/numeric/owner/release/memory/context-slot errors to equal zero.

- [ ] **Step 3: Run and observe failure before runner/model completion**

Run:

```powershell
& tests\run_cats_r4_a3_full_protocol_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 0 -Seed 3019898881
```

Expected: compile or aggregate failure until the test model and top counter exports are complete.

- [ ] **Step 4: Finish the runner with explicit evidence labels**

The runner source list must compile the production A3 wrapper, actual Q-slab client/A2/score memory/error join/B4 wrapper, test-only QK/B2/B3 protocol models, and B4 C weight model. It must print exactly:

```text
PASS A3 FULL PROTOCOL MODEL rows=4096 causal_scores=264192 weight_writes=524288 qk_macs=33816576 pv_macs=33816576 context_words=524288 releases=4096
EVIDENCE_LEVEL=PROTOCOL_MODEL_NOT_REAL_IP
```

- [ ] **Step 5: Run both full protocol modes**

Run:

```powershell
& tests\run_cats_r4_a3_full_protocol_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 0 -Seed 3019898881
& tests\run_cats_r4_a3_full_protocol_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 1 -Seed 3019898881
```

Expected: both exact PASS markers and evidence labels.

- [ ] **Step 6: Run the stored full numerical gates with the correct Python**

Run:

```powershell
$a3Python = 'C:\Users\liuhe\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $a3Python tests\test_cats_r4_b2_accuracy_fixed_model.py
& $a3Python tests\check_cats_r4_lead_release.py
& tests\run_cats_r4_b2_accuracy_v3_stored_full_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_b3_pv_full_workload_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
```

Expected: Accuracy fixed-model tests PASS, archived full/stress hashes PASS, stored-full `combined_failures=0`, and B3 full counters `4096/264192/33816576/524288/4096` close with zero normal errors.

- [ ] **Step 7: Add a readiness evidence checker**

`tests/check_cats_r4_a3_readiness.py` must parse a JSON manifest and reject evidence-level substitution. Its core checks are:

```python
EXPECTED = {
    "rows": 4096,
    "causal_scores": 264192,
    "weight_writes": 524288,
    "qk_macs": 33816576,
    "pv_macs": 33816576,
    "context_words": 524288,
    "final_releases": 4096,
    "q_slabs": 256,
    "engine_jobs": 6144,
}

assert evidence["full_protocol"]["level"] == "protocol_model"
assert evidence["real_ip_xsim"]["level"] == "representative_real_ip"
assert evidence["numeric"]["combined_failures"] == 0
assert evidence["ooc"]["clock_period_ns"] == 6.666
assert evidence["ooc"]["wns_ns"] >= 0.0
for name, value in EXPECTED.items():
    assert evidence["full_protocol"]["counters"][name] == value
```

Create `tests/test_check_cats_r4_a3_readiness.py` with three fixtures: one valid evidence dictionary, one dictionary that places `protocol_model` in `real_ip_xsim.level`, and one with `ooc.wns_ns=-0.001`. Assert that only the valid dictionary passes validation. Run:

```powershell
& 'C:\Users\liuhe\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' tests\test_check_cats_r4_a3_readiness.py
```

Expected: three tests PASS.

- [ ] **Step 8: Commit**

Run:

```powershell
git add tb/tb_cats_r4_a3_qk_protocol_model.sv tb/tb_cats_r4_a3_full_protocol.sv tests/run_cats_r4_a3_full_protocol_iverilog.ps1 tests/check_cats_r4_a3_readiness.py tests/test_check_cats_r4_a3_readiness.py
git diff --cached --check
git commit -m "test(a3): close full protocol and numeric counters"
```

## Task 9: Run Representative Real-IP XSim and 150 MHz OOC

**Files:**
- Create: `tests/run_cats_r4_a3_realip_vivado.ps1`
- Create: `scripts/cats_r4_a3_compute_cluster_ooc.tcl`
- Modify: `tb/tb_cats_r4_a3_compute_cluster.sv`
- Generate outside Git: XSim/OOC logs, DCPs, timing, utilization, route, DRC, methodology and power reports.

**Interfaces:**
- Consumes: complete production A3 RTL and generated Floating Point IP.
- Produces: representative actual-IP XSim and routed A3 OOC evidence at 6.666 ns.

- [ ] **Step 1: Add a real-IP XSim matrix to the TB**

Parameterize the directed TB with `MODE`, `ROWS`, `SEED`, `INJECT_RESET`, and `INJECT_ABORT`. The runner must execute both modes, at least six rows so every slot is reused, four seeds, one reset case and one abort/error case. Require `REAL_IP=1` in the PASS marker.

- [ ] **Step 2: Run XSim before adding the runner and observe failure**

Run:

```powershell
& tests\run_cats_r4_a3_realip_vivado.ps1 `
  -VivadoRoot 'C:\Software\AMD\vivado25.2\2025.2\Vivado' -SkipOoc
```

Expected: command or source-list failure because the A3 real-IP runner is not complete.

- [ ] **Step 3: Implement the isolated Vivado runner**

Follow the proven B4 runner pattern: mirror sources to an ASCII-only temporary root, generate or reuse `floating_point_0/1/2`, compile the real QK/B2/B3/A3 RTL, run the matrix, count PASS markers, reject `Fatal:`/`FATAL:`, and copy final evidence to a caller-provided fresh output root. The runner must never modify the user's Vivado manifest permanently and must restore it in `finally`.

- [ ] **Step 4: Implement A3 OOC Tcl**

The Tcl flow must set:

```tcl
read_xdc $a3_xdc
set_property top cats_r4_a3_compute_cluster [current_fileset]
synth_design -mode out_of_context -flatten_hierarchy none \
    -top cats_r4_a3_compute_cluster -part xczu15eg-ffvb1156-2-i
opt_design
place_design
phys_opt_design
route_design
report_utilization -hierarchical -file $a3_utilization
report_timing_summary -delay_type max -max_paths 20 \
    -report_unconstrained -file $a3_timing
report_timing -delay_type max -max_paths 20 -file $a3_critical_paths
report_route_status -file $a3_route_status
report_drc -file $a3_drc
report_methodology -file $a3_methodology
report_power -file $a3_power
```

Create the 6.666 ns core clock, time all internal clock-to-clock paths, and explicitly document any OOC-only false paths on package-less contract I/O. Reject no-timing-path, negative WNS, incomplete route, DRC errors, or unconstrained internal endpoints.

- [ ] **Step 5: Run representative real-IP XSim**

Run:

```powershell
$a3XsimRoot = Join-Path ([IO.Path]::GetTempPath()) ('a3_xsim_' + [guid]::NewGuid().ToString('N'))
& tests\run_cats_r4_a3_realip_vivado.ps1 `
  -VivadoRoot 'C:\Software\AMD\vivado25.2\2025.2\Vivado' `
  -OutputRoot $a3XsimRoot -SkipOoc
```

Expected: every mode/seed/reset/abort configuration completes with `EVIDENCE_LEVEL=REPRESENTATIVE_REAL_IP_XSIM`, no runtime fatal, and no claim of full 4096-row real-IP execution.

- [ ] **Step 6: Run the complete A3 OOC implementation**

Run:

```powershell
$a3OocRoot = Join-Path ([IO.Path]::GetTempPath()) ('a3_ooc_' + [guid]::NewGuid().ToString('N'))
& tests\run_cats_r4_a3_realip_vivado.ps1 `
  -VivadoRoot 'C:\Software\AMD\vivado25.2\2025.2\Vivado' `
  -OutputRoot $a3OocRoot -SkipXsim -ClockPeriodNs 6.666
```

Expected: routed `WNS>=0`, `TNS=0`, no failing endpoints, complete route, no DRC errors, and reports for LUT/FF/BRAM/DSP/URAM, critical paths, methodology and vectorless estimated power.

- [ ] **Step 7: Run affected vendor regressions**

Run:

```powershell
& tests\run_cats_r4_qk_a2_row_pipeline_xsim.ps1 -VivadoRoot 'C:\Software\AMD\vivado25.2\2025.2\Vivado'
$a3B4Root = Join-Path ([IO.Path]::GetTempPath()) ('b4_ooc_recheck_' + [guid]::NewGuid().ToString('N'))
& tests\run_cats_r4_b4_realip_vivado.ps1 -VivadoRoot 'C:\Software\AMD\vivado25.2\2025.2\Vivado' -OutputRoot $a3B4Root -SkipXsim -ClockPeriodNs 6.666
```

Expected: A2 XSim PASS and B4 routed OOC PASS remain unchanged.

- [ ] **Step 8: Commit reproducible scripts and TB changes**

Run:

```powershell
git add tests/run_cats_r4_a3_realip_vivado.ps1 scripts/cats_r4_a3_compute_cluster_ooc.tcl tb/tb_cats_r4_a3_compute_cluster.sv
git diff --cached --check
git commit -m "test(a3): add real-IP XSim and OOC gates"
```

## Task 10: Produce Telemetry, Ablation Record, Delivery, and Final Review

**Files:**
- Create: `python/cats_r4_a3_ablation_gate.py`
- Create: `tests/test_cats_r4_a3_ablation_gate.py`
- Create: `reports/cats_r4_a3_evidence.json`
- Create: `docs/CATS_R4_A3_ROW_ONLINE_ABLATION_2026-09-13.md`
- Create: `docs/CATS_R4_A3_COMPUTE_CLUSTER_DELIVERY_2026-09-13.md`

**Interfaces:**
- Consumes: full protocol counters, numerical reports, real-IP XSim logs, OOC reports, A3 telemetry, and an independently generated same-boundary online candidate if available.
- Produces: machine-checkable A3 evidence, an honest row/online comparison status, and the final A3 handoff SHA.

- [ ] **Step 1: Write failing ablation-gate unit tests**

Define candidate metadata fields `input_sha256`, `numeric_mode`, `qk_lanes`, `pv_lanes`, `clock_mhz`, `timing_start`, `timing_end`, `cycles`, `resources`, and `stalls`. Unit tests must prove that mismatched input hash, mode, lanes, clock, or timing boundary returns `comparable=false`; matching metadata returns cycle/resource/stall deltas.

- [ ] **Step 2: Run the tests and observe missing-module failure**

Run:

```powershell
& 'C:\Users\liuhe\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' tests\test_cats_r4_a3_ablation_gate.py
```

Expected: import failure for `cats_r4_a3_ablation_gate`.

- [ ] **Step 3: Implement strict comparability**

Use this core logic:

```python
MATCH_FIELDS = (
    "input_sha256",
    "numeric_mode",
    "qk_lanes",
    "pv_lanes",
    "clock_mhz",
    "timing_start",
    "timing_end",
)

def compare(row: dict, online: dict) -> dict:
    mismatches = {
        name: {"row": row[name], "online": online[name]}
        for name in MATCH_FIELDS
        if row[name] != online[name]
    }
    if mismatches:
        return {"comparable": False, "mismatches": mismatches}
    return {
        "comparable": True,
        "cycle_delta": row["cycles"] - online["cycles"],
        "cycle_ratio": row["cycles"] / online["cycles"],
        "resource_delta": {
            name: row["resources"][name] - online["resources"][name]
            for name in ("lut", "ff", "bram", "dsp", "uram")
        },
        "stall_delta": {
            name: row["stalls"].get(name, 0) - online["stalls"].get(name, 0)
            for name in sorted(set(row["stalls"]) | set(online["stalls"]))
        },
    }
```

- [ ] **Step 4: Generate the A3 evidence manifest**

Populate `reports/cats_r4_a3_evidence.json` with exact Git SHA, tag identities, tool versions, command lines, input/report hashes, full protocol counters, `combined_failures`, real-IP matrix, OOC WNS/TNS/PPA and telemetry. Label evidence exactly as `protocol_model`, `stored_full_numeric`, `representative_real_ip`, or `routed_ooc`.

- [ ] **Step 5: Generate the row/online comparison record**

Run the gate only with a same-input/mode/32-lane/150-MHz/same-boundary online manifest. If no such manifest exists, write `comparable=false` and list the missing or mismatched fields; do not use v3.1.4's 4-lane/board timing as the online baseline. This does not block A3 compute-unit/OOC READY, but it blocks row-vs-online and system performance claims.

- [ ] **Step 6: Run the machine-readable readiness gate**

Run:

```powershell
& 'C:\Users\liuhe\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' `
  tests\check_cats_r4_a3_readiness.py reports\cats_r4_a3_evidence.json
```

Expected: PASS only when all exact counters close, `combined_failures=0`, evidence classes are distinct, and OOC `WNS>=0`.

- [ ] **Step 7: Run the complete final regression matrix**

Run:

```powershell
& tests\run_cats_r4_qk_32lane_engine_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_qk_q_slab_client_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_qk_a2_row_pipeline_xsim.ps1 -VivadoRoot 'C:\Software\AMD\vivado25.2\2025.2\Vivado'
& tests\run_cats_r4_a3_row_frontend_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_a3_error_join_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog'
& tests\run_cats_r4_a3_compute_cluster_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 0
& tests\run_cats_r4_a3_compute_cluster_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 1
foreach ($a3Mode in 0,1) {
  foreach ($a3Seed in 7,19,73,101) {
    & tests\run_cats_r4_a3_compute_cluster_stress_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode $a3Mode -Seed $a3Seed
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }
}
& tests\run_cats_r4_a3_full_protocol_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 0 -Seed 3019898881
& tests\run_cats_r4_a3_full_protocol_iverilog.ps1 -IcarusRoot 'C:\Software\iverilog' -Mode 1 -Seed 3019898881
& tests\run_cats_r4_c_unit_checks.ps1 -IcarusRoot 'C:\Software\iverilog'
git diff --check
```

Expected: all commands exit zero, all normal errors are zero, negative errors match their expected increments, and `git diff --check` is clean. Run the Task 9 real-IP and OOC commands again if any RTL source changed after their last evidence run.

- [ ] **Step 8: Write the delivery record**

`docs/CATS_R4_A3_COMPUTE_CLUSTER_DELIVERY_2026-09-13.md` must state:

```text
stage/status
base and complete head SHA
accepted B source SHAs
interface tag object and tagged commit
changed files and owner boundaries
all commands with PASS/FAIL/NOT RUN
full expected/actual counters
numeric modes and combined_failures
real-IP XSim scope
OOC device/clock/WNS/TNS/PPA/critical path
telemetry and row/online comparability
failed seeds retained
known limitations
C2, D review, board and system work still open
```

Do not write `READY` if the machine-readable gate, real-IP representative matrix, or routed OOC timing gate is absent or failing.

- [ ] **Step 9: Request code review before final commit**

Use `superpowers:requesting-code-review`. Review the diff from the first post-B baseline commit through HEAD for spec compliance, owner-boundary violations, protocol stability, counter inflation, evidence substitution and generated files. Resolve only A-owned findings; route B/C findings to their owners.

- [ ] **Step 10: Commit the evidence and delivery record**

Run:

```powershell
git add python/cats_r4_a3_ablation_gate.py tests/test_cats_r4_a3_ablation_gate.py tests/check_cats_r4_a3_readiness.py reports/cats_r4_a3_evidence.json docs/CATS_R4_A3_ROW_ONLINE_ABLATION_2026-09-13.md docs/CATS_R4_A3_COMPUTE_CLUSTER_DELIVERY_2026-09-13.md
git diff --cached --check
git commit -m "docs(a3): deliver compute-cluster readiness"
git status --short --branch
git rev-parse HEAD
```

Expected: clean worktree and a complete A3 delivery SHA. Push `codex/a-cats-r4-a3-compute-cluster`; open a review toward `codex/cats-r4-local-integration`, never directly toward `main`.
