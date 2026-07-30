`timescale 1ns/1ps

// The production interface has 8 Groups encoded by all values of group_id[2:0],
// so it has no invalid binary code.  Parameterizing the same guard to 7 Groups
// makes 3'b111 invalid and proves that an out-of-range launch is rejected.
module tb_bc_invalid_group_id;
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n;
    logic group_start;
    logic [2:0] group_id;
    logic group_start_ready;
    logic [2:0] active_group_id;
    logic busy;
    logic invalid_group_id_error;
    logic start_while_busy_error;
    logic protocol_error;
    logic qk_vec_ready;
    logic v_req_valid;
    logic pv_vec_valid;

    qk_softmax_pv_pipeline_top #(
        .QK_TILE(4),
        .PV_TILE(2),
        .SEQ_LEN(8),
        .HEAD_DIM(8),
        .Q_HEADS(4),
        .GQA_GROUPS(7),
        .SCALE_FP32(32'h3EB504F3)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .group_start(group_start),
        .group_id(group_id),
        .group_start_ready(group_start_ready),
        .active_group_id(active_group_id),
        .causal_en(1'b1),
        .qk_vec_ready(qk_vec_ready),
        .qk_vec_valid(1'b0),
        .q_vec_bf16('0),
        .k_vec_bf16('0),
        .req_head(), .req_group_id(), .req_global_q_head(), .req_kv_head(),
        .req_row_base(), .req_col_base(), .req_dim(),
        .v_req_valid(v_req_valid),
        .v_req_ready(1'b0),
        .v_req_kv_head(), .v_req_reduce_index(), .v_req_feature_base(),
        .v_req_addr(),
        .v_rsp_valid(1'b0),
        .v_rsp_ready(),
        .v_rsp_data('0),
        .p_vec_bf16(), .v_vec_bf16(),
        .pv_vec_valid(pv_vec_valid),
        .pv_vec_ready(1'b1),
        .pv_vec_first(), .pv_vec_last(), .pv_vec_group_last(),
        .pv_vec_group_id(), .pv_vec_head(), .pv_vec_global_q_head(),
        .pv_vec_row_base(), .pv_vec_feature_base(), .pv_vec_reduce_index(),
        .mon_prob_valid(), .mon_prob_ready(), .mon_prob_data(),
        .mon_prob_group_id(), .mon_prob_head(), .mon_prob_row(), .mon_prob_col(),
        .mon_prob_first(), .mon_prob_last(), .mon_prob_group_last(),
        .qk_busy(), .qk_done(), .b_frontend_busy(), .c_backend_busy(),
        .busy(busy), .prob_input_done(), .done(),
        .start_while_busy_error(start_while_busy_error),
        .invalid_group_id_error(invalid_group_id_error),
        .adapter_protocol_error(), .adapter_global_last_error(),
        .softmax_row_error(), .softmax_metadata_error(),
        .c_protocol_error(), .protocol_error(protocol_error)
    );

    initial begin
        rst_n = 1'b0;
        group_start = 1'b0;
        group_id = '0;
        repeat (5) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        repeat (2) @(posedge clk);

        if (!group_start_ready)
            $fatal(1, "Pipeline not ready before invalid-ID test");
        @(negedge clk);
        group_id = 3'b111;
        group_start = 1'b1;
        @(negedge clk);
        group_start = 1'b0;
        repeat (2) @(posedge clk);

        if (!invalid_group_id_error || !protocol_error)
            $fatal(1, "Out-of-range Group ID was not reported");
        if (start_while_busy_error || busy || v_req_valid || pv_vec_valid ||
            qk_vec_ready || (active_group_id != 0))
            $fatal(1, "Invalid Group launch changed pipeline state");
        if (!group_start_ready)
            $fatal(1, "Invalid Group launch consumed readiness");

        @(negedge clk) rst_n = 1'b0;
        repeat (2) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        repeat (2) @(posedge clk);
        if (invalid_group_id_error || protocol_error || busy)
            $fatal(1, "Reset did not clear invalid-Group error");

        $display("PASS: illegal group_id is rejected without starting B or C");
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "Timeout in invalid Group ID test");
    end
endmodule


// Resets the complete B+C pipeline during QK, C-backend activity and a stalled
// PV output.  It also proves that a repeated group_start while busy is flagged
// without replacing the active Group.
module tb_bc_reset_and_busy;
    localparam int QK_TILE = 4;
    localparam int PV_TILE = 2;
    localparam int SEQ_LEN = 8;
    localparam int HEAD_DIM = 8;
    localparam int Q_HEADS = 4;
    localparam int GQA_GROUPS = 8;
    localparam int TOTAL_PROBS = Q_HEADS*SEQ_LEN*SEQ_LEN;
    localparam int TOTAL_VECS = Q_HEADS*(SEQ_LEN/PV_TILE)*
                                (HEAD_DIM/PV_TILE)*SEQ_LEN;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n;
    logic group_start;
    logic [2:0] group_id;
    logic group_start_ready;
    logic [2:0] active_group_id;
    logic qk_vec_ready;
    logic qk_vec_valid;
    logic [63:0] q_vec_bf16;
    logic [63:0] k_vec_bf16;
    logic [1:0] req_head;
    logic [2:0] req_group_id;
    logic [4:0] req_global_q_head;
    logic [2:0] req_kv_head;
    logic [2:0] req_row_base;
    logic [2:0] req_col_base;
    logic [2:0] req_dim;

    logic v_req_valid;
    logic v_req_ready;
    logic [2:0] v_req_kv_head;
    logic [2:0] v_req_reduce_index;
    logic [2:0] v_req_feature_base;
    logic [8:0] v_req_addr;
    logic v_rsp_valid;
    logic v_rsp_ready;
    logic [31:0] v_rsp_data;

    logic v_load_valid;
    logic v_load_ready;
    logic [8:0] v_load_addr;
    logic [31:0] v_load_data;
    logic v_cache_error;

    logic [31:0] p_vec_bf16;
    logic [31:0] v_vec_bf16;
    logic pv_vec_valid;
    logic pv_vec_ready;
    logic pv_vec_first;
    logic pv_vec_last;
    logic pv_vec_group_last;
    logic [2:0] pv_vec_group_id;
    logic [1:0] pv_vec_head;
    logic [4:0] pv_vec_global_q_head;
    logic [2:0] pv_vec_row_base;
    logic [2:0] pv_vec_feature_base;
    logic [2:0] pv_vec_reduce_index;

    logic mon_prob_valid;
    logic mon_prob_ready;
    logic [15:0] mon_prob_data;
    logic [2:0] mon_prob_group_id;
    logic [1:0] mon_prob_head;
    logic [2:0] mon_prob_row;
    logic [2:0] mon_prob_col;
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

    integer lane;
    integer final_prob_count;
    integer final_pv_count;
    integer final_qk_done_count;
    integer final_prob_done_count;
    integer final_done_count;
    logic count_final;

    qk_softmax_pv_pipeline_top #(
        .QK_TILE(QK_TILE), .PV_TILE(PV_TILE),
        .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS), .GQA_GROUPS(GQA_GROUPS),
        .SCALE_FP32(32'h3EB504F3)
    ) dut (
        .clk, .rst_n, .group_start, .group_id,
        .group_start_ready, .active_group_id, .causal_en(1'b1),
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

    bf16_v_cache #(
        .NUM_KV_HEADS(GQA_GROUPS),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .LANES(PV_TILE),
        .ADDR_W(9)
    ) v_cache (
        .clk, .rst_n,
        .load_valid(v_load_valid), .load_ready(v_load_ready),
        .load_addr(v_load_addr), .load_data(v_load_data),
        .req_valid(v_req_valid), .req_ready(v_req_ready),
        .req_addr(v_req_addr), .rsp_valid(v_rsp_valid),
        .rsp_ready(v_rsp_ready), .rsp_data(v_rsp_data),
        .protocol_error(v_cache_error)
    );

    function automatic [15:0] v_word(
        input integer group_index,
        input integer reduce_index,
        input integer feature_index
    );
        begin
            v_word = 16'h4000 + (group_index << 8) +
                     (reduce_index << 4) + feature_index;
        end
    endfunction

    always_comb begin
        qk_vec_valid = busy;
        q_vec_bf16 = '0;
        k_vec_bf16 = '0;
        for (lane = 0; lane < QK_TILE; lane = lane + 1) begin
            q_vec_bf16[lane*16 +: 16] = 16'h3F80;
            k_vec_bf16[lane*16 +: 16] = 16'h3F80;
        end
    end

    task automatic load_v_cache;
        integer group_index;
        integer reduce_index;
        integer feature_base;
        begin
            @(negedge clk);
            v_load_valid = 1'b1;
            for (group_index = 0; group_index < GQA_GROUPS;
                 group_index = group_index + 1)
                for (reduce_index = 0; reduce_index < SEQ_LEN;
                     reduce_index = reduce_index + 1)
                    for (feature_base = 0; feature_base < HEAD_DIM;
                         feature_base = feature_base + PV_TILE) begin
                        while (!v_load_ready)
                            @(negedge clk);
                        v_load_addr = ((group_index*SEQ_LEN + reduce_index) *
                                       HEAD_DIM) + feature_base;
                        v_load_data[15:0] =
                            v_word(group_index, reduce_index, feature_base);
                        v_load_data[31:16] =
                            v_word(group_index, reduce_index, feature_base+1);
                        @(negedge clk);
                    end
            v_load_valid = 1'b0;
            v_load_addr = '0;
            v_load_data = '0;
        end
    endtask

    task automatic launch_group(input logic [2:0] selected_group);
        begin
            wait (group_start_ready);
            @(negedge clk);
            group_id = selected_group;
            group_start = 1'b1;
            @(negedge clk);
            group_start = 1'b0;
        end
    endtask

    task automatic pulse_reset;
        begin
            @(negedge clk) rst_n = 1'b0;
            repeat (3) @(posedge clk);
            @(negedge clk) rst_n = 1'b1;
            repeat (3) @(posedge clk);
            if (busy || qk_busy || b_frontend_busy || c_backend_busy ||
                mon_prob_valid || pv_vec_valid || v_rsp_valid ||
                protocol_error || v_cache_error)
                $fatal(1, "B+C pipeline not clean after synchronous reset");
            if (!group_start_ready)
                $fatal(1, "B+C pipeline not ready after reset");
        end
    endtask

    always @(posedge clk) begin
        integer check_lane;
        if (!rst_n) begin
            final_prob_count = 0;
            final_pv_count = 0;
            final_qk_done_count = 0;
            final_prob_done_count = 0;
            final_done_count = 0;
        end else if (count_final) begin
            if (adapter_protocol_error || adapter_global_last_error ||
                softmax_row_error || softmax_metadata_error ||
                c_protocol_error || invalid_group_id_error ||
                start_while_busy_error || v_cache_error)
                $fatal(1, "Unexpected error in final reset-recovery run");
            if (mon_prob_valid && mon_prob_ready) begin
                if (mon_prob_group_id != 3'd7)
                    $fatal(1, "Final run probability Group mismatch");
                final_prob_count = final_prob_count + 1;
            end
            if (pv_vec_valid && pv_vec_ready) begin
                for (check_lane = 0; check_lane < PV_TILE;
                     check_lane = check_lane + 1)
                    if (v_vec_bf16[check_lane*16 +: 16] !==
                        v_word(7, pv_vec_reduce_index,
                               pv_vec_feature_base+check_lane))
                        $fatal(1, "Final run V-cache data mismatch");
                final_pv_count = final_pv_count + 1;
            end
            if (qk_done)
                final_qk_done_count = final_qk_done_count + 1;
            if (prob_input_done)
                final_prob_done_count = final_prob_done_count + 1;
            if (done)
                final_done_count = final_done_count + 1;
        end
    end

    initial begin
        rst_n = 1'b0;
        group_start = 1'b0;
        group_id = '0;
        pv_vec_ready = 1'b1;
        v_load_valid = 1'b0;
        v_load_addr = '0;
        v_load_data = '0;
        count_final = 1'b0;

        repeat (8) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;
        load_v_cache();

        // Busy launch must be rejected without replacing Group 1.
        launch_group(3'd1);
        wait (qk_busy);
        repeat (5) @(posedge clk);
        @(negedge clk);
        group_id = 3'd6;
        group_start = 1'b1;
        @(negedge clk);
        group_start = 1'b0;
        repeat (2) @(posedge clk);
        if (!start_while_busy_error || !protocol_error ||
            (active_group_id != 3'd1))
            $fatal(1, "Busy group_start guard failed");
        wait (done);
        @(posedge clk);
        @(negedge clk);
        if (c_protocol_error || adapter_protocol_error ||
            adapter_global_last_error || (active_group_id != 3'd1))
            $fatal(1, "Busy relaunch corrupted the accepted Group");
        $display("PASS: busy group_start is flagged and original Group completes");
        pulse_reset();

        // Reset while QK is active.
        launch_group(3'd2);
        wait (qk_busy);
        repeat (8) @(posedge clk);
        pulse_reset();
        $display("PASS: B+C reset recovery during QK activity");

        // Reset while the C P-buffer/loader is active.
        launch_group(3'd3);
        wait (mon_prob_valid && mon_prob_ready);
        if (!c_backend_busy)
            $fatal(1, "C backend was not active after accepting a probability");
        repeat (3) @(posedge clk);
        pulse_reset();
        $display("PASS: B+C reset recovery during C backend activity");

        // Reset while a PV vector is held by downstream backpressure.
        pv_vec_ready = 1'b0;
        launch_group(3'd4);
        wait (pv_vec_valid);
        repeat (4) @(posedge clk);
        if (!pv_vec_valid)
            $fatal(1, "PV vector did not remain valid while stalled");
        pulse_reset();
        pv_vec_ready = 1'b1;
        $display("PASS: B+C reset recovery from stalled PV output");

        // A clean full Group after all reset points proves restartability.
        count_final = 1'b1;
        launch_group(3'd7);
        wait (done);
        @(posedge clk);
        @(negedge clk);
        count_final = 1'b0;
        if (final_prob_count != TOTAL_PROBS ||
            final_pv_count != TOTAL_VECS ||
            final_qk_done_count != 1 ||
            final_prob_done_count != 1 || final_done_count != 1)
            $fatal(1, "Final recovery counts prob=%0d pv=%0d qk=%0d p=%0d done=%0d",
                   final_prob_count, final_pv_count, final_qk_done_count,
                   final_prob_done_count, final_done_count);
        if (busy || protocol_error || v_cache_error)
            $fatal(1, "Final reset-recovery run did not return cleanly to idle");

        $display("PASS: B+C reset/busy regression and final Group 7 recovery");
        $finish;
    end

    initial begin
        #2_000_000_000;
        $fatal(1, "Timeout in B+C reset/busy test");
    end
endmodule
