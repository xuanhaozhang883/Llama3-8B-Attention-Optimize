`timescale 1ns/1ps

// Routing/contract smoke test for the A-owned multi-cluster frontend.  The
// test deliberately stops after q_slab_need: no memory service model is
// hidden in the production wrapper.  Resetting between groups lets all eight
// legal IF_V3 groups be checked without running the 33M-MAC workload.
module tb_cats_r4_compute_frontend_routing #(
    parameter int CLUSTERS = 1
);
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0, clear = 0, counter_clear = 0;
    logic txn_start_valid = 0, txn_start_ready;
    logic [15:0] txn_epoch = 16'hca75;
    logic [1:0] txn_numeric_mode = 1;
    logic job_valid = 0, job_ready;
    logic [15:0] job_epoch = 16'hca75;
    logic [2:0] job_group = 0;
    logic [4:0] job_global_q_head = 0;
    logic [2:0] job_row_window = 0;

    logic [CLUSTERS-1:0] q_slab_need_valid;
    logic [CLUSTERS*16-1:0] q_slab_need_epoch;
    logic [CLUSTERS*3-1:0] q_slab_need_group;
    logic [CLUSTERS*5-1:0] q_slab_need_head;
    logic [CLUSTERS*3-1:0] q_slab_need_window;
    logic [CLUSTERS-1:0] q_slab_need_ready = '1;
    logic [CLUSTERS-1:0] q_slab_ready_valid = '0;
    logic [CLUSTERS*16-1:0] q_slab_ready_epoch = '0;
    logic [CLUSTERS*3-1:0] q_slab_ready_group = '0;
    logic [CLUSTERS*5-1:0] q_slab_ready_head = '0;
    logic [CLUSTERS*3-1:0] q_slab_ready_window = '0;
    logic [CLUSTERS-1:0] q_slab_ready_buffer = '0;
    logic [CLUSTERS-1:0] q_slab_retire_valid;
    logic [CLUSTERS-1:0] q_slab_retire_ready = '1;

    logic [CLUSTERS-1:0] q_req_ready = '1, q_rsp_valid = '0;
    logic [CLUSTERS*4-1:0] q_rsp_context = '0;
    logic [CLUSTERS*16-1:0] q_rsp_bf16 = '0;
    logic [CLUSTERS-1:0] k_req_ready = '1, k_rsp_valid = '0;
    logic [CLUSTERS*4-1:0] k_rsp_context = '0;
    logic [CLUSTERS*512-1:0] k_rsp_vec = '0;

    logic [CLUSTERS-1:0] store_wr_ready = '1;
    logic [CLUSTERS-1:0] score_rd_req_ready = '1;
    logic [CLUSTERS-1:0] score_rd_rsp_valid = '0;
    logic [CLUSTERS*16-1:0] score_rd_rsp_epoch = '0;
    logic [CLUSTERS*3-1:0] score_rd_rsp_group = '0;
    logic [CLUSTERS*5-1:0] score_rd_rsp_head = '0;
    logic [CLUSTERS*7-1:0] score_rd_rsp_row = '0;
    logic [CLUSTERS*7-1:0] score_rd_rsp_key = '0;
    logic [CLUSTERS*2-1:0] score_rd_rsp_slot = '0;
    logic [CLUSTERS*2-1:0] score_rd_rsp_mode = '0;
    logic [CLUSTERS*16-1:0] score_rd_rsp_data = '0;
    logic [CLUSTERS-1:0] b_row_ready = '1, b_score_ready = '1;
    logic [CLUSTERS-1:0] final_release_valid = '0;
    logic [CLUSTERS*16-1:0] final_release_epoch = '0;
    logic [CLUSTERS*3-1:0] final_release_group = '0;
    logic [CLUSTERS*5-1:0] final_release_head = '0;
    logic [CLUSTERS*7-1:0] final_release_row = '0;
    logic [CLUSTERS*2-1:0] final_release_slot = '0;
    logic [CLUSTERS*2-1:0] final_release_mode = '0;
    logic [CLUSTERS-1:0] row_abort_ready = '1;

    logic [CLUSTERS*64-1:0] cluster_jobs_accepted;
    logic [CLUSTERS*64-1:0] cluster_assignment_errors;
    logic [CLUSTERS-1:0] protocol_error_sticky;
    integer g, c, expected;

    cats_r4_compute_frontend #(.CLUSTERS(CLUSTERS)) dut (
        .clk, .rst_n, .clear, .counter_clear,
        .txn_start_valid, .txn_start_ready, .txn_epoch, .txn_numeric_mode,
        .job_valid, .job_ready, .job_epoch, .job_group,
        .job_global_q_head, .job_row_window,
        .q_slab_need_valid, .q_slab_need_ready,
        .q_slab_need_epoch, .q_slab_need_group,
        .q_slab_need_global_q_head(q_slab_need_head),
        .q_slab_need_row_window(q_slab_need_window),
        .q_slab_ready_valid, .q_slab_ready_ready(),
        .q_slab_ready_epoch, .q_slab_ready_group,
        .q_slab_ready_global_q_head(q_slab_ready_head),
        .q_slab_ready_row_window(q_slab_ready_window), .q_slab_ready_buffer,
        .q_slab_retire_valid, .q_slab_retire_ready,
        .q_slab_retire_epoch(), .q_slab_retire_group(),
        .q_slab_retire_global_q_head(), .q_slab_retire_row_window(),
        .q_slab_retire_buffer(),
        .q_req_valid(), .q_req_ready, .q_req_context_tag(), .q_req_d(),
        .q_rsp_valid, .q_rsp_context_tag(q_rsp_context), .q_rsp_bf16,
        .k_req_valid(), .k_req_ready, .k_req_context_tag(),
        .k_req_key_block(), .k_req_d(), .k_rsp_valid,
        .k_rsp_context_tag(k_rsp_context), .k_rsp_vec,
        .store_wr_valid(), .store_wr_ready, .store_wr_slot_id(),
        .store_wr_key_base(), .store_wr_lane_valid(), .store_wr_score_bf16(),
        .score_rd_req_valid(), .score_rd_req_ready,
        .score_rd_req_epoch(), .score_rd_req_group(),
        .score_rd_req_global_q_head(), .score_rd_req_row(), .score_rd_req_key(),
        .score_rd_req_slot_id(), .score_rd_req_numeric_mode(),
        .score_rd_rsp_valid, .score_rd_rsp_ready(), .score_rd_rsp_epoch,
        .score_rd_rsp_group, .score_rd_rsp_global_q_head(score_rd_rsp_head),
        .score_rd_rsp_row, .score_rd_rsp_key, .score_rd_rsp_slot_id(score_rd_rsp_slot),
        .score_rd_rsp_numeric_mode(score_rd_rsp_mode), .score_rd_rsp_bf16(score_rd_rsp_data),
        .b_row_valid(), .b_row_ready, .b_row_epoch(), .b_row_group(),
        .b_row_global_q_head(), .b_row_index(), .b_row_slot_id(),
        .b_row_numeric_mode(), .b_row_max_bf16(), .b_score_valid(),
        .b_score_ready, .b_score_epoch(), .b_score_group(),
        .b_score_global_q_head(), .b_score_row(), .b_score_key(),
        .b_score_slot_id(), .b_score_numeric_mode(), .b_score_bf16(),
        .b_score_last(), .final_release_valid, .final_release_ready(),
        .final_release_epoch, .final_release_group,
        .final_release_global_q_head(final_release_head), .final_release_row,
        .final_release_slot_id(final_release_slot),
        .final_release_numeric_mode(final_release_mode), .row_abort_valid(),
        .row_abort_ready, .row_abort_epoch(), .row_abort_group(),
        .row_abort_global_q_head(), .row_abort_row(), .row_abort_error_key(),
        .row_abort_slot_id(), .row_abort_numeric_mode(), .row_abort_error_code(),
        .slot_owner(), .cluster_jobs_accepted, .cluster_engine_jobs_started(),
        .cluster_engine_jobs_completed(), .cluster_rows_completed(),
        .cluster_scores_transferred(), .cluster_rows_transferred(),
        .cluster_valid_macs(), .cluster_mac_steps_issued(),
        .cluster_mac_steps_completed(), .cluster_assignment_errors,
        .protocol_error_sticky
    );

    task automatic tick;
        @(posedge clk); #1;
    endtask

    task automatic reset_frontend;
        begin
            rst_n = 0; repeat (2) tick(); rst_n = 1; tick();
        end
    endtask

    initial begin
        reset_frontend();
        // Every legal group must reach exactly group % CLUSTERS.
        for (g = 0; g < 8; g = g + 1) begin
            job_group = g[2:0];
            job_global_q_head = {g[2:0], 2'b00};
            job_row_window = g[2:0];
            @(negedge clk); job_valid = 1;
            while (!job_ready) tick();
            tick();
            expected = g % CLUSTERS;
            for (c = 0; c < CLUSTERS; c = c + 1)
                if (q_slab_need_valid[c] !== (c == expected))
                    $fatal(1, "group %0d routed to wrong cluster c=%0d expected=%0d",
                           g, c, expected);
            if (q_slab_need_group[expected*3 +: 3] !== g[2:0])
                $fatal(1, "group %0d q_slab token mismatch", g);
            @(negedge clk); job_valid = 0;
            // Consume the need, then clear the in-flight client before the
            // next independent routing sample.
            tick();
            reset_frontend();
        end

        // Head/group mismatch is rejected before a child FIFO sees it.
        job_group = 3'd3; job_global_q_head = 5'd0;
        @(negedge clk); job_valid = 1; #1;
        if (job_ready) $fatal(1, "invalid group/head job was accepted");
        tick(); @(negedge clk); job_valid = 0; tick();
        if (cluster_assignment_errors[63:0] !== 64'd1)
            $fatal(1, "invalid assignment was not counted once: %0d",
                   cluster_assignment_errors[63:0]);

        // Unsupported IF_V3 mode is consumed as a transaction error and
        // blocks score admission until reset/clear; it must not silently
        // fall back to Compatibility or Accuracy.
        txn_numeric_mode = 2;
        @(negedge clk); txn_start_valid = 1;
        if (!txn_start_ready)
            $fatal(1, "mode-reject transaction did not handshake");
        tick(); @(negedge clk); txn_start_valid = 0; txn_numeric_mode = 1;
        if (protocol_error_sticky !== {CLUSTERS{1'b1}})
            $fatal(1, "unsupported numeric mode was not made sticky");

        $display("PASS: CATS-R4 compute frontend static group routing CLUSTERS=%0d",
                 CLUSTERS);
        $finish;
    end

    initial begin
        repeat (200) tick();
        $fatal(1, "routing test timeout CLUSTERS=%0d", CLUSTERS);
    end
endmodule
