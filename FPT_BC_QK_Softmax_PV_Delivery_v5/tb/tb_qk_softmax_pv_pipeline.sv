`timescale 1ns/1ps

// Reusable self-checking B+C integration test core.  It does not require a
// real PV MAC: the sink checks every P/V vector that would enter the PV array.
module bc_pipeline_test_core #(
    parameter int SEQ_LEN = 8,
    parameter int HEAD_DIM = 8,
    parameter logic [31:0] SCALE_FP32 = 32'h3EB504F3,
    parameter bit RUN_SECOND_GROUP = 1'b1,
    parameter logic [2:0] FIRST_GROUP = 3'd0,
    parameter logic [2:0] SECOND_GROUP = 3'd7,
    parameter longint TIMEOUT_NS = 64'd200_000_000,
    parameter int PROGRESS_INTERVAL = 128,
    parameter EXP_LUT_FILE = "exp_lut_q15.mem"
);
    localparam int QK_TILE = 4;
    localparam int PV_TILE = 2;
    localparam int Q_HEADS = 4;
    localparam int GQA_GROUPS = 8;
    localparam int HEAD_W = 2;
    localparam int GROUP_W = 3;
    localparam int GLOBAL_Q_HEAD_W = 5;
    localparam int POS_W = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN);
    localparam int DIM_W = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM);
    localparam int V_ADDR_W = $clog2(GQA_GROUPS*SEQ_LEN*HEAD_DIM);
    localparam int TOTAL_PROBS = Q_HEADS*SEQ_LEN*SEQ_LEN;
    localparam int TOTAL_VECS = Q_HEADS*(SEQ_LEN/PV_TILE)*
                                (HEAD_DIM/PV_TILE)*SEQ_LEN;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n;
    logic group_start;
    logic [GROUP_W-1:0] group_id;
    logic group_start_ready;
    logic [GROUP_W-1:0] active_group_id;
    logic causal_en;

    logic qk_vec_ready;
    logic qk_vec_valid;
    logic [QK_TILE*16-1:0] q_vec_bf16;
    logic [QK_TILE*16-1:0] k_vec_bf16;
    logic [HEAD_W-1:0] req_head;
    logic [GROUP_W-1:0] req_group_id;
    logic [GLOBAL_Q_HEAD_W-1:0] req_global_q_head;
    logic [GROUP_W-1:0] req_kv_head;
    logic [POS_W-1:0] req_row_base;
    logic [POS_W-1:0] req_col_base;
    logic [DIM_W-1:0] req_dim;

    logic v_req_valid;
    logic v_req_ready;
    logic [GROUP_W-1:0] v_req_kv_head;
    logic [POS_W-1:0] v_req_reduce_index;
    logic [DIM_W-1:0] v_req_feature_base;
    logic [V_ADDR_W-1:0] v_req_addr;
    logic v_rsp_valid;
    logic v_rsp_ready;
    logic [PV_TILE*16-1:0] v_rsp_data;

    logic [PV_TILE*16-1:0] p_vec_bf16;
    logic [PV_TILE*16-1:0] v_vec_bf16;
    logic pv_vec_valid;
    logic pv_vec_ready;
    logic pv_vec_first;
    logic pv_vec_last;
    logic pv_vec_group_last;
    logic [GROUP_W-1:0] pv_vec_group_id;
    logic [HEAD_W-1:0] pv_vec_head;
    logic [GLOBAL_Q_HEAD_W-1:0] pv_vec_global_q_head;
    logic [POS_W-1:0] pv_vec_row_base;
    logic [DIM_W-1:0] pv_vec_feature_base;
    logic [POS_W-1:0] pv_vec_reduce_index;

    logic mon_prob_valid;
    logic mon_prob_ready;
    logic [15:0] mon_prob_data;
    logic [GROUP_W-1:0] mon_prob_group_id;
    logic [HEAD_W-1:0] mon_prob_head;
    logic [POS_W-1:0] mon_prob_row;
    logic [POS_W-1:0] mon_prob_col;
    logic mon_prob_first;
    logic mon_prob_last;
    logic mon_prob_group_last;

    logic qk_busy;
    logic qk_done;
    logic b_frontend_busy;
    logic c_backend_busy;
    logic busy;
    logic prob_input_done;
    logic done;
    logic start_while_busy_error;
    logic invalid_group_id_error;
    logic adapter_protocol_error;
    logic adapter_global_last_error;
    logic softmax_row_error;
    logic softmax_metadata_error;
    logic c_protocol_error;
    logic protocol_error;

    logic [15:0] captured_p [0:TOTAL_PROBS-1];
    integer prob_count;
    integer pv_count;
    integer v_req_count;
    integer prob_done_count;
    integer qk_done_count;
    integer c_done_count;
    integer ready_cycle;
    integer q_lane;
    integer rsp_lane;
    integer pv_lane;

    logic v_pending;
    logic [GROUP_W-1:0] pending_kv;
    logic [POS_W-1:0] pending_reduce;
    logic [DIM_W-1:0] pending_feature;

    logic pv_hold_active;
    logic [PV_TILE*16-1:0] pv_hold_p;
    logic [PV_TILE*16-1:0] pv_hold_v;
    logic pv_hold_first;
    logic pv_hold_last;
    logic pv_hold_group_last;
    logic [GROUP_W-1:0] pv_hold_group;
    logic [HEAD_W-1:0] pv_hold_head;
    logic [GLOBAL_Q_HEAD_W-1:0] pv_hold_global_head;
    logic [POS_W-1:0] pv_hold_row;
    logic [DIM_W-1:0] pv_hold_feature;
    logic [POS_W-1:0] pv_hold_reduce;

    logic req_hold_active;
    logic [GROUP_W-1:0] req_hold_kv;
    logic [POS_W-1:0] req_hold_reduce;
    logic [DIM_W-1:0] req_hold_feature;
    logic [V_ADDR_W-1:0] req_hold_addr;

    qk_softmax_pv_pipeline_top #(
        .QK_TILE(QK_TILE),
        .PV_TILE(PV_TILE),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),
        .SCALE_FP32(SCALE_FP32),
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) dut (
        .clk, .rst_n,
        .group_start, .group_id, .group_start_ready, .active_group_id,
        .causal_en,
        .qk_vec_ready, .qk_vec_valid, .q_vec_bf16, .k_vec_bf16,
        .req_head, .req_group_id, .req_global_q_head, .req_kv_head,
        .req_row_base, .req_col_base, .req_dim,
        .v_req_valid, .v_req_ready, .v_req_kv_head,
        .v_req_reduce_index, .v_req_feature_base, .v_req_addr,
        .v_rsp_valid, .v_rsp_ready, .v_rsp_data,
        .p_vec_bf16, .v_vec_bf16, .pv_vec_valid, .pv_vec_ready,
        .pv_vec_first, .pv_vec_last, .pv_vec_group_last,
        .pv_vec_group_id, .pv_vec_head, .pv_vec_global_q_head,
        .pv_vec_row_base, .pv_vec_feature_base, .pv_vec_reduce_index,
        .mon_prob_valid, .mon_prob_ready, .mon_prob_data,
        .mon_prob_group_id, .mon_prob_head, .mon_prob_row, .mon_prob_col,
        .mon_prob_first, .mon_prob_last, .mon_prob_group_last,
        .qk_busy, .qk_done, .b_frontend_busy, .c_backend_busy, .busy,
        .prob_input_done, .done,
        .start_while_busy_error, .invalid_group_id_error,
        .adapter_protocol_error, .adapter_global_last_error,
        .softmax_row_error, .softmax_metadata_error,
        .c_protocol_error, .protocol_error
    );

    function automatic [15:0] v_word(
        input integer g,
        input integer reduce_index,
        input integer feature_index
    );
        begin
            v_word = 16'h4000 + (g << 8) +
                     (reduce_index << 4) + feature_index;
        end
    endfunction

    // Constant Q and K values make every unmasked score in a row equal.  The
    // B pipeline still performs the complete real QK computation and Softmax.
    always_comb begin
        qk_vec_valid = busy;
        q_vec_bf16 = '0;
        k_vec_bf16 = '0;
        for (q_lane = 0; q_lane < QK_TILE; q_lane = q_lane + 1) begin
            q_vec_bf16[q_lane*16 +: 16] = 16'h3F80; // BF16 1.0
            k_vec_bf16[q_lane*16 +: 16] = 16'h3F80; // BF16 1.0
        end
    end

    // Deterministic stalls exercise V-request and PV-output stability.
    assign v_req_ready = rst_n && !v_pending && !v_rsp_valid &&
                         ((ready_cycle % 5) != 1);
    assign pv_vec_ready = rst_n && ((ready_cycle % 7) != 3) &&
                          ((ready_cycle % 11) != 8);

    always_ff @(posedge clk) begin
        if (!rst_n)
            ready_cycle <= 0;
        else
            ready_cycle <= ready_cycle + 1;
    end

    // One-outstanding registered V-memory responder.
    always_ff @(posedge clk) begin
        if (!rst_n || (group_start && group_start_ready)) begin
            v_pending       <= 1'b0;
            pending_kv      <= '0;
            pending_reduce  <= '0;
            pending_feature <= '0;
            v_rsp_valid     <= 1'b0;
            v_rsp_data      <= '0;
        end else begin
            if (v_rsp_valid && v_rsp_ready)
                v_rsp_valid <= 1'b0;

            if (v_req_valid && v_req_ready) begin
                v_pending       <= 1'b1;
                pending_kv      <= v_req_kv_head;
                pending_reduce  <= v_req_reduce_index;
                pending_feature <= v_req_feature_base;
            end

            if (v_pending && !v_rsp_valid) begin
                for (rsp_lane = 0; rsp_lane < PV_TILE;
                     rsp_lane = rsp_lane + 1)
                    v_rsp_data[rsp_lane*16 +: 16] <=
                        v_word(pending_kv, pending_reduce,
                               pending_feature + rsp_lane);
                v_rsp_valid <= 1'b1;
                v_pending   <= 1'b0;
            end
        end
    end

    // Capture the exact B probability stream accepted by C.  Later P-vector
    // comparisons therefore prove ordering, buffering and replay losslessly.
    always @(posedge clk) begin
        integer expected_head;
        integer expected_row;
        integer expected_col;
        integer flat_index;

        if (!rst_n || (group_start && group_start_ready)) begin
            prob_count      = 0;
            prob_done_count = 0;
            qk_done_count   = 0;
        end else begin
            if (qk_done)
                qk_done_count = qk_done_count + 1;
            if (prob_input_done)
                prob_done_count = prob_done_count + 1;

            if (protocol_error)
                $fatal(1, "B+C protocol_error asserted");

            if (qk_vec_valid && qk_vec_ready) begin
                if ((req_group_id !== active_group_id) ||
                    (req_kv_head !== active_group_id) ||
                    (req_global_q_head !==
                     ((active_group_id*Q_HEADS) + req_head)))
                    $fatal(1, "Q/K global-head mapping mismatch");
            end

            if (mon_prob_valid && mon_prob_ready) begin
                expected_head = prob_count / (SEQ_LEN*SEQ_LEN);
                expected_row  = (prob_count / SEQ_LEN) % SEQ_LEN;
                expected_col  = prob_count % SEQ_LEN;
                flat_index    = expected_head*SEQ_LEN*SEQ_LEN +
                                expected_row*SEQ_LEN + expected_col;

                if ((mon_prob_group_id !== active_group_id) ||
                    ($unsigned(mon_prob_head) != expected_head) ||
                    ($unsigned(mon_prob_row) != expected_row) ||
                    ($unsigned(mon_prob_col) != expected_col) ||
                    (mon_prob_first != (expected_col == 0)) ||
                    (mon_prob_last != (expected_col == SEQ_LEN-1)) ||
                    (mon_prob_group_last !=
                     ((expected_head == Q_HEADS-1) &&
                      (expected_row == SEQ_LEN-1) &&
                      (expected_col == SEQ_LEN-1))))
                    $fatal(1, "B->C probability metadata mismatch at %0d",
                           prob_count);

                if ((expected_col > expected_row) &&
                    (mon_prob_data !== 16'h0000))
                    $fatal(1, "Causal-masked probability is nonzero");

                captured_p[flat_index] = mon_prob_data;
                prob_count = prob_count + 1;
            end
        end
    end

    // Check every global V request, including Group 7's nonzero KV base.
    always @(posedge clk) begin
        integer expected_head;
        integer expected_row_tile;
        integer expected_feature_tile;
        integer expected_reduce;
        integer rem;
        integer expected_addr;
        integer vecs_per_row_tile;
        integer vecs_per_head;

        if (!rst_n || (group_start && group_start_ready)) begin
            v_req_count     = 0;
            req_hold_active = 1'b0;
        end else begin
            if (req_hold_active) begin
                if (!v_req_valid ||
                    v_req_kv_head !== req_hold_kv ||
                    v_req_reduce_index !== req_hold_reduce ||
                    v_req_feature_base !== req_hold_feature ||
                    v_req_addr !== req_hold_addr)
                    $fatal(1, "V request changed while stalled");
            end

            if (v_req_valid && !v_req_ready) begin
                if (!req_hold_active) begin
                    req_hold_kv      = v_req_kv_head;
                    req_hold_reduce  = v_req_reduce_index;
                    req_hold_feature = v_req_feature_base;
                    req_hold_addr    = v_req_addr;
                end
                req_hold_active = 1'b1;
            end else begin
                req_hold_active = 1'b0;
            end

            if (v_req_valid && v_req_ready) begin
                vecs_per_row_tile = (HEAD_DIM/PV_TILE)*SEQ_LEN;
                vecs_per_head = (SEQ_LEN/PV_TILE)*vecs_per_row_tile;
                expected_head = v_req_count / vecs_per_head;
                rem = v_req_count % vecs_per_head;
                expected_row_tile = rem / vecs_per_row_tile;
                rem = rem % vecs_per_row_tile;
                expected_feature_tile = rem / SEQ_LEN;
                expected_reduce = rem % SEQ_LEN;
                expected_addr = ((active_group_id*SEQ_LEN + expected_reduce) *
                                 HEAD_DIM) + expected_feature_tile*PV_TILE;

                if ((v_req_kv_head !== active_group_id) ||
                    ($unsigned(v_req_reduce_index) != expected_reduce) ||
                    ($unsigned(v_req_feature_base) !=
                     expected_feature_tile*PV_TILE) ||
                    ($unsigned(v_req_addr) != expected_addr))
                    $fatal(1, "V request mismatch at %0d", v_req_count);

                // These variables are intentionally calculated to validate the
                // complete loader schedule, even though row/head do not appear
                // on the external V request interface.
                if ((expected_head >= Q_HEADS) ||
                    (expected_row_tile >= (SEQ_LEN/PV_TILE)))
                    $fatal(1, "V request schedule overflow");

                v_req_count = v_req_count + 1;
            end
        end
    end

    // Check every P replay vector, returned V vector and all PV metadata.
    always @(posedge clk) begin
        integer expected_head;
        integer expected_row_tile;
        integer expected_feature_tile;
        integer expected_reduce;
        integer expected_row_base;
        integer expected_feature_base;
        integer flat_index;
        integer rem;
        integer vecs_per_row_tile;
        integer vecs_per_head;

        if (!rst_n || (group_start && group_start_ready)) begin
            pv_count       = 0;
            c_done_count   = 0;
            pv_hold_active = 1'b0;
        end else begin
            if (pv_hold_active) begin
                if (!pv_vec_valid ||
                    p_vec_bf16 !== pv_hold_p ||
                    v_vec_bf16 !== pv_hold_v ||
                    pv_vec_first !== pv_hold_first ||
                    pv_vec_last !== pv_hold_last ||
                    pv_vec_group_last !== pv_hold_group_last ||
                    pv_vec_group_id !== pv_hold_group ||
                    pv_vec_head !== pv_hold_head ||
                    pv_vec_global_q_head !== pv_hold_global_head ||
                    pv_vec_row_base !== pv_hold_row ||
                    pv_vec_feature_base !== pv_hold_feature ||
                    pv_vec_reduce_index !== pv_hold_reduce)
                    $fatal(1, "PV vector changed while stalled");
            end

            if (pv_vec_valid && !pv_vec_ready) begin
                if (!pv_hold_active) begin
                    pv_hold_p           = p_vec_bf16;
                    pv_hold_v           = v_vec_bf16;
                    pv_hold_first       = pv_vec_first;
                    pv_hold_last        = pv_vec_last;
                    pv_hold_group_last  = pv_vec_group_last;
                    pv_hold_group       = pv_vec_group_id;
                    pv_hold_head        = pv_vec_head;
                    pv_hold_global_head = pv_vec_global_q_head;
                    pv_hold_row         = pv_vec_row_base;
                    pv_hold_feature     = pv_vec_feature_base;
                    pv_hold_reduce      = pv_vec_reduce_index;
                end
                pv_hold_active = 1'b1;
            end else begin
                pv_hold_active = 1'b0;
            end

            if (pv_vec_valid && pv_vec_ready) begin
                vecs_per_row_tile = (HEAD_DIM/PV_TILE)*SEQ_LEN;
                vecs_per_head = (SEQ_LEN/PV_TILE)*vecs_per_row_tile;
                expected_head = pv_count / vecs_per_head;
                rem = pv_count % vecs_per_head;
                expected_row_tile = rem / vecs_per_row_tile;
                rem = rem % vecs_per_row_tile;
                expected_feature_tile = rem / SEQ_LEN;
                expected_reduce = rem % SEQ_LEN;
                expected_row_base = expected_row_tile*PV_TILE;
                expected_feature_base = expected_feature_tile*PV_TILE;

                if (($unsigned(pv_vec_group_id) != active_group_id) ||
                    ($unsigned(pv_vec_head) != expected_head) ||
                    ($unsigned(pv_vec_global_q_head) !=
                     (active_group_id*Q_HEADS + expected_head)) ||
                    ($unsigned(pv_vec_row_base) != expected_row_base) ||
                    ($unsigned(pv_vec_feature_base) != expected_feature_base) ||
                    ($unsigned(pv_vec_reduce_index) != expected_reduce) ||
                    (pv_vec_first != (expected_reduce == 0)) ||
                    (pv_vec_last != (expected_reduce == SEQ_LEN-1)) ||
                    (pv_vec_group_last != (pv_count == TOTAL_VECS-1)))
                    $fatal(1, "PV metadata mismatch at %0d", pv_count);

                for (pv_lane = 0; pv_lane < PV_TILE;
                     pv_lane = pv_lane + 1) begin
                    flat_index = expected_head*SEQ_LEN*SEQ_LEN +
                                 (expected_row_base+pv_lane)*SEQ_LEN +
                                 expected_reduce;
                    if (p_vec_bf16[pv_lane*16 +: 16] !==
                        captured_p[flat_index])
                        $fatal(1, "P replay mismatch vec=%0d lane=%0d",
                               pv_count, pv_lane);
                    if (v_vec_bf16[pv_lane*16 +: 16] !==
                        v_word(active_group_id, expected_reduce,
                               expected_feature_base+pv_lane))
                        $fatal(1, "V vector mismatch vec=%0d lane=%0d",
                               pv_count, pv_lane);
                end

                pv_count = pv_count + 1;
                if ((PROGRESS_INTERVAL > 0) &&
                    ((pv_count % PROGRESS_INTERVAL) == 0))
                    $display("PROGRESS group=%0d probs=%0d/%0d pv_vectors=%0d/%0d",
                             active_group_id, prob_count, TOTAL_PROBS,
                             pv_count, TOTAL_VECS);
            end

            if (done)
                c_done_count = c_done_count + 1;
        end
    end

    task automatic run_group(input logic [2:0] selected_group);
        begin
            wait (group_start_ready);
            @(negedge clk);
            group_id    = selected_group;
            group_start = 1'b1;
            @(negedge clk);
            group_start = 1'b0;

            wait (done);
            // done is generated by sequential logic.  Give the posedge-based
            // monitors one complete sampling edge before checking counters.
            @(posedge clk);
            @(negedge clk);

            if (prob_count != TOTAL_PROBS)
                $fatal(1, "Expected %0d probabilities, got %0d",
                       TOTAL_PROBS, prob_count);
            if (pv_count != TOTAL_VECS)
                $fatal(1, "Expected %0d PV vectors, got %0d",
                       TOTAL_VECS, pv_count);
            if (v_req_count != TOTAL_VECS)
                $fatal(1, "Expected %0d V requests, got %0d",
                       TOTAL_VECS, v_req_count);
            if (prob_done_count != 1 || qk_done_count != 1 ||
                c_done_count != 1)
                $fatal(1, "Completion pulse count mismatch qk=%0d prob=%0d c=%0d",
                       qk_done_count, prob_done_count, c_done_count);
            if (busy || protocol_error)
                $fatal(1, "Pipeline not cleanly idle after Group %0d",
                       selected_group);

            $display("PASS: B+C direct integration Group %0d, probabilities=%0d, PV vectors=%0d",
                     selected_group, prob_count, pv_count);
        end
    endtask

    initial begin
        rst_n       = 1'b0;
        group_start = 1'b0;
        group_id    = '0;
        causal_en   = 1'b1;

        repeat (8) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        repeat (4) @(posedge clk);

        run_group(FIRST_GROUP);
        if (RUN_SECOND_GROUP)
            run_group(SECOND_GROUP);

        $display("PASS: complete B+C QK->Softmax->PBuffer->PV-loader integration test");
        $finish;
    end

    initial begin
        #(TIMEOUT_NS);
        $fatal(1, "Timeout in B+C integration test");
    end
endmodule

module tb_qk_softmax_pv_pipeline_small;
    bc_pipeline_test_core #(
        .SEQ_LEN(8),
        .HEAD_DIM(8),
        .SCALE_FP32(32'h3EB504F3), // 1/sqrt(8)
        .RUN_SECOND_GROUP(1'b1),
        .FIRST_GROUP(3'd0),
        .SECOND_GROUP(3'd7),
        .TIMEOUT_NS(64'd200_000_000),
        .PROGRESS_INTERVAL(128)
    ) test();
endmodule

module tb_qk_softmax_pv_pipeline_full_optional;
    bc_pipeline_test_core #(
        .SEQ_LEN(128),
        .HEAD_DIM(128),
        .SCALE_FP32(32'h3DB504F3), // 1/sqrt(128)
        .RUN_SECOND_GROUP(1'b0),
        .FIRST_GROUP(3'd6),
        .TIMEOUT_NS(64'd5_000_000_000),
        .PROGRESS_INTERVAL(131072)
    ) test();
endmodule
