`timescale 1ns/1ps

module tb_v30_online_softmax_context;
    localparam int SEQ = 8;
    localparam int DIM = 8;
    localparam int TILE = 4;
    localparam int WORDS = SEQ*DIM;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic rst_n;
    logic start;
    logic start_ready;
    logic busy;
    logic done;

    logic score_valid;
    logic score_ready;
    logic [15:0] score_bf16;
    logic [0:0] score_head;
    logic [2:0] score_row, score_col;
    logic score_global_last;

    logic v_req_valid, v_req_ready;
    logic [5:0] v_req_addr;
    logic v_rsp_valid, v_rsp_ready;
    logic [63:0] v_rsp_data;

    logic context_valid, context_ready;
    logic [15:0] context_bf16;
    logic [31:0] context_fp32_debug;
    logic [0:0] context_group_id;
    logic [0:0] context_head;
    logic [2:0] context_row, context_col;
    logic context_group_last;

    logic [31:0] online_tiles_processed;
    logic [31:0] online_tiles_skipped;
    logic [31:0] online_rescale_events;
    logic [31:0] online_v_vectors_read;
    logic [31:0] online_mac_terms;
    logic order_error, numeric_error;

    logic [15:0] score_mem [0:WORDS-1];
    logic [15:0] value_mem [0:WORDS-1];
    logic [15:0] golden_mem [0:WORDS-1];

    logic [15:0] lfsr;
    logic v_pending;
    logic [5:0] v_pending_addr;
    logic [1:0] v_delay;
    integer output_count;
    integer cycle_count;
    integer stream_failures;

    online_softmax_context_tile #(
        .TILE(TILE), .SEQ_LEN(SEQ), .HEAD_DIM(DIM),
        .Q_HEADS(1), .GQA_GROUPS(1),
`ifdef V30_XSIM
        .EXP_LUT_FILE("exp_lut_q15.mem")
`else
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
`endif
    ) dut (
        .clk, .rst_n, .start, .group_id(1'b0), .causal_en(1'b1),
        .start_ready, .busy, .done,
        .score_valid, .score_ready, .score_bf16,
        .score_head, .score_row, .score_col, .score_global_last,
        .v_req_valid, .v_req_ready, .v_req_addr,
        .v_rsp_valid, .v_rsp_ready, .v_rsp_data,
        .context_valid, .context_ready, .context_bf16,
        .context_fp32_debug, .context_group_id, .context_head,
        .context_row, .context_col, .context_group_last,
        .online_tiles_processed, .online_tiles_skipped,
        .online_rescale_events, .online_v_vectors_read,
        .online_mac_terms, .order_error, .numeric_error
    );

    assign v_req_ready = !v_pending && lfsr[0];
    assign context_ready = lfsr[3] || lfsr[7];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= 16'h1ACE;
            v_pending <= 1'b0;
            v_pending_addr <= '0;
            v_delay <= '0;
            v_rsp_valid <= 1'b0;
            v_rsp_data <= '0;
            cycle_count <= 0;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
            cycle_count <= cycle_count + 1;

            if (v_req_valid && v_req_ready) begin
                v_pending <= 1'b1;
                v_pending_addr <= v_req_addr;
                v_delay <= {1'b0, lfsr[2]} + 1'b1;
            end

            if (v_pending && !v_rsp_valid) begin
                if (v_delay != 0)
                    v_delay <= v_delay - 1'b1;
                else begin
                    v_rsp_data[15:0]  <= value_mem[v_pending_addr+0];
                    v_rsp_data[31:16] <= value_mem[v_pending_addr+1];
                    v_rsp_data[47:32] <= value_mem[v_pending_addr+2];
                    v_rsp_data[63:48] <= value_mem[v_pending_addr+3];
                    v_rsp_valid <= 1'b1;
                end
            end

            if (v_rsp_valid && v_rsp_ready) begin
                v_rsp_valid <= 1'b0;
                v_pending <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        integer within_tile;
        integer row_base;
        integer feature_base;
        integer expected_row;
        integer expected_col;
        if (!rst_n) begin
            output_count <= 0;
            stream_failures <= 0;
        end else if (context_valid && context_ready) begin
            row_base = (output_count/32)*4;
            within_tile = output_count%32;
            feature_base = (within_tile/16)*4;
            expected_row = row_base + ((within_tile%16)/4);
            expected_col = feature_base + (within_tile%4);

            if (context_bf16 !== golden_mem[output_count]) begin
                $display("[FAIL] context[%0d] exp=%h got=%h fp32=%h",
                         output_count, golden_mem[output_count],
                         context_bf16, context_fp32_debug);
                stream_failures <= stream_failures + 1;
            end
            if ((context_row !== expected_row[2:0]) ||
                (context_col !== expected_col[2:0])) begin
                $display("[FAIL] metadata[%0d] exp=(%0d,%0d) got=(%0d,%0d)",
                         output_count, expected_row, expected_col,
                         context_row, context_col);
                stream_failures <= stream_failures + 1;
            end
            if (context_group_last !== (output_count == WORDS-1)) begin
                $display("[FAIL] group_last at output %0d", output_count);
                stream_failures <= stream_failures + 1;
            end
            output_count <= output_count + 1;
        end
    end

    task automatic send_score(
        input integer stream_index,
        input integer row_index,
        input integer col_index
    );
        begin
            @(negedge clk);
            score_bf16 = score_mem[stream_index];
            score_head = '0;
            score_row = row_index[2:0];
            score_col = col_index[2:0];
            score_global_last = (stream_index == WORDS-1);
            score_valid = 1'b1;
            do begin
                @(posedge clk);
            end while (!score_ready);
            @(negedge clk);
            score_valid = 1'b0;
        end
    endtask

    initial begin : TEST
        integer row_base;
        integer col_base;
        integer lr;
        integer lc;
        integer stream_index;
        integer final_failures;

`ifdef V30_XSIM
        $readmemh("v30_online_scores_s8.hex", score_mem);
        $readmemh("v30_online_v_s8.hex", value_mem);
        $readmemh("v30_online_context_s8.hex", golden_mem);
`else
        $readmemh("tests/data/v30_online_scores_s8.hex", score_mem);
        $readmemh("tests/data/v30_online_v_s8.hex", value_mem);
        $readmemh("tests/data/v30_online_context_s8.hex", golden_mem);
`endif

        rst_n = 1'b0;
        start = 1'b0;
        score_valid = 1'b0;
        score_bf16 = '0;
        score_head = '0;
        score_row = '0;
        score_col = '0;
        score_global_last = 1'b0;
        repeat (8) @(negedge clk);
        rst_n = 1'b1;
        repeat (3) @(negedge clk);

        while (!start_ready) @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        stream_index = 0;
        for (row_base = 0; row_base < SEQ; row_base += TILE)
            for (col_base = 0; col_base < SEQ; col_base += TILE)
                for (lr = 0; lr < TILE; lr += 1)
                    for (lc = 0; lc < TILE; lc += 1) begin
                        send_score(stream_index, row_base+lr, col_base+lc);
                        stream_index += 1;
                    end

        fork
            begin
                wait(done);
            end
            begin
                repeat (200000) @(posedge clk);
                $fatal(1, "[FAIL] timeout state=%0d outputs=%0d", dut.state,
                       output_count);
            end
        join_any
        disable fork;

        final_failures = stream_failures;
        if (output_count != WORDS) begin
            $display("[FAIL] output count exp=%0d got=%0d", WORDS, output_count);
            final_failures = final_failures + 1;
        end
        if (online_tiles_processed != 3 || online_tiles_skipped != 1) begin
            $display("[FAIL] tile counters processed=%0d skipped=%0d",
                     online_tiles_processed, online_tiles_skipped);
            final_failures = final_failures + 1;
        end
        if (online_v_vectors_read != 24 || online_mac_terms != 288) begin
            $display("[FAIL] fused counters vreads=%0d mac_terms=%0d",
                     online_v_vectors_read, online_mac_terms);
            final_failures = final_failures + 1;
        end
        if (online_rescale_events == 0) begin
            $display("[FAIL] rescale path was not exercised");
            final_failures = final_failures + 1;
        end
        if (order_error || numeric_error) begin
            $display("[FAIL] error flags order=%0b numeric=%0b",
                     order_error, numeric_error);
            final_failures = final_failures + 1;
        end

        if (final_failures == 0) begin
            integer pass_fd;
            $display("[PASS] V3.0 ONLINE SOFTMAX + STREAMING CONTEXT");
            pass_fd = $fopen("v30_xsim_pass.txt", "w");
            if (pass_fd != 0) begin
                $fdisplay(pass_fd,
                    "V3.0 ONLINE SOFTMAX + STREAMING CONTEXT: SIM_PASS");
                $fclose(pass_fd);
            end
        end else
            $fatal(1, "[FAIL] V3.0 regression failures=%0d", final_failures);
        $finish;
    end
endmodule
