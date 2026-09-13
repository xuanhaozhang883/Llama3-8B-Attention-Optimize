`timescale 1ns/1ps

// CATS-R4 A-owned compute boundary.
//
// This wrapper is deliberately limited to the compute side of the frozen
// IF_V3 contract.  It instantiates one QK scheduler/FP32 service and one
// score/max/slot pipeline per compute cluster.  Q/K memory, score storage,
// B4, CDC and DDR remain external services.  The wrapper is therefore useful
// in an A-side testbench without accidentally creating a second production
// cluster shell.
//
// KV groups are assigned statically by group % CLUSTERS.  For the supported
// configurations this gives:
//   1 cluster: {0..7}; 2 clusters: even/odd groups; 4 clusters: two groups
//   per cluster ({c,c+4}), i.e. two balanced waves for the eight groups.
//
// The file is intentionally absent from scripts/source_manifest.tcl until C
// accepts the A handoff and performs system-level integration.
module cats_r4_compute_frontend #(
    parameter int CLUSTERS = 1,
    parameter int SEQ_LEN  = 128,
    parameter int HEAD_DIM = 128,
    parameter int CONTEXTS = 16,
    parameter int LANES    = 32,
    parameter int SLOTS    = 3,
    parameter logic [31:0] SCALE_FP32 = 32'h3db5_04f3
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,
    input  logic counter_clear,

    // One mode/epoch latch is broadcast to all cluster row pipelines.
    input  logic txn_start_valid,
    output logic txn_start_ready,
    input  logic [15:0] txn_epoch,
    input  logic [1:0]  txn_numeric_mode,

    // A group job is routed to exactly one cluster.  A job is a 16-row Q
    // window; q_slab_client expands it into the four key blocks and six
    // row sub-batches required by the R=16 scheduler.
    input  logic        job_valid,
    output logic        job_ready,
    input  logic [15:0] job_epoch,
    input  logic [2:0]  job_group,
    input  logic [4:0]  job_global_q_head,
    input  logic [2:0]  job_row_window,

    // Per-cluster Q-slab service.
    output logic [CLUSTERS-1:0]       q_slab_need_valid,
    input  logic  [CLUSTERS-1:0]      q_slab_need_ready,
    output logic [CLUSTERS*16-1:0]    q_slab_need_epoch,
    output logic [CLUSTERS*3-1:0]     q_slab_need_group,
    output logic [CLUSTERS*5-1:0]     q_slab_need_global_q_head,
    output logic [CLUSTERS*3-1:0]     q_slab_need_row_window,
    input  logic  [CLUSTERS-1:0]      q_slab_ready_valid,
    output logic [CLUSTERS-1:0]       q_slab_ready_ready,
    input  logic  [CLUSTERS*16-1:0]   q_slab_ready_epoch,
    input  logic  [CLUSTERS*3-1:0]    q_slab_ready_group,
    input  logic  [CLUSTERS*5-1:0]    q_slab_ready_global_q_head,
    input  logic  [CLUSTERS*3-1:0]    q_slab_ready_row_window,
    input  logic  [CLUSTERS-1:0]      q_slab_ready_buffer,
    output logic [CLUSTERS-1:0]       q_slab_retire_valid,
    input  logic  [CLUSTERS-1:0]      q_slab_retire_ready,
    output logic [CLUSTERS*16-1:0]    q_slab_retire_epoch,
    output logic [CLUSTERS*3-1:0]     q_slab_retire_group,
    output logic [CLUSTERS*5-1:0]     q_slab_retire_global_q_head,
    output logic [CLUSTERS*3-1:0]     q_slab_retire_row_window,
    output logic [CLUSTERS-1:0]       q_slab_retire_buffer,

    // Per-cluster Q and K memory request/response services.
    output logic [CLUSTERS-1:0]       q_req_valid,
    input  logic [CLUSTERS-1:0]       q_req_ready,
    output logic [CLUSTERS*4-1:0]     q_req_context_tag,
    output logic [CLUSTERS*7-1:0]     q_req_d,
    input  logic [CLUSTERS-1:0]       q_rsp_valid,
    input  logic [CLUSTERS*4-1:0]     q_rsp_context_tag,
    input  logic [CLUSTERS*16-1:0]    q_rsp_bf16,
    output logic [CLUSTERS-1:0]       k_req_valid,
    input  logic [CLUSTERS-1:0]       k_req_ready,
    output logic [CLUSTERS*4-1:0]     k_req_context_tag,
    output logic [CLUSTERS*2-1:0]     k_req_key_block,
    output logic [CLUSTERS*7-1:0]     k_req_d,
    input  logic [CLUSTERS-1:0]       k_rsp_valid,
    input  logic [CLUSTERS*4-1:0]     k_rsp_context_tag,
    input  logic [CLUSTERS*512-1:0]   k_rsp_vec,

    // Score-store write/read service owned by C.  The score stream and row
    // header below are the only normal A-to-C data outputs.
    output logic [CLUSTERS-1:0]       store_wr_valid,
    input  logic [CLUSTERS-1:0]       store_wr_ready,
    output logic [CLUSTERS*2-1:0]     store_wr_slot_id,
    output logic [CLUSTERS*7-1:0]     store_wr_key_base,
    output logic [CLUSTERS*LANES-1:0] store_wr_lane_valid,
    output logic [CLUSTERS*LANES*16-1:0] store_wr_score_bf16,
    output logic [CLUSTERS-1:0]       score_rd_req_valid,
    input  logic [CLUSTERS-1:0]       score_rd_req_ready,
    output logic [CLUSTERS*16-1:0]    score_rd_req_epoch,
    output logic [CLUSTERS*3-1:0]     score_rd_req_group,
    output logic [CLUSTERS*5-1:0]     score_rd_req_global_q_head,
    output logic [CLUSTERS*7-1:0]     score_rd_req_row,
    output logic [CLUSTERS*7-1:0]     score_rd_req_key,
    output logic [CLUSTERS*2-1:0]     score_rd_req_slot_id,
    output logic [CLUSTERS*2-1:0]     score_rd_req_numeric_mode,
    input  logic [CLUSTERS-1:0]       score_rd_rsp_valid,
    output logic [CLUSTERS-1:0]       score_rd_rsp_ready,
    input  logic [CLUSTERS*16-1:0]    score_rd_rsp_epoch,
    input  logic [CLUSTERS*3-1:0]     score_rd_rsp_group,
    input  logic [CLUSTERS*5-1:0]     score_rd_rsp_global_q_head,
    input  logic [CLUSTERS*7-1:0]     score_rd_rsp_row,
    input  logic [CLUSTERS*7-1:0]     score_rd_rsp_key,
    input  logic [CLUSTERS*2-1:0]     score_rd_rsp_slot_id,
    input  logic [CLUSTERS*2-1:0]     score_rd_rsp_numeric_mode,
    input  logic [CLUSTERS*16-1:0]    score_rd_rsp_bf16,

    // B4 row/score handoff and final-release return, all per cluster.
    output logic [CLUSTERS-1:0]       b_row_valid,
    input  logic [CLUSTERS-1:0]       b_row_ready,
    output logic [CLUSTERS*16-1:0]    b_row_epoch,
    output logic [CLUSTERS*3-1:0]     b_row_group,
    output logic [CLUSTERS*5-1:0]     b_row_global_q_head,
    output logic [CLUSTERS*7-1:0]     b_row_index,
    output logic [CLUSTERS*2-1:0]     b_row_slot_id,
    output logic [CLUSTERS*2-1:0]     b_row_numeric_mode,
    output logic [CLUSTERS*16-1:0]    b_row_max_bf16,
    output logic [CLUSTERS-1:0]       b_score_valid,
    input  logic [CLUSTERS-1:0]       b_score_ready,
    output logic [CLUSTERS*16-1:0]    b_score_epoch,
    output logic [CLUSTERS*3-1:0]     b_score_group,
    output logic [CLUSTERS*5-1:0]     b_score_global_q_head,
    output logic [CLUSTERS*7-1:0]     b_score_row,
    output logic [CLUSTERS*7-1:0]     b_score_key,
    output logic [CLUSTERS*2-1:0]     b_score_slot_id,
    output logic [CLUSTERS*2-1:0]     b_score_numeric_mode,
    output logic [CLUSTERS*16-1:0]    b_score_bf16,
    output logic [CLUSTERS-1:0]       b_score_last,
    input  logic [CLUSTERS-1:0]       final_release_valid,
    output logic [CLUSTERS-1:0]       final_release_ready,
    input  logic [CLUSTERS*16-1:0]    final_release_epoch,
    input  logic [CLUSTERS*3-1:0]     final_release_group,
    input  logic [CLUSTERS*5-1:0]     final_release_global_q_head,
    input  logic [CLUSTERS*7-1:0]     final_release_row,
    input  logic [CLUSTERS*2-1:0]     final_release_slot_id,
    input  logic [CLUSTERS*2-1:0]     final_release_numeric_mode,

    output logic [CLUSTERS-1:0]       row_abort_valid,
    input  logic [CLUSTERS-1:0]       row_abort_ready,
    output logic [CLUSTERS*16-1:0]    row_abort_epoch,
    output logic [CLUSTERS*3-1:0]     row_abort_group,
    output logic [CLUSTERS*5-1:0]     row_abort_global_q_head,
    output logic [CLUSTERS*7-1:0]     row_abort_row,
    output logic [CLUSTERS*7-1:0]     row_abort_error_key,
    output logic [CLUSTERS*2-1:0]     row_abort_slot_id,
    output logic [CLUSTERS*2-1:0]     row_abort_numeric_mode,
    output logic [CLUSTERS*3-1:0]     row_abort_error_code,

    // Per-cluster evidence.  Keeping the counters separate makes overlap,
    // ownership and static group balance auditable without relying on a
    // single aggregate counter.
    output logic [CLUSTERS*6-1:0]     slot_owner,
    output logic [CLUSTERS*64-1:0]    cluster_jobs_accepted,
    output logic [CLUSTERS*64-1:0]    cluster_engine_jobs_started,
    output logic [CLUSTERS*64-1:0]    cluster_engine_jobs_completed,
    output logic [CLUSTERS*64-1:0]    cluster_rows_completed,
    output logic [CLUSTERS*64-1:0]    cluster_scores_transferred,
    output logic [CLUSTERS*64-1:0]    cluster_rows_transferred,
    output logic [CLUSTERS*64-1:0]    cluster_valid_macs,
    output logic [CLUSTERS*64-1:0]    cluster_mac_steps_issued,
    output logic [CLUSTERS*64-1:0]    cluster_mac_steps_completed,
    output logic [CLUSTERS*64-1:0]    cluster_assignment_errors,
    output logic [CLUSTERS-1:0]       protocol_error_sticky
);
    localparam int CLUSTER_ID_W = (CLUSTERS <= 1) ? 1 : $clog2(CLUSTERS);

    logic [CLUSTERS-1:0] txn_start_ready_c;
    logic [CLUSTERS-1:0] job_valid_c, job_ready_c;
    logic [CLUSTERS-1:0] job_accept_c;
    logic [CLUSTERS-1:0] assignment_error_seen;
    logic job_fields_valid;
    logic [CLUSTER_ID_W-1:0] target_cluster;

    // q_slab_client <-> QK engine control.
    logic [CLUSTERS-1:0] engine_start_valid, engine_start_ready;
    logic [CLUSTERS*16-1:0] engine_start_epoch;
    logic [CLUSTERS*3-1:0] engine_start_group;
    logic [CLUSTERS*5-1:0] engine_start_head;
    logic [CLUSTERS*3-1:0] engine_start_window;
    logic [CLUSTERS*4-1:0] engine_start_offset;
    logic [CLUSTERS*5-1:0] engine_start_count;
    logic [CLUSTERS*2-1:0] engine_start_key_block;
    logic [CLUSTERS-1:0] engine_start_q_buffer;
    logic [CLUSTERS-1:0] engine_done_valid, engine_done_ready;
    logic [CLUSTERS*16-1:0] engine_done_epoch;
    logic [CLUSTERS*3-1:0] engine_done_group;
    logic [CLUSTERS*5-1:0] engine_done_head;
    logic [CLUSTERS*3-1:0] engine_done_window;
    logic [CLUSTERS*2-1:0] engine_done_key_block;
    logic [CLUSTERS-1:0] engine_done_error;

    // QK engine score blocks feed the row/max/slot pipeline directly.
    logic [CLUSTERS-1:0] engine_score_valid, engine_score_ready;
    logic [CLUSTERS*16-1:0] engine_score_epoch;
    logic [CLUSTERS*3-1:0] engine_score_group;
    logic [CLUSTERS*5-1:0] engine_score_head;
    logic [CLUSTERS*7-1:0] engine_score_row;
    logic [CLUSTERS*2-1:0] engine_score_key_block;
    logic [CLUSTERS*4-1:0] engine_score_context;
    logic [CLUSTERS*LANES-1:0] engine_score_lane_valid;
    logic [CLUSTERS*LANES*32-1:0] engine_score_fp32;

    logic [CLUSTERS-1:0] row_txn_start_ready;
    logic [CLUSTERS*64-1:0] qslab_protocol_errors;
    logic [CLUSTERS*64-1:0] qslab_epoch_drops;
    logic [CLUSTERS-1:0] qslab_sticky;
    logic [CLUSTERS-1:0] engine_sticky;
    logic [CLUSTERS-1:0] row_sticky;
    logic [CLUSTERS*64-1:0] qslab_needs_count;
    logic [CLUSTERS*64-1:0] qslab_readies_count;
    logic [CLUSTERS*64-1:0] qslab_retires_count;

    // A job is legal only when the group is in the eight-group domain and
    // the IF_V3 group/head bijection holds.  The modulo route is constant for
    // a given group and never changes while a job is in flight.
    always_comb begin
        job_fields_valid = (job_group < 8) &&
                           (job_global_q_head[4:2] == job_group) &&
                           // Jobs from a stale epoch must be rejected at the
                           // routing boundary; otherwise a row pipeline that
                           // has latched a newer transaction would stall
                           // forever waiting for an old token to match.
                           (job_epoch == txn_epoch);
        target_cluster = '0;
        if (job_group < 8)
            target_cluster = job_group % CLUSTERS;
        job_ready = 1'b0;
        if (job_fields_valid)
            job_ready = job_ready_c[target_cluster];
    end

    assign txn_start_ready = &row_txn_start_ready;

    always_ff @(posedge clk) begin
        integer ec;
        if (!rst_n || clear) begin
            assignment_error_seen <= '0;
        end else begin
            // Count one malformed job assertion, not every cycle of a held
            // invalid valid signal.  A new assertion is recognized after the
            // producer withdraws valid.
            if (!job_valid)
                assignment_error_seen <= '0;
            else if (!job_fields_valid && !assignment_error_seen[0])
                assignment_error_seen <= '1;
        end
    end

    genvar c;
    generate
        for (c = 0; c < CLUSTERS; c = c + 1) begin : GEN_CLUSTER
            assign job_valid_c[c] = job_valid && job_fields_valid &&
                                     (target_cluster == c);
            assign job_accept_c[c] = job_valid_c[c] && job_ready_c[c];

            cats_r4_qk_q_slab_client u_q_slab (
                .clk, .rst_n, .clear, .counter_clear,
                .job_valid(job_valid_c[c]), .job_ready(job_ready_c[c]),
                .job_epoch, .job_group, .job_global_q_head, .job_row_window,
                .q_slab_need_valid(q_slab_need_valid[c]),
                .q_slab_need_ready(q_slab_need_ready[c]),
                .q_slab_need_epoch(q_slab_need_epoch[c*16 +: 16]),
                .q_slab_need_group(q_slab_need_group[c*3 +: 3]),
                .q_slab_need_global_q_head(q_slab_need_global_q_head[c*5 +: 5]),
                .q_slab_need_row_window(q_slab_need_row_window[c*3 +: 3]),
                .q_slab_ready_valid(q_slab_ready_valid[c]),
                .q_slab_ready_ready(q_slab_ready_ready[c]),
                .q_slab_ready_epoch(q_slab_ready_epoch[c*16 +: 16]),
                .q_slab_ready_group(q_slab_ready_group[c*3 +: 3]),
                .q_slab_ready_global_q_head(q_slab_ready_global_q_head[c*5 +: 5]),
                .q_slab_ready_row_window(q_slab_ready_row_window[c*3 +: 3]),
                .q_slab_ready_buffer(q_slab_ready_buffer[c]),
                .engine_start_valid(engine_start_valid[c]),
                .engine_start_ready(engine_start_ready[c]),
                .engine_start_epoch(engine_start_epoch[c*16 +: 16]),
                .engine_start_group(engine_start_group[c*3 +: 3]),
                .engine_start_global_q_head(engine_start_head[c*5 +: 5]),
                .engine_start_row_window(engine_start_window[c*3 +: 3]),
                .engine_start_row_offset(engine_start_offset[c*4 +: 4]),
                .engine_start_row_count(engine_start_count[c*5 +: 5]),
                .engine_start_key_block(engine_start_key_block[c*2 +: 2]),
                .engine_start_q_buffer(engine_start_q_buffer[c]),
                .engine_done_valid(engine_done_valid[c]),
                .engine_done_ready(engine_done_ready[c]),
                .engine_done_epoch(engine_done_epoch[c*16 +: 16]),
                .engine_done_group(engine_done_group[c*3 +: 3]),
                .engine_done_global_q_head(engine_done_head[c*5 +: 5]),
                .engine_done_row_window(engine_done_window[c*3 +: 3]),
                // The engine keeps exactly one start token in flight, so the
                // q_slab metadata remains stable while its done is pending.
                .engine_done_row_offset(engine_start_offset[c*4 +: 4]),
                .engine_done_row_count(engine_start_count[c*5 +: 5]),
                .engine_done_key_block(engine_done_key_block[c*2 +: 2]),
                .engine_done_error(engine_done_error[c]),
                .q_slab_retire_valid(q_slab_retire_valid[c]),
                .q_slab_retire_ready(q_slab_retire_ready[c]),
                .q_slab_retire_epoch(q_slab_retire_epoch[c*16 +: 16]),
                .q_slab_retire_group(q_slab_retire_group[c*3 +: 3]),
                .q_slab_retire_global_q_head(q_slab_retire_global_q_head[c*5 +: 5]),
                .q_slab_retire_row_window(q_slab_retire_row_window[c*3 +: 3]),
                .q_slab_retire_buffer(q_slab_retire_buffer[c]),
                .jobs_accepted(cluster_jobs_accepted[c*64 +: 64]),
                .q_slab_needs_transferred(qslab_needs_count[c*64 +: 64]),
                .q_slab_ready_transferred(qslab_readies_count[c*64 +: 64]),
                .engine_jobs_started(cluster_engine_jobs_started[c*64 +: 64]),
                .engine_jobs_completed(cluster_engine_jobs_completed[c*64 +: 64]),
                .q_slab_retires_transferred(qslab_retires_count[c*64 +: 64]),
                .protocol_errors(qslab_protocol_errors[c*64 +: 64]),
                .epoch_drops(qslab_epoch_drops[c*64 +: 64]),
                .protocol_error_sticky(qslab_sticky[c])
            );

            cats_r4_qk_32lane_engine #(
                .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
                .CONTEXTS(CONTEXTS), .LANES(LANES)
            ) u_engine (
                .clk, .rst_n, .clear, .counter_clear,
                .start_valid(engine_start_valid[c]),
                .start_ready(engine_start_ready[c]),
                .start_epoch(engine_start_epoch[c*16 +: 16]),
                .start_group(engine_start_group[c*3 +: 3]),
                .start_global_q_head(engine_start_head[c*5 +: 5]),
                .start_row_window(engine_start_window[c*3 +: 3]),
                .start_row_offset(engine_start_offset[c*4 +: 4]),
                .start_row_count(engine_start_count[c*5 +: 5]),
                .start_key_block(engine_start_key_block[c*2 +: 2]),
                .done_valid(engine_done_valid[c]),
                .done_ready(engine_done_ready[c]),
                .done_epoch(engine_done_epoch[c*16 +: 16]),
                .done_group(engine_done_group[c*3 +: 3]),
                .done_global_q_head(engine_done_head[c*5 +: 5]),
                .done_row_window(engine_done_window[c*3 +: 3]),
                .done_key_block(engine_done_key_block[c*2 +: 2]),
                .done_error(engine_done_error[c]),
                .q_req_valid(q_req_valid[c]), .q_req_ready(q_req_ready[c]),
                .q_req_context_tag(q_req_context_tag[c*4 +: 4]),
                .q_req_d(q_req_d[c*7 +: 7]),
                .q_rsp_valid(q_rsp_valid[c]),
                .q_rsp_context_tag(q_rsp_context_tag[c*4 +: 4]),
                .q_rsp_bf16(q_rsp_bf16[c*16 +: 16]),
                .k_req_valid(k_req_valid[c]), .k_req_ready(k_req_ready[c]),
                .k_req_context_tag(k_req_context_tag[c*4 +: 4]),
                .k_req_key_block(k_req_key_block[c*2 +: 2]),
                .k_req_d(k_req_d[c*7 +: 7]),
                .k_rsp_valid(k_rsp_valid[c]),
                .k_rsp_context_tag(k_rsp_context_tag[c*4 +: 4]),
                .k_rsp_vec(k_rsp_vec[c*512 +: 512]),
                .score_valid(engine_score_valid[c]),
                .score_ready(engine_score_ready[c]),
                .score_epoch(engine_score_epoch[c*16 +: 16]),
                .score_group(engine_score_group[c*3 +: 3]),
                .score_global_q_head(engine_score_head[c*5 +: 5]),
                .score_row(engine_score_row[c*7 +: 7]),
                .score_key_block(engine_score_key_block[c*2 +: 2]),
                .score_context_tag(engine_score_context[c*4 +: 4]),
                .score_lane_valid(engine_score_lane_valid[c*LANES +: LANES]),
                .score_fp32(engine_score_fp32[c*LANES*32 +: LANES*32]),
                .q_requests_accepted(), .k_requests_accepted(),
                .mac_steps_issued(cluster_mac_steps_issued[c*64 +: 64]),
                .mac_steps_completed(cluster_mac_steps_completed[c*64 +: 64]),
                .valid_macs(cluster_valid_macs[c*64 +: 64]),
                .causal_lane_bubbles(), .causal_rows_skipped(),
                .memory_request_stalls(), .mac_issue_stalls(),
                .scheduler_protocol_errors(), .scheduler_protocol_error_sticky(engine_sticky[c]),
                .fp32_requests_accepted(), .fp32_mul_products_completed(),
                .fp32_add_results_completed(), .fp32_response_transfers(),
                .fp32_protocol_errors(), .fp32_protocol_error_sticky(),
                .score_commits(), .score_commit_stalls(),
                .score_fifo_max_occupancy()
            );

            cats_r4_qk_a2_row_pipeline #(
                .SEQ_LEN(SEQ_LEN), .LANES(LANES), .SLOTS(SLOTS),
                .SCALE_FP32(SCALE_FP32)
            ) u_rows (
                .clk, .rst_n, .clear, .counter_clear,
                .txn_start_valid(txn_start_valid),
                .txn_start_ready(row_txn_start_ready[c]),
                .txn_epoch, .txn_numeric_mode,
                .raw_score_valid(engine_score_valid[c]),
                .raw_score_ready(engine_score_ready[c]),
                .raw_score_epoch(engine_score_epoch[c*16 +: 16]),
                .raw_score_group(engine_score_group[c*3 +: 3]),
                .raw_score_global_q_head(engine_score_head[c*5 +: 5]),
                .raw_score_row(engine_score_row[c*7 +: 7]),
                .raw_score_key_block(engine_score_key_block[c*2 +: 2]),
                .raw_score_context_tag(engine_score_context[c*4 +: 4]),
                .raw_score_lane_valid(engine_score_lane_valid[c*LANES +: LANES]),
                .raw_score_fp32(engine_score_fp32[c*LANES*32 +: LANES*32]),
                .store_wr_valid(store_wr_valid[c]),
                .store_wr_ready(store_wr_ready[c]),
                .store_wr_slot_id(store_wr_slot_id[c*2 +: 2]),
                .store_wr_key_base(store_wr_key_base[c*7 +: 7]),
                .store_wr_lane_valid(store_wr_lane_valid[c*LANES +: LANES]),
                .store_wr_score_bf16(store_wr_score_bf16[c*LANES*16 +: LANES*16]),
                .score_rd_req_valid(score_rd_req_valid[c]),
                .score_rd_req_ready(score_rd_req_ready[c]),
                .score_rd_req_epoch(score_rd_req_epoch[c*16 +: 16]),
                .score_rd_req_group(score_rd_req_group[c*3 +: 3]),
                .score_rd_req_global_q_head(score_rd_req_global_q_head[c*5 +: 5]),
                .score_rd_req_row(score_rd_req_row[c*7 +: 7]),
                .score_rd_req_key(score_rd_req_key[c*7 +: 7]),
                .score_rd_req_slot_id(score_rd_req_slot_id[c*2 +: 2]),
                .score_rd_req_numeric_mode(score_rd_req_numeric_mode[c*2 +: 2]),
                .score_rd_rsp_valid(score_rd_rsp_valid[c]),
                .score_rd_rsp_ready(score_rd_rsp_ready[c]),
                .score_rd_rsp_epoch(score_rd_rsp_epoch[c*16 +: 16]),
                .score_rd_rsp_group(score_rd_rsp_group[c*3 +: 3]),
                .score_rd_rsp_global_q_head(score_rd_rsp_global_q_head[c*5 +: 5]),
                .score_rd_rsp_row(score_rd_rsp_row[c*7 +: 7]),
                .score_rd_rsp_key(score_rd_rsp_key[c*7 +: 7]),
                .score_rd_rsp_slot_id(score_rd_rsp_slot_id[c*2 +: 2]),
                .score_rd_rsp_numeric_mode(score_rd_rsp_numeric_mode[c*2 +: 2]),
                .score_rd_rsp_bf16(score_rd_rsp_bf16[c*16 +: 16]),
                .b_row_valid(b_row_valid[c]), .b_row_ready(b_row_ready[c]),
                .b_row_epoch(b_row_epoch[c*16 +: 16]),
                .b_row_group(b_row_group[c*3 +: 3]),
                .b_row_global_q_head(b_row_global_q_head[c*5 +: 5]),
                .b_row_index(b_row_index[c*7 +: 7]),
                .b_row_slot_id(b_row_slot_id[c*2 +: 2]),
                .b_row_numeric_mode(b_row_numeric_mode[c*2 +: 2]),
                .b_row_max_bf16(b_row_max_bf16[c*16 +: 16]),
                .b_score_valid(b_score_valid[c]), .b_score_ready(b_score_ready[c]),
                .b_score_epoch(b_score_epoch[c*16 +: 16]),
                .b_score_group(b_score_group[c*3 +: 3]),
                .b_score_global_q_head(b_score_global_q_head[c*5 +: 5]),
                .b_score_row(b_score_row[c*7 +: 7]),
                .b_score_key(b_score_key[c*7 +: 7]),
                .b_score_slot_id(b_score_slot_id[c*2 +: 2]),
                .b_score_numeric_mode(b_score_numeric_mode[c*2 +: 2]),
                .b_score_bf16(b_score_bf16[c*16 +: 16]),
                .b_score_last(b_score_last[c]),
                .final_release_valid(final_release_valid[c]),
                .final_release_ready(final_release_ready[c]),
                .final_release_epoch(final_release_epoch[c*16 +: 16]),
                .final_release_group(final_release_group[c*3 +: 3]),
                .final_release_global_q_head(final_release_global_q_head[c*5 +: 5]),
                .final_release_row(final_release_row[c*7 +: 7]),
                .final_release_slot_id(final_release_slot_id[c*2 +: 2]),
                .final_release_numeric_mode(final_release_numeric_mode[c*2 +: 2]),
                .row_abort_valid(row_abort_valid[c]),
                .row_abort_ready(row_abort_ready[c]),
                .row_abort_epoch(row_abort_epoch[c*16 +: 16]),
                .row_abort_group(row_abort_group[c*3 +: 3]),
                .row_abort_global_q_head(row_abort_global_q_head[c*5 +: 5]),
                .row_abort_row(row_abort_row[c*7 +: 7]),
                .row_abort_error_key(row_abort_error_key[c*7 +: 7]),
                .row_abort_slot_id(row_abort_slot_id[c*2 +: 2]),
                .row_abort_numeric_mode(row_abort_numeric_mode[c*2 +: 2]),
                .row_abort_error_code(row_abort_error_code[c*3 +: 3]),
                .slot_owner(slot_owner[c*6 +: 6]),
                .rows_completed(cluster_rows_completed[c*64 +: 64]),
                .scores_transferred(cluster_scores_transferred[c*64 +: 64]),
                .rows_transferred(cluster_rows_transferred[c*64 +: 64]),
                .owner_errors(), .scale_requests_accepted(),
                .scale_products_completed(), .score_format_transfers(),
                .formatter_protocol_errors(), .protocol_error_sticky(row_sticky[c])
            );
        end
    endgenerate

    // Assignment errors are intentionally separate from protocol errors in
    // the child blocks.  Invalid group/head jobs never enter a child FIFO.
    generate
        for (c = 0; c < CLUSTERS; c = c + 1) begin : GEN_ASSIGNMENT_COUNTER
            always_ff @(posedge clk) begin
                if (!rst_n || clear || counter_clear)
                    cluster_assignment_errors[c*64 +: 64] <= '0;
                else if ((c == 0) && job_valid && !job_fields_valid &&
                         !assignment_error_seen[0])
                    cluster_assignment_errors[c*64 +: 64] <=
                        cluster_assignment_errors[c*64 +: 64] + 1'b1;
            end
        end
    endgenerate

    always_comb begin
        protocol_error_sticky = qslab_sticky | engine_sticky | row_sticky;
    end

    initial begin
        if ((CLUSTERS != 1) && (CLUSTERS != 2) && (CLUSTERS != 4))
            $error("cats_r4_compute_frontend: CLUSTERS must be 1, 2 or 4");
        if ((SEQ_LEN != 128) || (HEAD_DIM <= 0) ||
            (CONTEXTS != 16) || (LANES != 32) || (SLOTS != 3))
            $error("cats_r4_compute_frontend: expected CATS-R4 S=128,R=16,lanes=32,SLOTS=3");
    end
endmodule
