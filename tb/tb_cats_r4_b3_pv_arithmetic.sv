`timescale 1ns/1ps

module tb_cats_r4_b3_pv_arithmetic;
    logic clk = 0;
    always #5 clk = ~clk;
    logic rst_n = 0, clear = 0, counter_clear = 0;

    logic mac_valid, mac_ready;
    logic [3:0] mac_context_tag;
    logic [6:0] mac_key;
    logic mac_first, mac_last;
    logic [1:0] mac_numeric_mode;
    logic [31:0] mac_weight_data;
    logic [511:0] mac_v_vec_bf16;
    logic mac_rsp_valid, mac_rsp_ready;
    logic [3:0] mac_rsp_context_tag;
    logic [6:0] mac_rsp_key;
    logic mac_rsp_last;
    logic [1023:0] mac_rsp_accum_fp32;
    logic [63:0] vector_issue_count, lane_product_count;
    logic [63:0] lane_commit_count, mac_input_stalls;
    logic [63:0] mac_output_stalls, mac_protocol_errors;
    logic mac_error_sticky;

    logic norm_valid, norm_ready;
    logic [3:0] norm_context_tag;
    logic [1023:0] norm_numerator_fp32;
    logic [31:0] norm_inv_sum_fp32;
    logic norm_rsp_valid, norm_rsp_ready;
    logic [3:0] norm_rsp_context_tag;
    logic [511:0] norm_rsp_context_bf16;
    logic [63:0] normalize_issue_count, normalize_result_count;
    logic [63:0] norm_output_stalls, norm_numeric_errors;
    logic norm_error_sticky;

    cats_r4_b3_pv_mac_32lane u_mac (
        .clk, .rst_n, .clear, .counter_clear,
        .mac_valid, .mac_ready, .mac_context_tag, .mac_key,
        .mac_first, .mac_last, .mac_numeric_mode, .mac_weight_data,
        .mac_v_vec_bf16, .mac_rsp_valid, .mac_rsp_ready,
        .mac_rsp_context_tag, .mac_rsp_key, .mac_rsp_last,
        .mac_rsp_accum_fp32, .vector_issue_count, .lane_product_count,
        .lane_commit_count, .input_stall_cycles(mac_input_stalls),
        .output_stall_cycles(mac_output_stalls),
        .protocol_error_count(mac_protocol_errors),
        .error_sticky(mac_error_sticky)
    );

    assign norm_valid = mac_rsp_valid && mac_rsp_last;
    assign norm_context_tag = mac_rsp_context_tag;
    assign norm_numerator_fp32 = mac_rsp_accum_fp32;
    assign norm_inv_sum_fp32 = mac_rsp_context_tag == 4'd0 &&
                               mac_rsp_key == 1 ?
                               32'h3f00_0000 : 32'h3f80_0000;
    assign mac_rsp_ready = !mac_rsp_last || norm_ready;

    cats_r4_b3_pv_normalize_32lane u_norm (
        .clk, .rst_n, .clear, .counter_clear,
        .norm_valid, .norm_ready, .norm_context_tag,
        .norm_numerator_fp32, .norm_inv_sum_fp32,
        .norm_rsp_valid, .norm_rsp_ready, .norm_rsp_context_tag,
        .norm_rsp_context_bf16, .normalize_issue_count,
        .normalize_result_count,
        .output_stall_cycles(norm_output_stalls),
        .numeric_error_count(norm_numeric_errors),
        .error_sticky(norm_error_sticky)
    );

    logic [31:0] lfsr;
    assign norm_rsp_ready = lfsr[0] || lfsr[5];
    always_ff @(posedge clk) begin
        if (!rst_n || clear)
            lfsr <= 32'hb3ac_2026;
        else
            lfsr <= {lfsr[30:0],
                     lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
    end

    integer norm_seen;
    always_ff @(posedge clk) begin
        if (!rst_n || clear)
            norm_seen <= 0;
        else if (norm_rsp_valid && norm_rsp_ready) begin
            if (norm_rsp_context_bf16 != {32{16'h3f80}})
                $fatal(1, "normalized vector mismatch context=%0d data=%h",
                       norm_rsp_context_tag,
                       norm_rsp_context_bf16[15:0]);
            norm_seen <= norm_seen + 1;
        end
    end

    task automatic send_mac(
        input [3:0] context_tag,
        input [6:0] key,
        input first,
        input last,
        input [1:0] mode
    );
        begin
            @(negedge clk);
            mac_valid = 1;
            mac_context_tag = context_tag;
            mac_key = key;
            mac_first = first;
            mac_last = last;
            mac_numeric_mode = mode;
            mac_weight_data = mode == 0 ?
                              32'h0000_3f80 : 32'h3f80_0000;
            mac_v_vec_bf16 = {32{16'h3f80}};
            do @(posedge clk); while (!mac_ready);
            @(negedge clk);
            mac_valid = 0;
        end
    endtask

    integer context_index;
    integer timeout;
    initial begin
        mac_valid = 0;
        mac_context_tag = 0;
        mac_key = 0;
        mac_first = 0;
        mac_last = 0;
        mac_numeric_mode = 0;
        mac_weight_data = 0;
        mac_v_vec_bf16 = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        // Flush a request after it entered the multiplier but before the full
        // multiply/add/normalize chain could retire it.  No pre-clear result
        // may acquire post-clear metadata.
        send_mac(15, 0, 1, 1, 1);
        @(negedge clk);
        clear = 1;
        repeat (2) @(negedge clk);
        clear = 0;
        repeat (5) @(posedge clk);
        if (mac_rsp_valid || norm_rsp_valid || norm_seen != 0 ||
            vector_issue_count != 0 || lane_product_count != 0 ||
            lane_commit_count != 0 || normalize_issue_count != 0 ||
            normalize_result_count != 0 || mac_error_sticky ||
            norm_error_sticky)
            $fatal(1, "arithmetic clear leaked an in-flight result");

        // Twelve independent feature contexts are accepted without bubbles.
        for (context_index = 0; context_index < 12; context_index++)
            send_mac(context_index[3:0], 0, 1, 1,
                     context_index[0]);

        timeout = 0;
        while (norm_seen != 12 && timeout < 2000) begin
            @(posedge clk);
            timeout++;
        end
        if (timeout == 2000)
            $fatal(1, "timeout waiting for first normalization batch");

        // Reuse context zero for a two-key row.  The second request waits for
        // the first response, exactly as the controller RAW scoreboard does.
        send_mac(0, 0, 1, 0, 1);
        while (!(mac_rsp_valid && mac_rsp_ready &&
                 mac_rsp_context_tag == 0 && mac_rsp_key == 0))
            @(posedge clk);
        send_mac(0, 1, 0, 1, 1);

        timeout = 0;
        while (norm_seen != 13 && timeout < 2000) begin
            @(posedge clk);
            timeout++;
        end
        if (timeout == 2000)
            $fatal(1, "timeout waiting for two-key normalization");
        if (vector_issue_count != 14 || lane_product_count != 448 ||
            lane_commit_count != 448 || normalize_issue_count != 13 ||
            normalize_result_count != 13 || mac_protocol_errors != 0 ||
            norm_numeric_errors != 0 || mac_error_sticky ||
            norm_error_sticky)
            $fatal(1,
                "arithmetic counters mismatch vec=%0d mul=%0d add=%0d norm=%0d/%0d err=%0d/%0d",
                vector_issue_count, lane_product_count, lane_commit_count,
                normalize_issue_count, normalize_result_count,
                mac_protocol_errors, norm_numeric_errors);

        $display("PASS B3 PV arithmetic vectors=14 lane_mul_add=448 normalized=13 mac_stalls=%0d norm_stalls=%0d",
                 mac_output_stalls, norm_output_stalls);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "global timeout");
    end
endmodule
