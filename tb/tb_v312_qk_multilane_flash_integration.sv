`timescale 1ns/1ps

module tb_v312_qk_multilane_flash_integration #(
    parameter integer QK_LANES = 1
);
    localparam int TILE = 4;
    localparam int SEQ_LEN = 8;
    localparam int HEAD_DIM = 8;
    localparam int V_ADDR_W = $clog2(SEQ_LEN*HEAD_DIM);
    localparam int CONTEXT_ITEMS = SEQ_LEN*HEAD_DIM;
    localparam int SCORE_TILES = (SEQ_LEN/TILE)*(SEQ_LEN/TILE);
    localparam int COMPUTED_TILES = SCORE_TILES;
    localparam int SKIPPED_TILES = 0;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic clear = 1'b0;
    logic group_start = 1'b0;
    logic group_start_ready;
    logic vec_ready;
    logic vec_valid;
    logic [2:0] req_row_base;
    logic [2:0] req_col_base;
    logic [2:0] req_dim;
    logic v_load_valid = 1'b0;
    logic v_load_ready;
    logic [V_ADDR_W-1:0] v_load_addr = '0;
    logic [127:0] v_load_data = {8{16'h3F80}};
    logic context_valid;
    logic context_ready;
    logic [15:0] context_bf16;
    logic [2:0] context_row;
    logic [2:0] context_col;
    logic context_last;
    logic busy;
    logic group_done;
    logic [31:0] qk_tiles_computed;
    logic [31:0] qk_tiles_skipped;
    logic [31:0] masked_tiles_emitted;
    logic [31:0] score_tiles_enqueued;
    logic [31:0] score_tiles_dequeued;
    logic [31:0] softmax_tiles_processed;
    logic [31:0] context_tiles_processed;
    logic [31:0] v_vectors_read;
    logic protocol_error;
    logic [31:0] lfsr = 32'hA341316C;
    integer load_addr;
    integer outputs = 0;
    integer cycles = 0;
    integer vector_requests = 0;

    always #5 clk = ~clk;
    always_comb begin
        vec_valid = lfsr[0] || lfsr[7];
        context_ready = lfsr[13] || lfsr[23];
    end

    qk_flash_attention_pipeline_top #(
        .TILE(TILE), .QK_LANES(QK_LANES),
        .CAUSAL_QK_TILE_SKIP(1'b1), .V_LANES(8),
        .FIFO_DEPTH_TILES(3), .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM), .Q_HEADS(1), .GQA_GROUPS(1),
        .SCALE_FP32(32'h3E000000),
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (
        .clk, .rst_n, .clear,
        .group_start, .group_id(1'b0), .group_start_ready,
        .active_group_id(), .causal_en(1'b0),
        .vec_ready, .vec_valid,
        .q_vec_bf16({TILE{16'h3F80}}),
        .k_vec_bf16({TILE{16'h3F80}}),
        .req_head(), .req_group_id(), .req_global_q_head(), .req_kv_head(),
        .req_row_base, .req_col_base, .req_dim,
        .v_load_valid, .v_load_ready, .v_load_addr, .v_load_data,
        .context_valid, .context_ready, .context_bf16,
        .context_fp32_debug(), .context_group(), .context_head(),
        .context_global_head(), .context_row, .context_col, .context_last,
        .qk_busy(), .qk_done(), .consumer_busy(), .busy, .group_done,
        .qk_tiles_computed, .qk_tiles_skipped, .masked_tiles_emitted,
        .score_tiles_enqueued, .score_tiles_dequeued,
        .softmax_tiles_processed, .context_tiles_processed,
        .v_vectors_read, .causal_skip_error(),
        .start_while_busy_error(), .invalid_group_id_error(),
        .consumer_protocol_error(), .protocol_error
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= 32'hA341316C;
            outputs <= 0;
            cycles <= 0;
            vector_requests <= 0;
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            cycles <= cycles + 1;
            if (vec_valid && vec_ready) begin
                if (($unsigned(req_row_base) >= SEQ_LEN) ||
                    ($unsigned(req_col_base) >= SEQ_LEN) ||
                    ($unsigned(req_dim) >= HEAD_DIM))
                    $fatal(1, "lane%0d invalid QK request", QK_LANES);
                vector_requests <= vector_requests + 1;
            end
            if (context_valid && context_ready) begin
                if (context_bf16 !== 16'h3F80)
                    $fatal(1, "lane%0d context[%0d] expected 1.0 got %h",
                           QK_LANES, outputs, context_bf16);
                if ((context_row !== outputs/HEAD_DIM) ||
                    (context_col !== outputs%HEAD_DIM))
                    $fatal(1, "lane%0d context order mismatch at %0d",
                           QK_LANES, outputs);
                if (context_last !== (outputs == CONTEXT_ITEMS-1))
                    $fatal(1, "lane%0d context_last mismatch at %0d",
                           QK_LANES, outputs);
                outputs <= outputs + 1;
            end
            if (protocol_error)
                $fatal(1, "lane%0d Flash pipeline protocol_error", QK_LANES);
            if (cycles > 500000)
                $fatal(1, "lane%0d Flash integration timeout", QK_LANES);
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        for (load_addr = 0; load_addr < SEQ_LEN*HEAD_DIM;
             load_addr = load_addr + 8) begin
            @(posedge clk);
            v_load_valid <= 1'b1;
            v_load_addr <= load_addr[V_ADDR_W-1:0];
            do @(posedge clk); while (!v_load_ready);
            v_load_valid <= 1'b0;
        end
        do @(posedge clk); while (!group_start_ready);
        group_start <= 1'b1;
        @(posedge clk);
        group_start <= 1'b0;
        wait (group_done);
        wait (outputs == CONTEXT_ITEMS);
        #1;
        if (vector_requests != COMPUTED_TILES*HEAD_DIM)
            $fatal(1, "lane%0d requests=%0d expected=%0d", QK_LANES,
                   vector_requests, COMPUTED_TILES*HEAD_DIM);
        if ((qk_tiles_computed != COMPUTED_TILES) ||
            (qk_tiles_skipped != SKIPPED_TILES) ||
            (masked_tiles_emitted != SKIPPED_TILES))
            $fatal(1, "lane%0d QK counters %0d/%0d/%0d", QK_LANES,
                   qk_tiles_computed, qk_tiles_skipped, masked_tiles_emitted);
        if ((score_tiles_enqueued != SCORE_TILES) ||
            (score_tiles_dequeued != SCORE_TILES) ||
            (softmax_tiles_processed != SCORE_TILES) ||
            (context_tiles_processed != SCORE_TILES))
            $fatal(1, "lane%0d tile pipeline counters %0d/%0d/%0d/%0d",
                   QK_LANES, score_tiles_enqueued, score_tiles_dequeued,
                   softmax_tiles_processed, context_tiles_processed);
        if (v_vectors_read != SCORE_TILES*TILE*HEAD_DIM/8)
            $fatal(1, "lane%0d V reads=%0d expected=%0d", QK_LANES,
                   v_vectors_read, SCORE_TILES*TILE*HEAD_DIM/8);
        $display("QK_MULTILANE_FLASH_INTEGRATION_TEST: PASS lanes=%0d contexts=%0d cycles=%0d",
                 QK_LANES, outputs, cycles);
        $finish;
    end
endmodule

module tb_v312_qk_multilane_flash_lanes1;
    tb_v312_qk_multilane_flash_integration #(.QK_LANES(1)) test();
endmodule

module tb_v312_qk_multilane_flash_lanes2;
    tb_v312_qk_multilane_flash_integration #(.QK_LANES(2)) test();
endmodule

module tb_v312_qk_multilane_flash_lanes4;
    tb_v312_qk_multilane_flash_integration #(.QK_LANES(4)) test();
endmodule

module tb_v312_qk_multilane_flash_lanes8;
    tb_v312_qk_multilane_flash_integration #(.QK_LANES(8)) test();
endmodule
