`timescale 1ns/1ps

// Read-only-package regression for the v3.0 8-group GQA control path.
//
// The test deliberately uses S8/D8 so it is fast enough for every edit.  Q and
// K are zero, therefore all legal causal scores are equal.  Every KV group has
// a different constant V value, so any group-addressing or global-head error is
// visible in the final Context stream.  Random source latency and destination
// backpressure exercise the ready/valid boundaries.
module tb_v30_online_attention_system_8gqa;
    localparam int SEQ = 8;
    localparam int DIM = 8;
    localparam int GROUPS = 8;
    localparam int Q_HEADS_PER_GROUP = 4;
    localparam int V_WORDS_PER_GROUP = SEQ*DIM;
    localparam int WORDS_PER_GROUP = Q_HEADS_PER_GROUP*SEQ*DIM;
    localparam int TOTAL_WORDS = GROUPS*WORDS_PER_GROUP;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n, start, start_ready, busy, done;
    logic raw_req_valid, raw_req_ready, raw_req_is_k;
    logic [4:0] raw_req_head;
    logic [2:0] raw_req_token;
    logic [1:0] raw_req_pair;
    logic raw_rsp_valid, raw_rsp_ready;
    logic [15:0] raw_rsp_x0, raw_rsp_x1;
    logic v_load_valid, v_load_ready;
    logic [8:0] v_load_addr;
    logic [63:0] v_load_data;
    logic context_valid, context_ready;
    logic [15:0] context_bf16;
    logic [31:0] context_fp32_debug;
    logic [2:0] context_group_id;
    logic [1:0] context_head;
    logic [4:0] context_global_q_head;
    logic [2:0] context_row, context_col;
    logic context_group_last, context_global_last;
    logic group_complete;
    logic [2:0] completed_group_id, active_group_id;
    logic rope_busy, qk_busy, online_busy;
    logic [31:0] qk_tiles_computed, qk_tiles_skipped;
    logic [31:0] masked_tiles_emitted;
    logic [31:0] online_tiles_processed, online_tiles_skipped;
    logic [31:0] online_rescale_events, online_v_vectors_read;
    logic [31:0] online_mac_terms;
    logic start_while_busy_error, qk_causal_skip_error;
    logic v_cache_error, online_order_error, online_numeric_error;
    logic protocol_error;

    logic [15:0] lfsr;
    logic raw_pending;
    logic [1:0] raw_delay;
    integer output_count;
    integer raw_request_count;
    integer group_complete_count;
    integer failures;

    attention_online_system_with_rope_top #(
        .QK_TILE(4), .QK_LANES(2), .V_LANES(4),
        .SEQ_LEN(SEQ), .HEAD_DIM(DIM),
        .Q_HEADS(Q_HEADS_PER_GROUP),
        .GQA_GROUPS(GROUPS), .RUN_GQA_GROUPS(GROUPS),
`ifdef V30_XSIM
        .EXP_LUT_FILE("exp_lut_q15.mem"),
        .SIN_ROM_FILE("sin_bf16.hex"),
        .COS_ROM_FILE("cos_bf16.hex")
`else
        .EXP_LUT_FILE("mem/exp_lut_q15.mem"),
        .SIN_ROM_FILE("mem/sin_bf16.hex"),
        .COS_ROM_FILE("mem/cos_bf16.hex")
`endif
    ) dut (
        .clk, .rst_n, .start, .start_ready, .busy, .done,
        .causal_en(1'b1),
        .raw_req_valid, .raw_req_ready, .raw_req_is_k,
        .raw_req_head, .raw_req_token, .raw_req_pair,
        .raw_rsp_valid, .raw_rsp_ready, .raw_rsp_x0, .raw_rsp_x1,
        .v_load_valid, .v_load_ready, .v_load_addr, .v_load_data,
        .context_valid, .context_ready, .context_bf16,
        .context_fp32_debug, .context_group_id, .context_head,
        .context_global_q_head, .context_row, .context_col,
        .context_group_last, .context_global_last,
        .group_complete, .completed_group_id, .active_group_id,
        .rope_busy, .qk_busy, .online_busy,
        .qk_tiles_computed, .qk_tiles_skipped, .masked_tiles_emitted,
        .online_tiles_processed, .online_tiles_skipped,
        .online_rescale_events, .online_v_vectors_read,
        .online_mac_terms, .start_while_busy_error,
        .qk_causal_skip_error, .v_cache_error,
        .online_order_error, .online_numeric_error, .protocol_error
    );

    function automatic logic [15:0] expected_v(input logic [2:0] group_id);
        case (group_id)
            3'd0: expected_v = 16'h3F80; // +1.00
            3'd1: expected_v = 16'hBF00; // -0.50
            3'd2: expected_v = 16'h3F00; // +0.50
            3'd3: expected_v = 16'hBF80; // -1.00
            3'd4: expected_v = 16'h4000; // +2.00
            3'd5: expected_v = 16'hC000; // -2.00
            3'd6: expected_v = 16'h3E80; // +0.25
            default: expected_v = 16'hBE80; // -0.25
        endcase
    endfunction

    assign raw_req_ready = !raw_pending;
    assign context_ready = lfsr[2] || lfsr[9];

    // Returning zero for all raw Q/K words makes RoPE and QK exactly zero.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= 16'h5A3C;
            raw_pending <= 1'b0;
            raw_delay <= '0;
            raw_rsp_valid <= 1'b0;
            raw_rsp_x0 <= 16'h0000;
            raw_rsp_x1 <= 16'h0000;
            raw_request_count <= 0;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
            if (raw_req_valid && raw_req_ready) begin
                raw_pending <= 1'b1;
                raw_delay <= {1'b0, lfsr[0]} + 1'b1;
                raw_request_count <= raw_request_count + 1;
            end
            if (raw_pending && !raw_rsp_valid) begin
                if (raw_delay != 0)
                    raw_delay <= raw_delay - 1'b1;
                else
                    raw_rsp_valid <= 1'b1;
            end
            if (raw_rsp_valid && raw_rsp_ready) begin
                raw_rsp_valid <= 1'b0;
                raw_pending <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        logic [15:0] expected;
        if (!rst_n) begin
            output_count <= 0;
            group_complete_count <= 0;
            failures <= 0;
        end else begin
            if (group_complete) begin
                if (completed_group_id !== group_complete_count[2:0]) begin
                    $display("[FAIL] completed group exp=%0d got=%0d",
                             group_complete_count, completed_group_id);
                    failures <= failures + 1;
                end
                group_complete_count <= group_complete_count + 1;
            end
            if (context_valid && context_ready) begin
                expected = expected_v(context_group_id);
                if (context_bf16 !== expected) begin
                    $display("[FAIL] context[%0d] group=%0d exp=%h got=%h fp32=%h",
                             output_count, context_group_id, expected,
                             context_bf16, context_fp32_debug);
                    failures <= failures + 1;
                end
                if (context_global_q_head !==
                    context_group_id*Q_HEADS_PER_GROUP + context_head) begin
                    $display("[FAIL] global head group=%0d local=%0d got=%0d",
                             context_group_id, context_head,
                             context_global_q_head);
                    failures <= failures + 1;
                end
                if (context_group_last !==
                    ((output_count % WORDS_PER_GROUP) == WORDS_PER_GROUP-1)) begin
                    $display("[FAIL] context_group_last at output %0d",
                             output_count);
                    failures <= failures + 1;
                end
                if (context_global_last !==
                    (output_count == TOTAL_WORDS-1)) begin
                    $display("[FAIL] context_global_last at output %0d",
                             output_count);
                    failures <= failures + 1;
                end
                output_count <= output_count + 1;
            end
        end
    end

    task automatic load_v_group(
        input integer group,
        input logic [15:0] value
    );
        integer address;
        begin
            for (address = group*V_WORDS_PER_GROUP;
                 address < (group+1)*V_WORDS_PER_GROUP; address += 4) begin
                @(negedge clk);
                v_load_addr = address[8:0];
                v_load_data = {value, value, value, value};
                v_load_valid = 1'b1;
                while (!v_load_ready) @(negedge clk);
                @(negedge clk);
                v_load_valid = 1'b0;
            end
        end
    endtask

    initial begin : TEST
        integer group_index;
        integer final_failures;
        rst_n = 1'b0;
        start = 1'b0;
        v_load_valid = 1'b0;
        v_load_addr = '0;
        v_load_data = '0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        for (group_index = 0; group_index < GROUPS;
             group_index = group_index + 1)
            load_v_group(group_index, expected_v(group_index[2:0]));

        while (!start_ready) @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        fork
            wait(done);
            begin
                repeat (4000000) @(posedge clk);
                $fatal(1, "[FAIL] 8-GQA timeout state=%0d outputs=%0d",
                       dut.state, output_count);
            end
        join_any
        disable fork;
        repeat (2) @(posedge clk);

        final_failures = failures;
        if (output_count != TOTAL_WORDS) final_failures += 1;
        if (raw_request_count != 1280) final_failures += 1;
        if (group_complete_count != GROUPS) final_failures += 1;
        if (qk_tiles_computed != 96 || qk_tiles_skipped != 32 ||
            masked_tiles_emitted != 32) final_failures += 1;
        if (online_tiles_processed != 96 || online_tiles_skipped != 32 ||
            online_v_vectors_read != 768 || online_mac_terms != 9216)
            final_failures += 1;
        if (online_rescale_events != 0) final_failures += 1;
        if (start_while_busy_error || qk_causal_skip_error || v_cache_error ||
            online_order_error || online_numeric_error || protocol_error)
            final_failures += 1;

        if (final_failures == 0) begin
            integer pass_fd;
            $display("[PASS] V3.0 8-GQA END-TO-END ONLINE CONTEXT");
            pass_fd = $fopen("v30_8gqa_xsim_pass.txt", "w");
            if (pass_fd != 0) begin
                $fdisplay(pass_fd,
                    "V3.0 8-GQA END-TO-END ONLINE CONTEXT: SIM_PASS");
                $fclose(pass_fd);
            end
        end else begin
            $display("[FAIL] outputs=%0d raw=%0d groups=%0d",
                     output_count, raw_request_count, group_complete_count);
            $display("[FAIL] qk=%0d/%0d masked=%0d online=%0d/%0d v=%0d mac=%0d",
                     qk_tiles_computed, qk_tiles_skipped,
                     masked_tiles_emitted, online_tiles_processed,
                     online_tiles_skipped, online_v_vectors_read,
                     online_mac_terms);
            $fatal(1, "[FAIL] V3.0 8-GQA failures=%0d", final_failures);
        end
        $finish;
    end
endmodule
