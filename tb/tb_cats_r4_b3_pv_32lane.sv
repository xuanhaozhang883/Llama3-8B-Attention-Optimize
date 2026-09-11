`timescale 1ns/1ps

module tb_cats_r4_b3_pv_32lane;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0, clear = 0, counter_clear = 0;
    logic pv_row_valid, pv_row_ready;
    logic [15:0] pv_row_epoch;
    logic [2:0] pv_row_group;
    logic [4:0] pv_row_global_q_head;
    logic [6:0] pv_row_row;
    logic [1:0] pv_row_slot_id, pv_row_numeric_mode;
    logic [31:0] pv_row_sum_fp32, pv_row_inv_sum_fp32;
    logic weight_rd_req_valid, weight_rd_req_ready;
    logic [15:0] weight_rd_req_epoch;
    logic [2:0] weight_rd_req_group;
    logic [4:0] weight_rd_req_global_q_head;
    logic [6:0] weight_rd_req_row;
    logic [1:0] weight_rd_req_slot_id, weight_rd_req_numeric_mode;
    logic [6:0] weight_rd_req_key;
    logic weight_rd_rsp_valid;
    logic [15:0] weight_rd_rsp_epoch;
    logic [2:0] weight_rd_rsp_group;
    logic [4:0] weight_rd_rsp_global_q_head;
    logic [6:0] weight_rd_rsp_row;
    logic [1:0] weight_rd_rsp_slot_id, weight_rd_rsp_numeric_mode;
    logic [6:0] weight_rd_rsp_key;
    logic weight_rd_rsp_mask;
    logic [31:0] weight_rd_rsp_data;
    logic v_req_valid, v_req_ready;
    logic [3:0] v_req_context_tag;
    logic [6:0] v_req_key;
    logic [1:0] v_req_feature_block;
    logic v_rsp_valid;
    logic [3:0] v_rsp_context_tag;
    logic [511:0] v_rsp_vec_bf16;
    logic out_valid, out_ready;
    logic [15:0] out_epoch;
    logic [11:0] out_seq;
    logic [4:0] out_global_q_head;
    logic [6:0] out_row;
    logic [1:0] out_feature_block;
    logic [511:0] out_data_bf16;
    logic out_row_last, out_tensor_last;
    logic weight_release_valid, weight_release_ready;
    logic [15:0] weight_release_epoch;
    logic [2:0] weight_release_group;
    logic [4:0] weight_release_global_q_head;
    logic [6:0] weight_release_row;
    logic [1:0] weight_release_slot_id, weight_release_numeric_mode;
    logic [63:0] pv_rows_accepted, weight_rd_requests;
    logic [63:0] weight_rd_responses, weight_rd_consumes;
    logic [63:0] v_requests, v_responses, v_consumes;
    logic [63:0] pv_mac_issue, pv_mac_result, pv_mac_commit;
    logic [63:0] context_words, rows_released, raw_scoreboard_stalls;
    logic [63:0] weight_stall_cycles, v_stall_cycles;
    logic [63:0] mac_stall_cycles, output_stall_cycles;
    logic [63:0] protocol_error_count, numeric_error_count;
    logic [63:0] epoch_drop_count, arithmetic_vector_issue;
    logic [63:0] arithmetic_lane_products, arithmetic_lane_commits;
    logic [63:0] normalize_issue_count, normalize_result_count;
    logic [63:0] arithmetic_protocol_errors, arithmetic_numeric_errors;
    logic error_sticky;

    cats_r4_b3_pv_32lane dut (.*);

    logic [31:0] lfsr;
    always_ff @(posedge clk) begin
        if (!rst_n || clear)
            lfsr <= 32'h32b3_2026;
        else
            lfsr <= {lfsr[30:0],
                     lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    end

    logic w0_valid, w1_valid;
    logic [15:0] w0_epoch, w1_epoch;
    logic [2:0] w0_group, w1_group;
    logic [4:0] w0_head, w1_head;
    logic [6:0] w0_row, w1_row, w0_key, w1_key;
    logic [1:0] w0_slot, w1_slot, w0_mode, w1_mode;
    assign weight_rd_req_ready = lfsr[0] || lfsr[3];
    assign weight_rd_rsp_valid = w1_valid;
    assign weight_rd_rsp_epoch = w1_epoch;
    assign weight_rd_rsp_group = w1_group;
    assign weight_rd_rsp_global_q_head = w1_head;
    assign weight_rd_rsp_row = w1_row;
    assign weight_rd_rsp_slot_id = w1_slot;
    assign weight_rd_rsp_numeric_mode = w1_mode;
    assign weight_rd_rsp_key = w1_key;
    assign weight_rd_rsp_mask = 0;
    assign weight_rd_rsp_data = 32'h3f80_0000;
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            w0_valid <= 0;
            w1_valid <= 0;
        end else begin
            w1_valid <= w0_valid;
            w1_epoch <= w0_epoch;
            w1_group <= w0_group;
            w1_head <= w0_head;
            w1_row <= w0_row;
            w1_slot <= w0_slot;
            w1_mode <= w0_mode;
            w1_key <= w0_key;
            w0_valid <= weight_rd_req_valid && weight_rd_req_ready;
            if (weight_rd_req_valid && weight_rd_req_ready) begin
                w0_epoch <= weight_rd_req_epoch;
                w0_group <= weight_rd_req_group;
                w0_head <= weight_rd_req_global_q_head;
                w0_row <= weight_rd_req_row;
                w0_slot <= weight_rd_req_slot_id;
                w0_mode <= weight_rd_req_numeric_mode;
                w0_key <= weight_rd_req_key;
            end
        end
    end

    logic v0_valid, v1_valid;
    logic [3:0] v0_context, v1_context;
    assign v_req_ready = lfsr[2] || lfsr[6];
    assign v_rsp_valid = v1_valid;
    assign v_rsp_context_tag = v1_context;
    assign v_rsp_vec_bf16 = {32{16'h3f80}};
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            v0_valid <= 0;
            v1_valid <= 0;
        end else begin
            v1_valid <= v0_valid;
            v1_context <= v0_context;
            v0_valid <= v_req_valid && v_req_ready;
            if (v_req_valid && v_req_ready)
                v0_context <= v_req_context_tag;
        end
    end

    assign out_ready = lfsr[5] && lfsr[9];
    assign weight_release_ready = lfsr[8] && lfsr[13];

    logic [3:0] seen_weight_key;
    logic [15:0] seen_v_pair;
    integer out_blocks;
    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            seen_weight_key <= 0;
            seen_v_pair <= 0;
            out_blocks <= 0;
        end else begin
            if (weight_rd_req_valid && weight_rd_req_ready) begin
                if (weight_rd_req_epoch != 16'd11 ||
                    weight_rd_req_global_q_head != 5 ||
                    weight_rd_req_row != 3 ||
                    weight_rd_req_slot_id != 2 ||
                    weight_rd_req_numeric_mode != 1 ||
                    seen_weight_key[weight_rd_req_key])
                    $fatal(1, "weight request token/key mismatch");
                seen_weight_key[weight_rd_req_key] <= 1'b1;
            end
            if (v_req_valid && v_req_ready) begin
                if (v_req_context_tag != {2'd2,v_req_feature_block} ||
                    v_req_key > 3 ||
                    seen_v_pair[v_req_key*4+v_req_feature_block])
                    $fatal(1, "V request key/block mismatch");
                seen_v_pair[v_req_key*4+v_req_feature_block] <= 1'b1;
            end
            if (out_valid && out_ready) begin
                if (out_epoch != 16'd11 || out_seq != 12'd643 ||
                    out_global_q_head != 5 || out_row != 3 ||
                    out_feature_block != out_blocks ||
                    out_data_bf16 != {32{16'h3f80}} ||
                    out_row_last != (out_blocks == 3) || out_tensor_last)
                    $fatal(1, "end-to-end output mismatch block=%0d",
                           out_blocks);
                out_blocks <= out_blocks + 1;
            end
            if (weight_release_valid && weight_release_ready)
                if (weight_release_epoch != 16'd11 ||
                    weight_release_global_q_head != 5 ||
                    weight_release_row != 3 ||
                    weight_release_slot_id != 2 ||
                    weight_release_numeric_mode != 1)
                    $fatal(1, "release token mismatch");
        end
    end

    integer timeout;
    initial begin
        pv_row_valid = 0;
        pv_row_epoch = 0;
        pv_row_group = 0;
        pv_row_global_q_head = 0;
        pv_row_row = 0;
        pv_row_slot_id = 0;
        pv_row_numeric_mode = 0;
        pv_row_sum_fp32 = 0;
        pv_row_inv_sum_fp32 = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;
        @(negedge clk);
        pv_row_valid = 1;
        pv_row_epoch = 16'd11;
        pv_row_group = 1;
        pv_row_global_q_head = 5;
        pv_row_row = 3;
        pv_row_slot_id = 2;
        pv_row_numeric_mode = 1;
        pv_row_sum_fp32 = 32'h4080_0000;
        pv_row_inv_sum_fp32 = 32'h3e80_0000;
        do @(negedge clk); while (!pv_row_ready);
        pv_row_valid = 0;

        timeout = 0;
        while (rows_released != 1 && timeout < 5000) begin
            @(posedge clk);
            timeout++;
        end
        if (timeout == 5000)
            $fatal(1, "timeout waiting for B3 end-to-end row");
        if (seen_weight_key != 4'hf || seen_v_pair != 16'hffff ||
            out_blocks != 4 || pv_rows_accepted != 1 ||
            weight_rd_requests != 4 || weight_rd_responses != 4 ||
            weight_rd_consumes != 4 || v_requests != 16 ||
            v_responses != 16 || v_consumes != 16 ||
            pv_mac_issue != 512 || pv_mac_result != 512 ||
            pv_mac_commit != 512 || context_words != 128 ||
            rows_released != 1 || arithmetic_vector_issue != 16 ||
            arithmetic_lane_products != 512 ||
            arithmetic_lane_commits != 512 ||
            normalize_issue_count != 4 || normalize_result_count != 4 ||
            protocol_error_count != 0 || numeric_error_count != 0 ||
            epoch_drop_count != 0 || arithmetic_protocol_errors != 0 ||
            arithmetic_numeric_errors != 0 || error_sticky)
            $fatal(1,
                "B3 e2e counters mismatch w=%0d/%0d/%0d v=%0d/%0d/%0d pv=%0d/%0d/%0d out=%0d rel=%0d arith=%0d/%0d/%0d norm=%0d/%0d err=%0d",
                weight_rd_requests, weight_rd_responses,
                weight_rd_consumes, v_requests, v_responses, v_consumes,
                pv_mac_issue, pv_mac_result, pv_mac_commit, context_words,
                rows_released, arithmetic_vector_issue,
                arithmetic_lane_products, arithmetic_lane_commits,
                normalize_issue_count, normalize_result_count, error_sticky);

        $display("PASS B3 32-lane end-to-end row=3 weights=4 V=16 PV_MAC=512 Context=128 cycles=%0d raw_stalls=%0d",
                 timeout, raw_scoreboard_stalls);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "global timeout");
    end
endmodule
