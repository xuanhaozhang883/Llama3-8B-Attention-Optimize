`timescale 1ns/1ps

// End-to-end A-front-end simulation.  The Q/K and score-store models are
// intentionally in this testbench (never in production RTL): they provide
// deterministic BF16=1.0 data, two-cycle memory response latency, random
// ready/backpressure, final-release return, and optional negative injections.
// HEAD_DIM is kept at four so the complete 4,096-row workload is practical in
// Icarus; the scheduler's 128-dimensional full-workload counter is checked by
// its dedicated regression and the expected score/MAC scaling is recorded.
module tb_cats_r4_compute_frontend_e2e #(
    parameter int CLUSTERS = 1,
    parameter int HEAD_DIM = 4,
    parameter int TOTAL_JOBS = 256,
    parameter int RANDOM_STALL = 1,
    parameter int INJECT_NEGATIVE = 0,
    parameter int RESET_MIDRUN = 0
);
    localparam int SEQ_LEN = 128;
    localparam int LANES = 32;
    localparam int SLOTS = 3;
    localparam int EXPECTED_ROWS = TOTAL_JOBS * 16;
    localparam int FULL_WINDOWS = TOTAL_JOBS / 32;
    localparam int PARTIAL_WINDOW_JOBS = TOTAL_JOBS % 32;
    // Jobs are submitted window-major.  Every job in row window w contains
    // sum(row+1, row=16*w..16*w+15) = 256*w+136 causal scores.
    localparam int EXPECTED_SCORES =
        32 * (256 * FULL_WINDOWS * (FULL_WINDOWS-1) / 2 +
              136 * FULL_WINDOWS) +
        PARTIAL_WINDOW_JOBS * (256 * FULL_WINDOWS + 136);
    localparam int EXPECTED_MACS = EXPECTED_SCORES * HEAD_DIM;

    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0, clear = 0, counter_clear = 0;
    logic txn_start_valid = 0, txn_start_ready;
    logic [15:0] txn_epoch = 16'hcafe;
    logic [1:0] txn_numeric_mode = 1;
    logic job_valid = 0, job_ready;
    logic [15:0] job_epoch = 16'hcafe;
    logic [2:0] job_group = 0;
    logic [4:0] job_head = 0;
    logic [2:0] job_window = 0;

    logic [CLUSTERS-1:0] q_slab_need_valid, q_slab_need_ready = '1;
    logic [CLUSTERS*16-1:0] q_slab_need_epoch;
    logic [CLUSTERS*3-1:0] q_slab_need_group;
    logic [CLUSTERS*5-1:0] q_slab_need_head;
    logic [CLUSTERS*3-1:0] q_slab_need_window;
    logic [CLUSTERS-1:0] q_slab_ready_valid = '0, q_slab_ready_ready;
    logic [CLUSTERS*16-1:0] q_slab_ready_epoch = '0;
    logic [CLUSTERS*3-1:0] q_slab_ready_group = '0;
    logic [CLUSTERS*5-1:0] q_slab_ready_head = '0;
    logic [CLUSTERS*3-1:0] q_slab_ready_window = '0;
    logic [CLUSTERS-1:0] q_slab_ready_buffer = '0;
    logic [CLUSTERS-1:0] q_slab_retire_valid, q_slab_retire_ready = '1;

    logic [CLUSTERS-1:0] q_req_valid, q_req_ready = '1, q_rsp_valid = '0;
    logic [CLUSTERS*4-1:0] q_req_context, q_rsp_context = '0;
    logic [CLUSTERS*7-1:0] q_req_d;
    logic [CLUSTERS*16-1:0] q_rsp_bf16 = '0;
    logic [CLUSTERS-1:0] k_req_valid, k_req_ready = '1, k_rsp_valid = '0;
    logic [CLUSTERS*4-1:0] k_req_context, k_rsp_context = '0;
    logic [CLUSTERS*2-1:0] k_req_key_block;
    logic [CLUSTERS*7-1:0] k_req_d;
    logic [CLUSTERS*512-1:0] k_rsp_vec = '0;

    logic [CLUSTERS-1:0] store_wr_valid, store_wr_ready;
    logic [CLUSTERS*2-1:0] store_wr_slot;
    logic [CLUSTERS*7-1:0] store_wr_key_base;
    logic [CLUSTERS*LANES-1:0] store_wr_lane_valid;
    logic [CLUSTERS*LANES*16-1:0] store_wr_data;
    logic [CLUSTERS-1:0] score_rd_req_valid, score_rd_req_ready = '1;
    logic [CLUSTERS*16-1:0] score_rd_req_epoch;
    logic [CLUSTERS*3-1:0] score_rd_req_group;
    logic [CLUSTERS*5-1:0] score_rd_req_head;
    logic [CLUSTERS*7-1:0] score_rd_req_row, score_rd_req_key;
    logic [CLUSTERS*2-1:0] score_rd_req_slot, score_rd_req_mode;
    logic [CLUSTERS-1:0] score_rd_rsp_valid = '0, score_rd_rsp_ready;
    logic [CLUSTERS*16-1:0] score_rd_rsp_epoch = '0;
    logic [CLUSTERS*3-1:0] score_rd_rsp_group = '0;
    logic [CLUSTERS*5-1:0] score_rd_rsp_head = '0;
    logic [CLUSTERS*7-1:0] score_rd_rsp_row = '0, score_rd_rsp_key = '0;
    logic [CLUSTERS*2-1:0] score_rd_rsp_slot = '0, score_rd_rsp_mode = '0;
    logic [CLUSTERS*16-1:0] score_rd_rsp_data = '0;

    logic [CLUSTERS-1:0] b_row_valid, b_row_ready;
    logic [CLUSTERS*16-1:0] b_row_epoch;
    logic [CLUSTERS*3-1:0] b_row_group;
    logic [CLUSTERS*5-1:0] b_row_head;
    logic [CLUSTERS*7-1:0] b_row_index;
    logic [CLUSTERS*2-1:0] b_row_slot, b_row_mode;
    logic [CLUSTERS*16-1:0] b_row_max;
    logic [CLUSTERS-1:0] b_score_valid, b_score_ready, b_score_last;
    logic [CLUSTERS*16-1:0] b_score_epoch, b_score_data;
    logic [CLUSTERS*3-1:0] b_score_group;
    logic [CLUSTERS*5-1:0] b_score_head;
    logic [CLUSTERS*7-1:0] b_score_row, b_score_key;
    logic [CLUSTERS*2-1:0] b_score_slot, b_score_mode;

    logic [CLUSTERS-1:0] final_release_valid, final_release_ready;
    logic [CLUSTERS*16-1:0] final_release_epoch = '0;
    logic [CLUSTERS*3-1:0] final_release_group = '0;
    logic [CLUSTERS*5-1:0] final_release_head = '0;
    logic [CLUSTERS*7-1:0] final_release_row = '0;
    logic [CLUSTERS*2-1:0] final_release_slot = '0, final_release_mode = '0;
    logic [CLUSTERS-1:0] row_abort_valid, row_abort_ready = '1;
    logic [CLUSTERS*16-1:0] row_abort_epoch;
    logic [CLUSTERS*3-1:0] row_abort_group;
    logic [CLUSTERS*5-1:0] row_abort_head;
    logic [CLUSTERS*7-1:0] row_abort_row, row_abort_error_key;
    logic [CLUSTERS*2-1:0] row_abort_slot, row_abort_mode;
    logic [CLUSTERS*3-1:0] row_abort_error_code;

    logic [CLUSTERS*6-1:0] slot_owner;
    logic [CLUSTERS*64-1:0] cluster_jobs, cluster_engine_started,
        cluster_engine_completed, cluster_rows, cluster_scores,
        cluster_rows_xfer, cluster_valid_macs, cluster_steps,
        cluster_steps_done, cluster_q_requests, cluster_k_requests,
        cluster_bubbles, cluster_skipped, cluster_owner_errors,
        cluster_assignment_errors;
    logic [CLUSTERS-1:0] protocol_sticky;

    logic [15:0] score_mem [0:CLUSTERS-1][0:SLOTS-1][0:SEQ_LEN-1];
    logic [CLUSTERS-1:0] q_pipe_v0, q_pipe_v1, k_pipe_v0, k_pipe_v1;
    logic [3:0] q_pipe_ctx0 [0:CLUSTERS-1], q_pipe_ctx1 [0:CLUSTERS-1];
    logic [3:0] k_pipe_ctx0 [0:CLUSTERS-1], k_pipe_ctx1 [0:CLUSTERS-1];
    logic [CLUSTERS-1:0] q_ready_pending;
    logic [CLUSTERS*16-1:0] q_pending_epoch;
    logic [CLUSTERS*3-1:0] q_pending_group;
    logic [CLUSTERS*5-1:0] q_pending_head;
    logic [CLUSTERS*3-1:0] q_pending_window;
    logic [31:0] lfsr = 32'h1a2b3c4d;
    logic [CLUSTERS-1:0] release_dup_pending, release_dup_active, release_dup_done;
    integer error_rsp_budget = INJECT_NEGATIVE;
    integer cycle_count = 0;
    integer observed_rows = 0, observed_scores = 0, observed_aborts = 0;
    integer max_occupancy [0:CLUSTERS-1];
    integer first_row_cycle [0:CLUSTERS-1], last_row_cycle [0:CLUSTERS-1];
    integer first_score_cycle [0:CLUSTERS-1], last_score_cycle [0:CLUSTERS-1];
    integer row_header_seen [0:CLUSTERS-1], expected_key [0:CLUSTERS-1];
    integer expected_row [0:CLUSTERS-1];
    integer c, lane;
    integer counter_job_sum, counter_engine_start_sum;
    integer counter_engine_done_sum, counter_row_sum, counter_score_sum;
    integer counter_row_xfer_sum, counter_q_sum, counter_k_sum;
    integer counter_step_sum, counter_step_done_sum, counter_mac_sum;
    integer counter_owner_error_sum, counter_assignment_error_sum;
    integer log_fd;
    string log_name;

    cats_r4_compute_frontend #(
        .CLUSTERS(CLUSTERS), .HEAD_DIM(HEAD_DIM),
        // The repository mock implements a finite e8 scale table; use unity
        // here because this test targets protocol/workload closure.
        .SCALE_FP32(32'h3f800000)
    ) dut (
        .clk, .rst_n, .clear, .counter_clear,
        .txn_start_valid, .txn_start_ready, .txn_epoch, .txn_numeric_mode,
        .job_valid, .job_ready, .job_epoch, .job_group,
        .job_global_q_head(job_head), .job_row_window(job_window),
        .q_slab_need_valid, .q_slab_need_ready, .q_slab_need_epoch,
        .q_slab_need_group, .q_slab_need_global_q_head(q_slab_need_head),
        .q_slab_need_row_window(q_slab_need_window), .q_slab_ready_valid,
        .q_slab_ready_ready, .q_slab_ready_epoch,
        .q_slab_ready_group, .q_slab_ready_global_q_head(q_slab_ready_head),
        .q_slab_ready_row_window(q_slab_ready_window), .q_slab_ready_buffer,
        .q_slab_retire_valid, .q_slab_retire_ready, .q_slab_retire_epoch(),
        .q_slab_retire_group(), .q_slab_retire_global_q_head(),
        .q_slab_retire_row_window(), .q_slab_retire_buffer(),
        .q_req_valid, .q_req_ready, .q_req_context_tag(q_req_context),
        .q_req_d, .q_rsp_valid, .q_rsp_context_tag(q_rsp_context),
        .q_rsp_bf16, .k_req_valid, .k_req_ready,
        .k_req_context_tag(k_req_context), .k_req_key_block, .k_req_d,
        .k_rsp_valid, .k_rsp_context_tag(k_rsp_context), .k_rsp_vec,
        .store_wr_valid, .store_wr_ready, .store_wr_slot_id(store_wr_slot),
        .store_wr_key_base, .store_wr_lane_valid, .store_wr_score_bf16(store_wr_data),
        .score_rd_req_valid, .score_rd_req_ready, .score_rd_req_epoch,
        .score_rd_req_group, .score_rd_req_global_q_head(score_rd_req_head),
        .score_rd_req_row, .score_rd_req_key, .score_rd_req_slot_id(score_rd_req_slot),
        .score_rd_req_numeric_mode(score_rd_req_mode), .score_rd_rsp_valid,
        .score_rd_rsp_ready, .score_rd_rsp_epoch, .score_rd_rsp_group,
        .score_rd_rsp_global_q_head(score_rd_rsp_head), .score_rd_rsp_row,
        .score_rd_rsp_key, .score_rd_rsp_slot_id(score_rd_rsp_slot),
        .score_rd_rsp_numeric_mode(score_rd_rsp_mode), .score_rd_rsp_bf16(score_rd_rsp_data),
        .b_row_valid, .b_row_ready, .b_row_epoch, .b_row_group,
        .b_row_global_q_head(b_row_head), .b_row_index, .b_row_slot_id(b_row_slot),
        .b_row_numeric_mode(b_row_mode), .b_row_max_bf16(b_row_max),
        .b_score_valid, .b_score_ready, .b_score_epoch, .b_score_group,
        .b_score_global_q_head(b_score_head), .b_score_row, .b_score_key,
        .b_score_slot_id(b_score_slot), .b_score_numeric_mode(b_score_mode),
        .b_score_bf16(b_score_data), .b_score_last, .final_release_valid,
        .final_release_ready, .final_release_epoch, .final_release_group,
        .final_release_global_q_head(final_release_head), .final_release_row,
        .final_release_slot_id(final_release_slot),
        .final_release_numeric_mode(final_release_mode), .row_abort_valid,
        .row_abort_ready, .row_abort_epoch, .row_abort_group,
        .row_abort_global_q_head(row_abort_head), .row_abort_row,
        .row_abort_error_key, .row_abort_slot_id(row_abort_slot),
        .row_abort_numeric_mode(row_abort_mode), .row_abort_error_code,
        .slot_owner, .cluster_jobs_accepted(cluster_jobs),
        .cluster_engine_jobs_started(cluster_engine_started),
        .cluster_engine_jobs_completed(cluster_engine_completed),
        .cluster_rows_completed(cluster_rows),
        .cluster_scores_transferred(cluster_scores),
        .cluster_rows_transferred(cluster_rows_xfer),
        .cluster_owner_errors, .cluster_valid_macs, .cluster_mac_steps_issued(cluster_steps),
        .cluster_mac_steps_completed(cluster_steps_done),
        .cluster_q_requests_accepted(cluster_q_requests),
        .cluster_k_requests_accepted(cluster_k_requests),
        .cluster_causal_lane_bubbles(cluster_bubbles),
        .cluster_causal_rows_skipped(cluster_skipped),
        .cluster_assignment_errors, .protocol_error_sticky(protocol_sticky)
    );

    always_comb begin
        for (integer rc = 0; rc < CLUSTERS; rc = rc + 1) begin
            if (!RANDOM_STALL) begin
                store_wr_ready[rc] = 1'b1;
                b_row_ready[rc] = 1'b1;
                b_score_ready[rc] = !final_release_valid[rc];
            end else begin
                store_wr_ready[rc] = lfsr[(rc+3) % 32] | !lfsr[(rc+9) % 32];
                b_row_ready[rc] = lfsr[(rc+11) % 32] | lfsr[(rc+17) % 32];
                b_score_ready[rc] = (lfsr[(rc+21) % 32] | lfsr[(rc+27) % 32]) &&
                                    !final_release_valid[rc];
            end
        end
    end

    always_ff @(posedge clk) begin : service_model
        integer sc;
        if (!rst_n || clear) begin
            lfsr <= 32'h1a2b3c4d;
            q_pipe_v0 <= '0; q_pipe_v1 <= '0;
            k_pipe_v0 <= '0; k_pipe_v1 <= '0;
            q_rsp_valid <= '0; k_rsp_valid <= '0;
            q_rsp_context <= '0; k_rsp_context <= '0;
            q_slab_ready_valid <= '0; q_ready_pending <= '0;
            score_rd_rsp_valid <= '0;
            q_pending_epoch <= '0; q_pending_group <= '0;
            q_pending_head <= '0; q_pending_window <= '0;
            for (sc = 0; sc < CLUSTERS; sc = sc + 1) begin
                q_pipe_ctx0[sc] <= '0; q_pipe_ctx1[sc] <= '0;
                k_pipe_ctx0[sc] <= '0; k_pipe_ctx1[sc] <= '0;
            end
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            for (sc = 0; sc < CLUSTERS; sc = sc + 1) begin
                // Two-cycle Q/K response.
                q_rsp_valid[sc] <= q_pipe_v1[sc];
                q_rsp_context[sc*4 +: 4] <= q_pipe_ctx1[sc];
                q_rsp_bf16[sc*16 +: 16] <= 16'h3f80;
                q_pipe_v1[sc] <= q_pipe_v0[sc];
                q_pipe_ctx1[sc] <= q_pipe_ctx0[sc];
                q_pipe_v0[sc] <= q_req_valid[sc] && q_req_ready[sc];
                q_pipe_ctx0[sc] <= q_req_context[sc*4 +: 4];
                k_rsp_valid[sc] <= k_pipe_v1[sc];
                k_rsp_context[sc*4 +: 4] <= k_pipe_ctx1[sc];
                for (lane = 0; lane < LANES; lane = lane + 1)
                    k_rsp_vec[sc*512 + lane*16 +: 16] <= 16'h3f80;
                k_pipe_v1[sc] <= k_pipe_v0[sc];
                k_pipe_ctx1[sc] <= k_pipe_ctx0[sc];
                k_pipe_v0[sc] <= k_req_valid[sc] && k_req_ready[sc];
                k_pipe_ctx0[sc] <= k_req_context[sc*4 +: 4];

                // Q-slab need/ready has one registered response cycle.
                if (q_slab_ready_valid[sc] && q_slab_ready_ready[sc])
                    q_slab_ready_valid[sc] <= 1'b0;
                if (q_ready_pending[sc]) begin
                    q_slab_ready_valid[sc] <= 1'b1;
                    q_slab_ready_epoch[sc*16 +: 16] <= q_pending_epoch[sc*16 +: 16];
                    q_slab_ready_group[sc*3 +: 3] <= q_pending_group[sc*3 +: 3];
                    q_slab_ready_head[sc*5 +: 5] <= q_pending_head[sc*5 +: 5];
                    q_slab_ready_window[sc*3 +: 3] <= q_pending_window[sc*3 +: 3];
                    q_slab_ready_buffer[sc] <= sc[0];
                    q_ready_pending[sc] <= 1'b0;
                end
                if (q_slab_need_valid[sc] && q_slab_need_ready[sc]) begin
                    q_ready_pending[sc] <= 1'b1;
                    q_pending_epoch[sc*16 +: 16] <= q_slab_need_epoch[sc*16 +: 16];
                    q_pending_group[sc*3 +: 3] <= q_slab_need_group[sc*3 +: 3];
                    q_pending_head[sc*5 +: 5] <= q_slab_need_head[sc*5 +: 5];
                    q_pending_window[sc*3 +: 3] <= q_slab_need_window[sc*3 +: 3];
                end

                // Score store write service.
                if (store_wr_valid[sc] && store_wr_ready[sc])
                    for (lane = 0; lane < LANES; lane = lane + 1)
                        if (store_wr_lane_valid[sc*LANES + lane])
                            score_mem[sc][store_wr_slot[sc*2 +: 2]]
                                     [store_wr_key_base[sc*7 +: 7] + lane] <=
                                store_wr_data[sc*LANES*16 + lane*16 +: 16];

                // One-cycle score read response.  Optional negative mode
                // corrupts exactly one response token/epoch per run.
                if (score_rd_rsp_valid[sc] && score_rd_rsp_ready[sc])
                    score_rd_rsp_valid[sc] <= 1'b0;
                if (score_rd_req_valid[sc] && score_rd_req_ready[sc]) begin
                    score_rd_rsp_valid[sc] <= 1'b1;
                    score_rd_rsp_epoch[sc*16 +: 16] <=
                        (error_rsp_budget > 0) ? 16'hdead :
                        score_rd_req_epoch[sc*16 +: 16];
                    score_rd_rsp_group[sc*3 +: 3] <= score_rd_req_group[sc*3 +: 3];
                    score_rd_rsp_head[sc*5 +: 5] <= score_rd_req_head[sc*5 +: 5];
                    score_rd_rsp_row[sc*7 +: 7] <= score_rd_req_row[sc*7 +: 7];
                    score_rd_rsp_key[sc*7 +: 7] <= score_rd_req_key[sc*7 +: 7];
                    score_rd_rsp_slot[sc*2 +: 2] <= score_rd_req_slot[sc*2 +: 2];
                    score_rd_rsp_mode[sc*2 +: 2] <= score_rd_req_mode[sc*2 +: 2];
                    score_rd_rsp_data[sc*16 +: 16] <=
                        (error_rsp_budget > 0) ? 16'h7fc0 :
                        score_mem[sc][score_rd_req_slot[sc*2 +: 2]]
                                           [score_rd_req_key[sc*7 +: 7]];
                    if (error_rsp_budget > 0)
                        error_rsp_budget = error_rsp_budget - 1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin : b_monitor
        integer mc, occupancy;
        if (!rst_n || clear) begin
            final_release_valid <= '0;
            release_dup_pending <= '0;
            release_dup_active <= '0;
            release_dup_done <= '0;
            observed_rows = 0; observed_scores = 0; observed_aborts = 0;
            for (mc = 0; mc < CLUSTERS; mc = mc + 1) begin
                row_header_seen[mc] <= 0; expected_key[mc] <= 0;
                expected_row[mc] <= 0; max_occupancy[mc] <= 0;
                first_row_cycle[mc] <= -1; last_row_cycle[mc] <= -1;
                first_score_cycle[mc] <= -1; last_score_cycle[mc] <= -1;
            end
        end else begin
            for (mc = 0; mc < CLUSTERS; mc = mc + 1) begin
                occupancy = 0;
                for (lane = 0; lane < SLOTS; lane = lane + 1)
                    occupancy = occupancy + (slot_owner[mc*6 + lane*2 +: 2] != 0);
                if (occupancy > max_occupancy[mc]) max_occupancy[mc] <= occupancy;

                if (final_release_valid[mc] && final_release_ready[mc]) begin
                    final_release_valid[mc] <= 1'b0;
                    if (INJECT_NEGATIVE && !release_dup_done[mc]) begin
                        release_dup_pending[mc] <= 1'b1;
                        release_dup_done[mc] <= 1'b1;
                    end
                end
                if (release_dup_active[mc]) begin
                    // A deliberately duplicated release is held for one
                    // cycle only: the owner checker must reject/count it,
                    // but it must not block subsequent B score traffic.
                    final_release_valid[mc] <= 1'b0;
                    release_dup_active[mc] <= 1'b0;
                end
                if (release_dup_pending[mc] && !final_release_valid[mc]) begin
                    final_release_valid[mc] <= 1'b1;
                    release_dup_pending[mc] <= 1'b0;
                    release_dup_active[mc] <= 1'b1;
                end

                if (b_row_valid[mc] && b_row_ready[mc]) begin
                    row_header_seen[mc] <= 1;
                    expected_key[mc] <= 0;
                    expected_row[mc] <= b_row_index[mc*7 +: 7];
                    observed_rows = observed_rows + 1;
                    if (first_row_cycle[mc] < 0) first_row_cycle[mc] <= cycle_count;
                    last_row_cycle[mc] <= cycle_count;
                end
                if (b_score_valid[mc] && b_score_ready[mc]) begin
                    if (!row_header_seen[mc] ||
                        b_score_key[mc*7 +: 7] != expected_key[mc])
                        $fatal(1, "score order/header violation cluster=%0d key=%0d exp=%0d",
                               mc, b_score_key[mc*7 +: 7], expected_key[mc]);
                    observed_scores = observed_scores + 1;
                    if (first_score_cycle[mc] < 0) first_score_cycle[mc] <= cycle_count;
                    last_score_cycle[mc] <= cycle_count;
                    if (b_score_last[mc]) begin
                        row_header_seen[mc] <= 0;
                        final_release_valid[mc] <= 1'b1;
                        final_release_epoch[mc*16 +: 16] <= b_score_epoch[mc*16 +: 16];
                        final_release_group[mc*3 +: 3] <= b_score_group[mc*3 +: 3];
                        final_release_head[mc*5 +: 5] <= b_score_head[mc*5 +: 5];
                        final_release_row[mc*7 +: 7] <= b_score_row[mc*7 +: 7];
                        final_release_slot[mc*2 +: 2] <= b_score_slot[mc*2 +: 2];
                        final_release_mode[mc*2 +: 2] <= b_score_mode[mc*2 +: 2];
                    end else begin
                        expected_key[mc] <= expected_key[mc] + 1;
                    end
                end
                if (row_abort_valid[mc] && row_abort_ready[mc]) begin
                    observed_aborts = observed_aborts + 1;
                    row_header_seen[mc] <= 0;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst_n) cycle_count = cycle_count + 1;
    end

    task automatic tick;
        @(posedge clk); #1;
    endtask

    integer head_i, window_i, sent_jobs, timeout_cycles, done_wait;
    initial begin
        if (!$value$plusargs("LOG_FILE=%s", log_name))
            log_name = $sformatf("cats_r4_compute_frontend_e2e_%0dc.log", CLUSTERS);
        log_fd = $fopen(log_name, "w");
        repeat (4) tick(); rst_n = 1; repeat (2) tick();
        @(negedge clk); txn_start_valid = 1;
        while (!txn_start_ready) tick();
        tick(); @(negedge clk); txn_start_valid = 0;

        sent_jobs = 0;
        if (RESET_MIDRUN) begin
            // Prove that a queued job and all in-flight Q/K/score state are
            // discarded by clear, then restart the same transaction cleanly.
            job_group = 0; job_head = 0; job_window = 0;
            @(negedge clk); job_valid = 1;
            while (!job_ready) tick();
            tick(); @(negedge clk); job_valid = 0;
            clear = 1; tick(); clear = 0; repeat (2) tick();
            @(negedge clk); txn_start_valid = 1;
            while (!txn_start_ready) tick();
            tick(); @(negedge clk); txn_start_valid = 0;
        end
        // Window-major order fills the per-cluster one-entry queues and lets
        // distinct static group assignments overlap.
        for (window_i = 0; window_i < 8 && sent_jobs < TOTAL_JOBS;
             window_i = window_i + 1) begin
            for (head_i = 0; head_i < 32 && sent_jobs < TOTAL_JOBS;
                 head_i = head_i + 1) begin
                job_group = head_i / 4;
                job_head = head_i;
                job_window = window_i;
                @(negedge clk); job_valid = 1;
                while (!job_ready) tick();
                tick(); @(negedge clk); job_valid = 0;
                sent_jobs = sent_jobs + 1;
            end
        end

        timeout_cycles = 0;
        done_wait = 0;
        while (!done_wait) begin
            tick(); timeout_cycles = timeout_cycles + 1;
            if (timeout_cycles > 3000000)
                $fatal(1, "frontend e2e timeout jobs=%0d rows=%0d scores=%0d",
                       sent_jobs, observed_rows, observed_scores);
            // Wait for both the final row header and the final score token.
            // The row header can handshake one cycle before its 128th score;
            // stopping on rows alone would under-report one complete row.
            counter_score_sum = 0;
            for (c = 0; c < CLUSTERS; c = c + 1)
                counter_score_sum = counter_score_sum + cluster_scores[c*64 +: 64];
            counter_row_xfer_sum = 0;
            for (c = 0; c < CLUSTERS; c = c + 1)
                counter_row_xfer_sum = counter_row_xfer_sum +
                                       cluster_rows_xfer[c*64 +: 64];
            if ((observed_rows == EXPECTED_ROWS) &&
                ((!INJECT_NEGATIVE &&
                  (counter_score_sum >= EXPECTED_SCORES)) ||
                 (INJECT_NEGATIVE && (observed_aborts > 0) &&
                  ((counter_row_xfer_sum + observed_aborts) >= EXPECTED_ROWS))))
                done_wait = 1;
        end

        counter_job_sum = 0;
        counter_engine_start_sum = 0;
        counter_engine_done_sum = 0;
        counter_row_sum = 0;
        counter_score_sum = 0;
        counter_row_xfer_sum = 0;
        counter_q_sum = 0;
        counter_k_sum = 0;
        counter_step_sum = 0;
        counter_step_done_sum = 0;
        counter_mac_sum = 0;
        counter_owner_error_sum = 0;
        counter_assignment_error_sum = 0;
        for (c = 0; c < CLUSTERS; c = c + 1) begin
            counter_job_sum = counter_job_sum + cluster_jobs[c*64 +: 64];
            counter_engine_start_sum = counter_engine_start_sum + cluster_engine_started[c*64 +: 64];
            counter_engine_done_sum = counter_engine_done_sum + cluster_engine_completed[c*64 +: 64];
            counter_row_sum = counter_row_sum + cluster_rows[c*64 +: 64];
            counter_score_sum = counter_score_sum + cluster_scores[c*64 +: 64];
            counter_row_xfer_sum = counter_row_xfer_sum + cluster_rows_xfer[c*64 +: 64];
            counter_q_sum = counter_q_sum + cluster_q_requests[c*64 +: 64];
            counter_k_sum = counter_k_sum + cluster_k_requests[c*64 +: 64];
            counter_step_sum = counter_step_sum + cluster_steps[c*64 +: 64];
            counter_step_done_sum = counter_step_done_sum + cluster_steps_done[c*64 +: 64];
            counter_mac_sum = counter_mac_sum + cluster_valid_macs[c*64 +: 64];
            counter_owner_error_sum = counter_owner_error_sum + cluster_owner_errors[c*64 +: 64];
            counter_assignment_error_sum = counter_assignment_error_sum + cluster_assignment_errors[c*64 +: 64];
        end

        $fwrite(log_fd, "CLUSTERS=%0d HEAD_DIM=%0d jobs=%0d rows=%0d scores=%0d aborts=%0d cycles=%0d\n",
                CLUSTERS, HEAD_DIM, sent_jobs, observed_rows, observed_scores,
                observed_aborts, cycle_count);
        for (c = 0; c < CLUSTERS; c = c + 1)
            $fwrite(log_fd, "cluster=%0d jobs=%0d engine=%0d/%0d q=%0d k=%0d steps=%0d/%0d valid_macs=%0d max_slot_occupancy=%0d first_row=%0d last_row=%0d first_score=%0d last_score=%0d owner_errors=%0d\n",
                    c, cluster_jobs[c*64 +: 64],
                    cluster_engine_started[c*64 +: 64],
                    cluster_engine_completed[c*64 +: 64],
                    cluster_q_requests[c*64 +: 64],
                    cluster_k_requests[c*64 +: 64],
                    cluster_steps[c*64 +: 64], cluster_steps_done[c*64 +: 64],
                    cluster_valid_macs[c*64 +: 64], max_occupancy[c],
                    first_row_cycle[c], last_row_cycle[c],
                    first_score_cycle[c], last_score_cycle[c],
                    cluster_owner_errors[c*64 +: 64]);
        $fwrite(log_fd, "aggregate jobs=%0d engine=%0d/%0d q=%0d k=%0d steps=%0d/%0d valid_macs=%0d rows=%0d rows_xfer=%0d scores=%0d owner_errors=%0d assignment_errors=%0d\n",
                counter_job_sum, counter_engine_start_sum,
                counter_engine_done_sum, counter_q_sum, counter_k_sum,
                counter_step_sum, counter_step_done_sum, counter_mac_sum,
                counter_row_sum, counter_row_xfer_sum, counter_score_sum,
                counter_owner_error_sum, counter_assignment_error_sum);
        $fclose(log_fd);

        if (observed_rows != EXPECTED_ROWS)
            $fatal(1, "row count mismatch got=%0d exp=%0d", observed_rows, EXPECTED_ROWS);
        if (!INJECT_NEGATIVE && (counter_score_sum != EXPECTED_SCORES))
            $fatal(1, "score counter mismatch got=%0d exp=%0d",
                   counter_score_sum, EXPECTED_SCORES);
        if ((TOTAL_JOBS == 256) && !INJECT_NEGATIVE) begin
            if ((counter_job_sum != 256) ||
                (counter_engine_start_sum != 6144) ||
                (counter_engine_done_sum != 6144) ||
                (counter_q_sum != 40960) || (counter_k_sum != 40960) ||
                (counter_step_sum != 40960) ||
                (counter_step_done_sum != 40960) ||
                (counter_mac_sum != EXPECTED_MACS) ||
                (counter_row_sum != EXPECTED_ROWS) ||
                (counter_row_xfer_sum != EXPECTED_ROWS))
                $fatal(1, "full-workload conservation mismatch jobs=%0d engine=%0d/%0d qk=%0d/%0d steps=%0d/%0d macs=%0d rows=%0d/%0d",
                       counter_job_sum, counter_engine_start_sum,
                       counter_engine_done_sum, counter_q_sum, counter_k_sum,
                       counter_step_sum, counter_step_done_sum, counter_mac_sum,
                       counter_row_sum, counter_row_xfer_sum);
            for (c = 0; c < CLUSTERS; c = c + 1) begin
                if (cluster_jobs[c*64 +: 64] != (256 / CLUSTERS))
                    $fatal(1, "cluster %0d load imbalance jobs=%0d expected=%0d",
                           c, cluster_jobs[c*64 +: 64], 256 / CLUSTERS);
                if (max_occupancy[c] != SLOTS)
                    $fatal(1, "cluster %0d max occupancy=%0d expected=%0d",
                           c, max_occupancy[c], SLOTS);
            end
            // Every pair of active cluster intervals must overlap.  This is
            // timestamp evidence that the replicated frontends ran in
            // parallel, rather than merely receiving balanced work serially.
            for (c = 0; c < CLUSTERS; c = c + 1)
                for (lane = c + 1; lane < CLUSTERS; lane = lane + 1)
                    if ((first_row_cycle[c] > last_row_cycle[lane]) ||
                        (first_row_cycle[lane] > last_row_cycle[c]))
                        $fatal(1, "clusters %0d/%0d did not overlap [%0d,%0d]/[%0d,%0d]",
                               c, lane, first_row_cycle[c], last_row_cycle[c],
                               first_row_cycle[lane], last_row_cycle[lane]);
        end
        if (!INJECT_NEGATIVE && observed_aborts != 0)
            $fatal(1, "unexpected aborts=%0d", observed_aborts);
        if (INJECT_NEGATIVE && (observed_aborts == 0))
            $fatal(1, "negative injection did not produce row_abort");
        if (!INJECT_NEGATIVE && (counter_owner_error_sum != 0))
            $fatal(1, "unexpected owner errors=%0d", counter_owner_error_sum);
        if (INJECT_NEGATIVE && (counter_owner_error_sum == 0))
            $fatal(1, "duplicate release did not produce owner error");
        if (counter_assignment_error_sum != 0)
            $fatal(1, "unexpected assignment errors=%0d", counter_assignment_error_sum);
        if (!INJECT_NEGATIVE && (protocol_sticky != '0))
            $fatal(1, "unexpected protocol error sticky=%b", protocol_sticky);
        for (c = 0; c < CLUSTERS; c = c + 1)
            if ((cluster_jobs[c*64 +: 64] != 0) && (max_occupancy[c] < 2))
                $fatal(1, "cluster %0d did not demonstrate slot overlap occupancy=%0d",
                       c, max_occupancy[c]);
        $display("PASS: CATS-R4 frontend end-to-end CLUSTERS=%0d jobs=%0d rows=%0d observed_scores=%0d counter_scores=%0d aborts=%0d",
                 CLUSTERS, sent_jobs, observed_rows, observed_scores,
                 counter_score_sum, observed_aborts);
        $finish;
    end

    initial begin
        repeat (3100000) tick();
        $fatal(1, "global frontend e2e timeout");
    end
endmodule
