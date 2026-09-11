`timescale 1ns/1ps

module tb_cats_r4_a2_b2_compatibility_integration;
`ifdef CATS_R4_ACCURACY_INTEGRATION
    localparam logic [1:0] TEST_MODE = 2'd1;
`else
    localparam logic [1:0] TEST_MODE = 2'd0;
`endif
    logic clk = 0;
    logic rst_n = 0;
    logic clear = 0;
    logic counter_clear = 0;
    always #5 clk = ~clk;

    logic in_row_valid, in_row_ready;
    logic [15:0] in_row_epoch;
    logic [2:0] in_row_group;
    logic [4:0] in_row_global_q_head;
    logic [6:0] in_row_index;
    logic [1:0] in_row_slot_id, in_row_numeric_mode;
    logic [15:0] in_row_max_bf16;
    logic score_rd_req_valid, score_rd_req_ready;
    logic [15:0] score_rd_req_epoch;
    logic [2:0] score_rd_req_group;
    logic [4:0] score_rd_req_global_q_head;
    logic [6:0] score_rd_req_row, score_rd_req_key;
    logic [1:0] score_rd_req_slot_id, score_rd_req_numeric_mode;
    logic score_rd_rsp_valid, score_rd_rsp_ready;
    logic [15:0] score_rd_rsp_epoch;
    logic [2:0] score_rd_rsp_group;
    logic [4:0] score_rd_rsp_global_q_head;
    logic [6:0] score_rd_rsp_row, score_rd_rsp_key;
    logic [1:0] score_rd_rsp_slot_id, score_rd_rsp_numeric_mode;
    logic [15:0] score_rd_rsp_bf16;

    logic a_row_valid, a_row_ready;
    logic [15:0] a_row_epoch;
    logic [2:0] a_row_group;
    logic [4:0] a_row_global_q_head;
    logic [6:0] a_row_index;
    logic [1:0] a_row_slot_id, a_row_numeric_mode;
    logic [15:0] a_row_max_bf16;
    logic a_score_valid, a_score_ready;
    logic [15:0] a_score_epoch;
    logic [2:0] a_score_group;
    logic [4:0] a_score_global_q_head;
    logic [6:0] a_score_row, a_score_key;
    logic [1:0] a_score_slot_id, a_score_numeric_mode;
    logic [15:0] a_score_bf16;
    logic a_score_last;
    logic abort_valid, abort_ready;
    logic [15:0] abort_epoch;
    logic [2:0] abort_group;
    logic [4:0] abort_global_q_head;
    logic [6:0] abort_row;
    logic [1:0] abort_slot_id, abort_numeric_mode;
    logic [2:0] abort_error_code;
    logic [6:0] abort_error_key;
    logic [63:0] a_row_headers, a_read_requests, a_read_responses;
    logic [63:0] a_scores, a_rows, a_protocol_errors, a_numeric_errors;
    logic a_error_sticky;

    logic weight_wr_valid, weight_wr_ready;
    logic [15:0] weight_wr_epoch;
    logic [2:0] weight_wr_group;
    logic [4:0] weight_wr_global_q_head;
    logic [6:0] weight_wr_row;
    logic [1:0] weight_wr_slot_id, weight_wr_numeric_mode;
    logic [6:0] weight_wr_key;
    logic weight_wr_mask;
    logic [31:0] weight_wr_data;
    logic weight_wr_last;
    logic row_commit_valid, row_commit_ready;
    logic [15:0] row_commit_epoch;
    logic [2:0] row_commit_group;
    logic [4:0] row_commit_global_q_head;
    logic [6:0] row_commit_row;
    logic [1:0] row_commit_slot_id, row_commit_numeric_mode;
    logic [31:0] row_commit_sum_fp32;
    logic [31:0] row_commit_inv_sum_fp32;
    logic row_error_valid, row_error_ready;
    logic [15:0] row_error_epoch;
    logic [2:0] row_error_group;
    logic [4:0] row_error_global_q_head;
    logic [6:0] row_error_row;
    logic [1:0] row_error_slot_id, row_error_numeric_mode;
    logic [3:0] row_error_code;
    logic [6:0] row_error_bad_key;
    logic slot_release_valid, slot_release_ready;
    logic [15:0] slot_release_epoch;
    logic [2:0] slot_release_group;
    logic [4:0] slot_release_global_q_head;
    logic [6:0] slot_release_row;
    logic [1:0] slot_release_slot_id, slot_release_numeric_mode;
    logic [63:0] b_rows_issue, b_rows_result;
    logic [63:0] b_exp_issue, b_exp_result, b_exp_commit;
    logic [63:0] b_sum_issue, b_sum_result, b_sum_commit;
    logic [63:0] b_reciprocal_issue, b_reciprocal_result;
    logic [63:0] b_reciprocal_commit, b_staged_weights;
    logic [63:0] b_weight_writes, b_row_commits, b_releases;
    logic [63:0] b_protocol_errors, b_numeric_errors, b_output_stalls;
    logic b_error_sticky;

    logic pending_response;
    logic [15:0] pending_epoch;
    logic [2:0] pending_group;
    logic [4:0] pending_head;
    logic [6:0] pending_row, pending_key;
    logic [1:0] pending_slot, pending_mode;
    logic [31:0] lfsr = 32'h1a2b3c4d;
    integer observed_writes = 0;
    integer expected_key = 0;
    integer observed_commits = 0;

    cats_r4_qk_ab_handoff u_a_handoff (
        .clk, .rst_n, .clear, .counter_clear,
        .in_row_valid, .in_row_ready, .in_row_epoch, .in_row_group,
        .in_row_global_q_head, .in_row_index, .in_row_slot_id,
        .in_row_numeric_mode, .in_row_max_bf16,
        .score_rd_req_valid, .score_rd_req_ready, .score_rd_req_epoch,
        .score_rd_req_group, .score_rd_req_global_q_head,
        .score_rd_req_row, .score_rd_req_slot_id,
        .score_rd_req_numeric_mode, .score_rd_req_key,
        .score_rd_rsp_valid, .score_rd_rsp_ready, .score_rd_rsp_epoch,
        .score_rd_rsp_group, .score_rd_rsp_global_q_head,
        .score_rd_rsp_row, .score_rd_rsp_slot_id,
        .score_rd_rsp_numeric_mode, .score_rd_rsp_key,
        .score_rd_rsp_bf16,
        .row_valid(a_row_valid), .row_ready(a_row_ready),
        .row_epoch(a_row_epoch), .row_group(a_row_group),
        .row_global_q_head(a_row_global_q_head),
        .row_index(a_row_index), .row_slot_id(a_row_slot_id),
        .row_numeric_mode(a_row_numeric_mode),
        .row_max_bf16(a_row_max_bf16),
        .score_valid(a_score_valid), .score_ready(a_score_ready),
        .score_epoch(a_score_epoch), .score_group(a_score_group),
        .score_global_q_head(a_score_global_q_head),
        .score_row(a_score_row), .score_slot_id(a_score_slot_id),
        .score_numeric_mode(a_score_numeric_mode),
        .score_key(a_score_key), .score_bf16(a_score_bf16),
        .score_last(a_score_last),
        .abort_valid, .abort_ready, .abort_epoch, .abort_group,
        .abort_global_q_head, .abort_row, .abort_slot_id,
        .abort_numeric_mode, .abort_error_code, .abort_error_key,
        .row_headers_transferred(a_row_headers),
        .score_reads_requested(a_read_requests),
        .score_reads_returned(a_read_responses),
        .scores_transferred(a_scores), .rows_transferred(a_rows),
        .protocol_errors(a_protocol_errors),
        .numeric_errors(a_numeric_errors),
        .protocol_error_sticky(a_error_sticky)
    );

`ifdef CATS_R4_SHARED_INTEGRATION
    cats_r4_b2_shared_stager_v3_wrapper #(
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) u_b_softmax (
`elsif CATS_R4_ACCURACY_INTEGRATION
    cats_r4_b2_accuracy_v3_wrapper u_b_softmax (
`else
    cats_r4_b2_compatibility_v3_wrapper #(
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) u_b_softmax (
`endif
        .clk, .rst_n, .clear, .counter_clear,
        .row_valid(a_row_valid), .row_ready(a_row_ready),
        .row_epoch(a_row_epoch), .row_group(a_row_group),
        .row_global_q_head(a_row_global_q_head),
        .row_index(a_row_index), .row_slot_id(a_row_slot_id),
        .row_numeric_mode(a_row_numeric_mode),
        .row_max_bf16(a_row_max_bf16),
        .score_valid(a_score_valid), .score_ready(a_score_ready),
        .score_epoch(a_score_epoch), .score_group(a_score_group),
        .score_global_q_head(a_score_global_q_head),
        .score_row(a_score_row), .score_slot_id(a_score_slot_id),
        .score_numeric_mode(a_score_numeric_mode),
        .score_key(a_score_key), .score_bf16(a_score_bf16),
        .score_last(a_score_last),
        .weight_wr_valid, .weight_wr_ready, .weight_wr_epoch,
        .weight_wr_group, .weight_wr_global_q_head, .weight_wr_row,
        .weight_wr_slot_id, .weight_wr_numeric_mode, .weight_wr_key,
        .weight_wr_mask, .weight_wr_data, .weight_wr_last,
        .row_commit_valid, .row_commit_ready, .row_commit_epoch,
        .row_commit_group, .row_commit_global_q_head, .row_commit_row,
        .row_commit_slot_id, .row_commit_numeric_mode,
        .row_commit_sum_fp32, .row_commit_inv_sum_fp32,
        .row_error_valid, .row_error_ready, .row_error_epoch,
        .row_error_group, .row_error_global_q_head, .row_error_row,
        .row_error_slot_id, .row_error_numeric_mode, .row_error_code,
        .row_error_bad_key,
        .slot_release_valid, .slot_release_ready, .slot_release_epoch,
        .slot_release_group, .slot_release_global_q_head,
        .slot_release_row, .slot_release_slot_id,
        .slot_release_numeric_mode,
        .rows_issue(b_rows_issue), .rows_result(b_rows_result),
        .exp_issue(b_exp_issue), .exp_result(b_exp_result),
        .exp_commit(b_exp_commit), .sum_issue(b_sum_issue),
        .sum_result(b_sum_result), .sum_commit(b_sum_commit),
        .reciprocal_issue(b_reciprocal_issue),
        .reciprocal_result(b_reciprocal_result),
        .reciprocal_commit(b_reciprocal_commit),
        .staged_weight_accept(b_staged_weights),
        .weight_wr_accept(b_weight_writes),
        .row_commit_count(b_row_commits),
        .slot_release_count(b_releases),
        .protocol_error_count(b_protocol_errors),
        .numeric_error_count(b_numeric_errors),
        .output_stall_cycles(b_output_stalls),
        .error_sticky(b_error_sticky)
    );

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            pending_response <= 0;
            score_rd_rsp_valid <= 0;
        end else begin
            if (score_rd_rsp_valid && score_rd_rsp_ready)
                score_rd_rsp_valid <= 0;
            if (pending_response &&
                (!score_rd_rsp_valid || score_rd_rsp_ready)) begin
                pending_response <= 0;
                score_rd_rsp_valid <= 1;
                score_rd_rsp_epoch <= pending_epoch;
                score_rd_rsp_group <= pending_group;
                score_rd_rsp_global_q_head <= pending_head;
                score_rd_rsp_row <= pending_row;
                score_rd_rsp_slot_id <= pending_slot;
                score_rd_rsp_numeric_mode <= pending_mode;
                score_rd_rsp_key <= pending_key;
                score_rd_rsp_bf16 <= 16'h3f80;
            end
            if (score_rd_req_valid && score_rd_req_ready) begin
                pending_response <= 1;
                pending_epoch <= score_rd_req_epoch;
                pending_group <= score_rd_req_group;
                pending_head <= score_rd_req_global_q_head;
                pending_row <= score_rd_req_row;
                pending_slot <= score_rd_req_slot_id;
                pending_mode <= score_rd_req_numeric_mode;
                pending_key <= score_rd_req_key;
            end
        end
    end

    always @(negedge clk) begin
        if (rst_n && !clear) begin
            lfsr <= {lfsr[30:0],
                     lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            weight_wr_ready <= lfsr[0] || lfsr[3];
            row_commit_ready <= lfsr[5] || lfsr[8];
        end
    end

    always @(posedge clk) begin
        if (rst_n && !clear && weight_wr_valid && weight_wr_ready) begin
            if (weight_wr_epoch !== 16'ha2b2 || weight_wr_group !== 1 ||
                weight_wr_global_q_head !== 5 || weight_wr_row !== 3 ||
                weight_wr_slot_id !== 0 ||
                weight_wr_numeric_mode !== TEST_MODE ||
                weight_wr_key !== expected_key ||
                weight_wr_mask !== (weight_wr_key > 3) ||
                weight_wr_last !== (weight_wr_key == 127))
                $fatal(1, "A2->B2 weight metadata/order mismatch");
            if (weight_wr_key <= 3) begin
`ifdef CATS_R4_ACCURACY_INTEGRATION
                if (weight_wr_data !== 32'h3f800000)
                    $fatal(1, "A2->B2 valid Accuracy weight mismatch");
`else
                if (weight_wr_data !== 32'h00003f80)
                    $fatal(1, "A2->B2 valid Compatibility weight mismatch");
`endif
            end else if (weight_wr_data !== 0) begin
                $fatal(1, "A2->B2 masked weight mismatch");
            end
            expected_key = expected_key + 1;
            observed_writes = observed_writes + 1;
        end
        if (rst_n && !clear && row_commit_valid && row_commit_ready) begin
            if (observed_writes != 128 || row_commit_epoch !== 16'ha2b2 ||
                row_commit_group !== 1 ||
                row_commit_global_q_head !== 5 || row_commit_row !== 3 ||
                row_commit_slot_id !== 0 ||
                row_commit_numeric_mode !== TEST_MODE ||
                row_commit_sum_fp32 !== 32'h40800000 ||
                row_commit_inv_sum_fp32 !== 32'h3e800000)
                $fatal(1, "A2->B2 commit mismatch");
            observed_commits = observed_commits + 1;
        end
    end

    initial begin
        in_row_valid = 0;
        in_row_epoch = 16'ha2b2;
        in_row_group = 1;
        in_row_global_q_head = 5;
        in_row_index = 3;
        in_row_slot_id = 0;
        in_row_numeric_mode = TEST_MODE;
        in_row_max_bf16 = 16'h3f80;
        score_rd_req_ready = 1;
        score_rd_rsp_valid = 0;
        score_rd_rsp_epoch = 0;
        score_rd_rsp_group = 0;
        score_rd_rsp_global_q_head = 0;
        score_rd_rsp_row = 0;
        score_rd_rsp_slot_id = 0;
        score_rd_rsp_numeric_mode = 0;
        score_rd_rsp_key = 0;
        score_rd_rsp_bf16 = 0;
        abort_ready = 1;
        weight_wr_ready = 0;
        row_commit_ready = 0;
        row_error_ready = 1;
        slot_release_valid = 0;
        slot_release_epoch = 16'ha2b2;
        slot_release_group = 1;
        slot_release_global_q_head = 5;
        slot_release_row = 3;
        slot_release_slot_id = 0;
        slot_release_numeric_mode = TEST_MODE;
        pending_response = 0;

        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        in_row_valid = 1;
        do @(posedge clk); while (!in_row_ready);
        @(negedge clk);
        in_row_valid = 0;

        wait (observed_commits == 1);
        repeat (3) @(posedge clk);
        if (abort_valid || row_error_valid || a_error_sticky ||
            b_error_sticky || a_protocol_errors != 0 ||
            a_numeric_errors != 0 || b_protocol_errors != 0 ||
            b_numeric_errors != 0 || a_row_headers != 1 ||
            a_read_requests != 4 || a_read_responses != 4 ||
            a_scores != 4 || a_rows != 1 || b_rows_issue != 1 ||
            b_rows_result != 1 || b_exp_commit != 4 ||
            b_staged_weights != 4 || b_weight_writes != 128 ||
            b_row_commits != 1)
            $fatal(1, "A2->B2 counter closure mismatch");

        @(negedge clk);
        slot_release_valid = 1;
        do @(posedge clk); while (!slot_release_ready);
        @(negedge clk);
        slot_release_valid = 0;
        repeat (2) @(posedge clk);
        if (b_releases != 1)
            $fatal(1, "A2->B2 release stub mismatch");

`ifdef CATS_R4_SHARED_INTEGRATION
`ifdef CATS_R4_ACCURACY_INTEGRATION
        $display("PASS: CATS-R4 actual A2 handoff to B2 shared wrapper Accuracy rows=%0d scores=%0d staged=%0d writes=%0d commits=%0d",
`else
        $display("PASS: CATS-R4 actual A2 handoff to B2 shared wrapper Compatibility rows=%0d scores=%0d staged=%0d writes=%0d commits=%0d",
`endif
`elsif CATS_R4_ACCURACY_INTEGRATION
        $display("PASS: CATS-R4 actual A2 handoff to B2 Accuracy rows=%0d scores=%0d staged=%0d writes=%0d commits=%0d",
`else
        $display("PASS: CATS-R4 actual A2 handoff to B2 Compatibility rows=%0d scores=%0d staged=%0d writes=%0d commits=%0d",
`endif
                 a_rows, a_scores, b_staged_weights,
                 b_weight_writes, b_row_commits);
        $finish;
    end
endmodule
