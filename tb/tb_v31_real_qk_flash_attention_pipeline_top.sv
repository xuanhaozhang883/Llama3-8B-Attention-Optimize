`timescale 1ns/1ps

module tb_v31_real_qk_flash_attention_pipeline_top;
    localparam int TILE=4;
    localparam int SEQ_LEN=8;
    localparam int HEAD_DIM=8;
    localparam int V_ADDR_W=$clog2(SEQ_LEN*HEAD_DIM);

    logic clk=1'b0;
    logic rst_n=1'b0;
    logic clear=1'b0;
    logic group_start=1'b0;
    logic group_start_ready;
    logic vec_ready;
    logic [0:0] req_head;
    logic [2:0] req_row_base;
    logic [2:0] req_col_base;
    logic [2:0] req_dim;
    logic v_load_valid=1'b0;
    logic v_load_ready;
    logic [V_ADDR_W-1:0] v_load_addr='0;
    logic [127:0] v_load_data={8{16'h3F80}};
    logic context_valid;
    logic context_ready;
    logic [15:0] context_bf16;
    logic [0:0] context_group;
    logic [0:0] context_head;
    logic [0:0] context_global_head;
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
    integer load_addr;
    integer outputs;
    integer cycles;
    integer vector_requests;

    always #5 clk=~clk;

    // Exercise output backpressure while keeping it deterministic.
    always_comb context_ready = (cycles[2:0] != 3'd3);

    qk_flash_attention_pipeline_top #(
        .TILE(TILE), .QK_LANES(2), .CAUSAL_QK_TILE_SKIP(1'b1),
        .V_LANES(8), .FIFO_DEPTH_TILES(2),
        .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(1), .GQA_GROUPS(1),
        .SCALE_FP32(32'h3E000000),
        .EXP_LUT_FILE("mem/exp_lut_q15.mem")
    ) dut (
        .clk, .rst_n, .clear,
        .group_start, .group_id(1'b0), .group_start_ready,
        .active_group_id(), .causal_en(1'b0),
        .vec_ready, .vec_valid(1'b1),
        .q_vec_bf16({TILE{16'h3F80}}),
        .k_vec_bf16({TILE{16'h3F80}}),
        .req_head, .req_group_id(), .req_global_q_head(), .req_kv_head(),
        .req_row_base, .req_col_base, .req_dim,
        .v_load_valid, .v_load_ready, .v_load_addr, .v_load_data,
        .context_valid, .context_ready, .context_bf16,
        .context_fp32_debug(), .context_group, .context_head,
        .context_global_head, .context_row, .context_col, .context_last,
        .qk_busy(), .qk_done(), .consumer_busy(), .busy, .group_done,
        .qk_tiles_computed, .qk_tiles_skipped, .masked_tiles_emitted,
        .score_tiles_enqueued, .score_tiles_dequeued,
        .softmax_tiles_processed, .context_tiles_processed,
        .v_vectors_read, .causal_tiles_bypassed(),
        .causal_bypass_error(), .causal_skip_error(),
        .start_while_busy_error(), .invalid_group_id_error(),
        .consumer_protocol_error(), .protocol_error
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            outputs <= 0;
            cycles <= 0;
            vector_requests <= 0;
        end else begin
            cycles <= cycles+1;
            if (vec_ready) begin
                if (req_head !== 0)
                    $fatal(1, "unexpected QK head");
                if (($unsigned(req_row_base) >= SEQ_LEN) ||
                    ($unsigned(req_col_base) >= SEQ_LEN) ||
                    ($unsigned(req_dim) >= HEAD_DIM))
                    $fatal(1, "invalid QK request coordinate");
                vector_requests <= vector_requests+1;
            end
            if (context_valid && context_ready) begin
                if (context_bf16 !== 16'h3F80)
                    $fatal(1, "context[%0d] expected 1.0 got %h",
                           outputs, context_bf16);
                if ((context_group !== 0) || (context_head !== 0) ||
                    (context_global_head !== 0))
                    $fatal(1, "context head metadata mismatch");
                if ((context_row !== outputs/HEAD_DIM) ||
                    (context_col !== outputs%HEAD_DIM))
                    $fatal(1, "context order mismatch at %0d", outputs);
                if (context_last !== (outputs == SEQ_LEN*HEAD_DIM-1))
                    $fatal(1, "context_last mismatch at %0d", outputs);
                outputs <= outputs+1;
            end
            if (protocol_error)
                $fatal(1, "real QK Flash pipeline protocol_error");
            if (cycles > 50000)
                $fatal(1, "real QK Flash pipeline timeout");
        end
    end

    initial begin
        repeat(4) @(posedge clk);
        rst_n <= 1'b1;

        for (load_addr=0; load_addr<SEQ_LEN*HEAD_DIM; load_addr=load_addr+8) begin
            @(posedge clk);
            v_load_valid <= 1'b1;
            v_load_addr <= load_addr[V_ADDR_W-1:0];
            do @(posedge clk); while(!v_load_ready);
            v_load_valid <= 1'b0;
        end

        do @(posedge clk); while(!group_start_ready);
        group_start <= 1'b1;
        @(posedge clk);
        group_start <= 1'b0;

        wait(group_done);
        wait(outputs == SEQ_LEN*HEAD_DIM);
        #1;
        if (vector_requests != 4*HEAD_DIM)
            $fatal(1, "QK vector requests expected %0d got %0d",
                   4*HEAD_DIM, vector_requests);
        if ((qk_tiles_computed != 4) || (qk_tiles_skipped != 0) ||
            (masked_tiles_emitted != 0))
            $fatal(1, "QK tile counters mismatch %0d/%0d/%0d",
                   qk_tiles_computed, qk_tiles_skipped, masked_tiles_emitted);
        if ((score_tiles_enqueued != 4) || (score_tiles_dequeued != 4) ||
            (softmax_tiles_processed != 4) || (context_tiles_processed != 4))
            $fatal(1, "Flash tile counters mismatch %0d/%0d/%0d/%0d",
                   score_tiles_enqueued, score_tiles_dequeued,
                   softmax_tiles_processed, context_tiles_processed);
        if (v_vectors_read != 4*TILE*HEAD_DIM/8)
            $fatal(1, "V vector reads expected %0d got %0d",
                   4*TILE*HEAD_DIM/8, v_vectors_read);
        $display("REAL_QK_FLASH_PIPELINE_TEST: PASS contexts=%0d cycles=%0d",
                 outputs, cycles);
        $finish;
    end
endmodule
