`timescale 1ns/1ps

module tb_cats_r4_b4_row_error_release_overlap;
    localparam logic [15:0] NORMAL_EPOCH = 16'h4401;
    localparam logic [15:0] ERROR_EPOCH = 16'h4402;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n = 1'b0;
    logic row_error_ready;
    logic row_error_valid;
    logic [15:0] row_error_epoch;
    logic [2:0] row_error_group;
    logic [4:0] row_error_global_q_head;
    logic [6:0] row_error_row;
    logic [1:0] row_error_slot_id;
    logic [1:0] row_error_numeric_mode;
    logic [3:0] row_error_code;
    logic [6:0] row_error_bad_key;
    logic weight_release_valid;
    logic [15:0] weight_release_epoch;
    logic [1:0] weight_release_slot_id;
    logic final_release_ready;
    logic final_release_valid;
    logic [15:0] final_release_epoch;
    logic [1:0] final_release_slot_id;
    logic [63:0] final_release_count;
    logic [63:0] release_join_errors;

    integer public_error_handshakes;
    integer internal_error_handshakes;
    integer weight_release_handshakes;
    integer final_release_handshakes;
    logic [45:0] held_error_payload;

    wire [45:0] error_payload = {
        row_error_epoch,
        row_error_group,
        row_error_global_q_head,
        row_error_row,
        row_error_slot_id,
        row_error_numeric_mode,
        row_error_code,
        row_error_bad_key
    };

    cats_r4_b4_softmax_pv_cluster dut (
        .clk(clk),
        .rst_n(rst_n),
        .clear(1'b0),
        .counter_clear(1'b0),
        .row_valid(1'b0),
        .row_ready(),
        .row_epoch(16'd0),
        .row_group(3'd0),
        .row_global_q_head(5'd0),
        .row_index(7'd0),
        .row_slot_id(2'd0),
        .row_numeric_mode(2'd0),
        .row_max_bf16(16'd0),
        .score_valid(1'b0),
        .score_ready(),
        .score_epoch(16'd0),
        .score_group(3'd0),
        .score_global_q_head(5'd0),
        .score_row(7'd0),
        .score_slot_id(2'd0),
        .score_numeric_mode(2'd0),
        .score_key(7'd0),
        .score_bf16(16'd0),
        .score_last(1'b0),
        .weight_wr_valid(),
        .weight_wr_ready(1'b1),
        .weight_wr_epoch(),
        .weight_wr_group(),
        .weight_wr_global_q_head(),
        .weight_wr_row(),
        .weight_wr_slot_id(),
        .weight_wr_numeric_mode(),
        .weight_wr_key(),
        .weight_wr_mask(),
        .weight_wr_data(),
        .weight_wr_last(),
        .row_commit_valid(),
        .row_commit_ready(1'b1),
        .row_commit_epoch(),
        .row_commit_group(),
        .row_commit_global_q_head(),
        .row_commit_row(),
        .row_commit_slot_id(),
        .row_commit_numeric_mode(),
        .row_commit_sum_fp32(),
        .row_commit_inv_sum_fp32(),
        .row_error_valid(row_error_valid),
        .row_error_ready(row_error_ready),
        .row_error_epoch(row_error_epoch),
        .row_error_group(row_error_group),
        .row_error_global_q_head(row_error_global_q_head),
        .row_error_row(row_error_row),
        .row_error_slot_id(row_error_slot_id),
        .row_error_numeric_mode(row_error_numeric_mode),
        .row_error_code(row_error_code),
        .row_error_bad_key(row_error_bad_key),
        .pv_row_valid(1'b0),
        .pv_row_ready(),
        .pv_row_epoch(16'd0),
        .pv_row_group(3'd0),
        .pv_row_global_q_head(5'd0),
        .pv_row_row(7'd0),
        .pv_row_slot_id(2'd0),
        .pv_row_numeric_mode(2'd0),
        .pv_row_sum_fp32(32'd0),
        .pv_row_inv_sum_fp32(32'd0),
        .weight_rd_req_valid(),
        .weight_rd_req_ready(1'b1),
        .weight_rd_req_epoch(),
        .weight_rd_req_group(),
        .weight_rd_req_global_q_head(),
        .weight_rd_req_row(),
        .weight_rd_req_slot_id(),
        .weight_rd_req_numeric_mode(),
        .weight_rd_req_key(),
        .weight_rd_rsp_valid(1'b0),
        .weight_rd_rsp_epoch(16'd0),
        .weight_rd_rsp_group(3'd0),
        .weight_rd_rsp_global_q_head(5'd0),
        .weight_rd_rsp_row(7'd0),
        .weight_rd_rsp_slot_id(2'd0),
        .weight_rd_rsp_numeric_mode(2'd0),
        .weight_rd_rsp_key(7'd0),
        .weight_rd_rsp_mask(1'b0),
        .weight_rd_rsp_data(32'd0),
        .v_req_valid(),
        .v_req_ready(1'b1),
        .v_req_context_tag(),
        .v_req_key(),
        .v_req_feature_block(),
        .v_rsp_valid(1'b0),
        .v_rsp_context_tag(4'd0),
        .v_rsp_vec_bf16(512'd0),
        .out_valid(),
        .out_ready(1'b1),
        .out_epoch(),
        .out_seq(),
        .out_global_q_head(),
        .out_row(),
        .out_feature_block(),
        .out_data_bf16(),
        .out_row_last(),
        .out_tensor_last(),
        .weight_release_valid(weight_release_valid),
        .weight_release_ready(1'b1),
        .weight_release_epoch(weight_release_epoch),
        .weight_release_group(),
        .weight_release_global_q_head(),
        .weight_release_row(),
        .weight_release_slot_id(weight_release_slot_id),
        .weight_release_numeric_mode(),
        .final_release_valid(final_release_valid),
        .final_release_ready(final_release_ready),
        .final_release_epoch(final_release_epoch),
        .final_release_group(),
        .final_release_global_q_head(),
        .final_release_row(),
        .final_release_slot_id(final_release_slot_id),
        .final_release_numeric_mode(),
        .b2_rows_issue(),
        .b2_exp_issue(),
        .b2_exp_commit(),
        .b2_weight_writes(),
        .b2_row_commits(),
        .b2_slot_releases(),
        .b2_protocol_errors(),
        .b2_numeric_errors(),
        .b2_owner_errors(),
        .b3_pv_rows(),
        .b3_weight_requests(),
        .b3_weight_responses(),
        .b3_weight_consumes(),
        .b3_v_requests(),
        .b3_v_responses(),
        .b3_v_consumes(),
        .b3_pv_issue(),
        .b3_pv_result(),
        .b3_pv_commit(),
        .b3_context_words(),
        .b3_rows_released(),
        .b3_protocol_errors(),
        .b3_numeric_errors(),
        .b3_epoch_drops(),
        .final_release_count(final_release_count),
        .release_join_errors(release_join_errors),
        .error_sticky()
    );

    always @(posedge clk) begin
        if (rst_n) begin
            if (row_error_valid && row_error_ready) begin
                public_error_handshakes = public_error_handshakes + 1;
                if (!(dut.b2_row_error_valid && dut.b2_row_error_ready))
                    $fatal(1,
                        "B4 phantom public row error handshake while B2 is blocked");
            end
            if (dut.b2_row_error_valid && dut.b2_row_error_ready)
                internal_error_handshakes = internal_error_handshakes + 1;
            if (weight_release_valid)
                weight_release_handshakes = weight_release_handshakes + 1;
            if (final_release_valid && final_release_ready)
                final_release_handshakes = final_release_handshakes + 1;
        end
    end

    initial begin
        row_error_ready = 1'b1;
        final_release_ready = 1'b0;
        public_error_handshakes = 0;
        internal_error_handshakes = 0;
        weight_release_handshakes = 0;
        final_release_handshakes = 0;

        force dut.b2_release_ready = 1'b1;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Capture a normal release for slot 0 and drain both owners while
        // deliberately stalling the public final release.
        force dut.b3_release_epoch = NORMAL_EPOCH;
        force dut.b3_release_group = 3'd0;
        force dut.b3_release_head = 5'd0;
        force dut.b3_release_row = 7'd0;
        force dut.b3_release_slot = 2'd0;
        force dut.b3_release_mode = 2'd0;
        force dut.b3_release_valid = 1'b1;
        do @(posedge clk); while (!dut.b3_release_ready);
        force dut.b3_release_valid = 1'b0;
        wait (final_release_valid);
        if (final_release_epoch != NORMAL_EPOCH ||
            final_release_slot_id != 0)
            $fatal(1, "B4 normal release token mismatch");

        // B2 presents an error for a different slot while the normal final
        // release is pending.  Downstream ready remains high at the overlap.
        force dut.b2_row_error_epoch = ERROR_EPOCH;
        force dut.b2_row_error_group = 3'd0;
        force dut.b2_row_error_head = 5'd1;
        force dut.b2_row_error_row = 7'd7;
        force dut.b2_row_error_slot = 2'd1;
        force dut.b2_row_error_mode = 2'd1;
        force dut.b2_row_error_code = 4'h5;
        force dut.b2_row_error_key = 7'd3;
        force dut.b2_row_error_valid = 1'b1;
        @(posedge clk);
        #1;
        if (public_error_handshakes != 0 ||
            internal_error_handshakes != 0)
            $fatal(1, "B4 consumed row error during pending release");

        // Release the normal token while backpressuring the newly-visible
        // error, then verify its complete payload remains stable.
        @(negedge clk);
        row_error_ready = 1'b0;
        final_release_ready = 1'b1;
        @(posedge clk);
        #1;
        if (!row_error_valid)
            $fatal(1, "B4 did not expose held row error after release");
        held_error_payload = error_payload;
        repeat (2) begin
            @(posedge clk);
            #1;
            if (!row_error_valid || error_payload != held_error_payload)
                $fatal(1, "B4 public row error payload changed while stalled");
        end

        @(negedge clk);
        row_error_ready = 1'b1;
        @(posedge clk);
        #1;
        if (public_error_handshakes != 1 ||
            internal_error_handshakes != 1)
            $fatal(1, "B4 row error handshake count mismatch public=%0d internal=%0d",
                public_error_handshakes, internal_error_handshakes);
        force dut.b2_row_error_valid = 1'b0;

        wait (final_release_count == 2);
        repeat (2) @(posedge clk);
        if (public_error_handshakes != 1 ||
            internal_error_handshakes != 1 ||
            weight_release_handshakes != 1 ||
            final_release_handshakes != 2 ||
            release_join_errors != 0)
            $fatal(1,
                "B4 release/error closure mismatch public=%0d internal=%0d weight=%0d final=%0d join=%0d",
                public_error_handshakes, internal_error_handshakes,
                weight_release_handshakes, final_release_handshakes,
                release_join_errors);

        $display("PASS B4 row-error/release overlap public=%0d internal=%0d weight_releases=%0d final_releases=%0d",
            public_error_handshakes, internal_error_handshakes,
            weight_release_handshakes, final_release_handshakes);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "B4 row-error/release overlap timeout");
    end
endmodule
