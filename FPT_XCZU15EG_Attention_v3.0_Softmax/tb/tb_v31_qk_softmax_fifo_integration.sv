`timescale 1ns/1ps

module tb_v31_qk_softmax_fifo_integration;
    localparam int TILE       = 4;
    localparam int SEQ_LEN    = 8;
    localparam int HEAD_DIM   = 4;
    localparam int Q_HEADS    = 2;
    localparam int GQA_GROUPS = 2;
    localparam int FIFO_DEPTH = 3;
    localparam int HEAD_W     = $clog2(Q_HEADS);
    localparam int GROUP_W    = $clog2(GQA_GROUPS);
    localparam int POS_W      = $clog2(SEQ_LEN);
    localparam int DIM_W      = $clog2(HEAD_DIM);
    localparam int TOTAL_TILES = Q_HEADS*(SEQ_LEN/TILE)*(SEQ_LEN/TILE);

    logic clk;
    logic rst_n;
    logic group_start;
    logic [GROUP_W-1:0] group_id;
    logic group_start_ready;
    logic [GROUP_W-1:0] active_group_id;
    logic causal_en;
    logic vec_ready;
    logic vec_valid;
    logic [TILE*16-1:0] q_vec_bf16;
    logic [TILE*16-1:0] k_vec_bf16;
    logic [HEAD_W-1:0] req_head;
    logic [GROUP_W-1:0] req_group_id;
    logic [1:0] req_global_q_head;
    logic [GROUP_W-1:0] req_kv_head;
    logic [POS_W-1:0] req_row_base;
    logic [POS_W-1:0] req_col_base;
    logic [DIM_W-1:0] req_dim;
    logic prob_valid;
    logic prob_ready;
    logic [15:0] prob_data;
    logic [GROUP_W-1:0] prob_group_id;
    logic [HEAD_W-1:0] prob_head;
    logic [POS_W-1:0] prob_row;
    logic [POS_W-1:0] prob_col;
    logic prob_first;
    logic prob_last;
    logic prob_group_last;
    logic prob_global_last;
    logic qk_busy;
    logic qk_done;
    logic [31:0] qk_tiles_computed;
    logic [31:0] qk_tiles_skipped;
    logic [31:0] masked_tiles_emitted;
    logic causal_skip_error;
    logic frontend_busy;
    logic mask_adapter_busy;
    logic softmax_busy;
    logic pipeline_busy;
    logic group_done;
    logic pipeline_done;
    logic start_while_busy_error;
    logic invalid_group_id_error;
    logic adapter_protocol_error;
    logic adapter_global_last_error;
    logic softmax_row_error;
    logic softmax_metadata_error;

    integer failures;
    integer timeout_cycles;

    qk_softmax_pipeline_top #(
        .TILE(TILE),
        .QK_LANES(2),
        .CAUSAL_QK_TILE_SKIP(1'b1),
        .SCORE_FIFO_DEPTH(FIFO_DEPTH),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W),
        .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(2),
        .POS_W(POS_W),
        .DIM_W(DIM_W)
    ) dut (
        .clk,
        .rst_n,
        .group_start,
        .group_id,
        .group_start_ready,
        .active_group_id,
        .causal_en,
        .vec_ready,
        .vec_valid,
        .q_vec_bf16,
        .k_vec_bf16,
        .req_head,
        .req_group_id,
        .req_global_q_head,
        .req_kv_head,
        .req_row_base,
        .req_col_base,
        .req_dim,
        .prob_valid,
        .prob_ready,
        .prob_data,
        .prob_group_id,
        .prob_head,
        .prob_row,
        .prob_col,
        .prob_first,
        .prob_last,
        .prob_group_last,
        .prob_global_last,
        .qk_busy,
        .qk_done,
        .qk_tiles_computed,
        .qk_tiles_skipped,
        .masked_tiles_emitted,
        .causal_skip_error,
        .frontend_busy,
        .mask_adapter_busy,
        .softmax_busy,
        .pipeline_busy,
        .group_done,
        .pipeline_done,
        .start_while_busy_error,
        .invalid_group_id_error,
        .adapter_protocol_error,
        .adapter_global_last_error,
        .softmax_row_error,
        .softmax_metadata_error
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic launch_group(input integer requested_group);
        begin
            while (!group_start_ready)
                @(posedge clk);
            @(negedge clk);
            group_id = requested_group[GROUP_W-1:0];
            group_start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            group_start = 1'b0;
        end
    endtask

    task automatic wait_for_group_done(input integer requested_group);
        begin
            timeout_cycles = 0;
            while (!group_done && timeout_cycles < 5000) begin
                @(posedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (!group_done) begin
                $error("Timeout waiting for group %0d", requested_group);
                failures = failures + 1;
            end

            if (active_group_id != requested_group[GROUP_W-1:0] ||
                prob_group_id != requested_group[GROUP_W-1:0] ||
                !prob_group_last || !prob_global_last) begin
                $error("Final group metadata mismatch for group %0d",
                       requested_group);
                failures = failures + 1;
            end

            @(posedge clk);
            if (dut.score_fifo_busy || dut.score_fifo_occupancy != 0 ||
                dut.score_fifo_tiles_enqueued != TOTAL_TILES ||
                dut.score_fifo_tiles_dequeued != TOTAL_TILES) begin
                $error("FIFO group boundary mismatch: busy=%0b occ=%0d enq=%0d deq=%0d",
                       dut.score_fifo_busy,
                       dut.score_fifo_occupancy,
                       dut.score_fifo_tiles_enqueued,
                       dut.score_fifo_tiles_dequeued);
                failures = failures + 1;
            end
        end
    endtask

    initial begin
        integer pass_fd;
        rst_n = 1'b0;
        group_start = 1'b0;
        group_id = '0;
        causal_en = 1'b1;
        vec_valid = 1'b0;
        q_vec_bf16 = '0;
        k_vec_bf16 = '0;
        prob_ready = 1'b1;
        failures = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        launch_group(0);
        wait_for_group_done(0);

        if (dut.score_fifo_max_occupancy != FIFO_DEPTH ||
            dut.score_fifo_backpressure_cycles == 0) begin
            $error("First group did not exercise full FIFO backpressure");
            failures = failures + 1;
        end

        // A second launch proves status_clear resets per-group accounting while
        // FIFO pointers continue to operate without a global reset.
        launch_group(1);
        wait_for_group_done(1);

        if (start_while_busy_error || invalid_group_id_error ||
            adapter_protocol_error || adapter_global_last_error ||
            softmax_row_error || softmax_metadata_error ||
            causal_skip_error) begin
            $error("Pipeline exposed an unexpected sticky error");
            failures = failures + 1;
        end

        if (failures == 0) begin
            $display("V31_QK_SOFTMAX_FIFO_INTEGRATION_TEST: PASS");
            pass_fd = $fopen("v31_qk_softmax_fifo_integration_pass.txt", "w");
            if (pass_fd != 0) begin
                $fdisplay(pass_fd,
                    "V3.1 QK -> FIFO -> Softmax integration: PASS");
                $fclose(pass_fd);
            end
        end else begin
            $fatal(1,
                "V31_QK_SOFTMAX_FIFO_INTEGRATION_TEST: FAIL count=%0d",
                failures);
        end
        $finish;
    end
endmodule

// Deterministic QK model for the active QK_LANES=2 generate branch. It emits
// the exact tile-major coordinate order required by the production adapter.
module qk_parallel_systolic_gqa_top #(
    parameter int TILE       = 4,
    parameter int QK_LANES   = 2,
    parameter int SEQ_LEN    = 8,
    parameter int HEAD_DIM   = 4,
    parameter int Q_HEADS    = 2,
    parameter bit CAUSAL_TILE_SKIP = 1'b1,
    parameter logic [15:0] MASK_BF16 = 16'hFF80,
    parameter logic [31:0] SCALE_FP32 = 32'h3DB504F3
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic causal_en,
    output logic busy,
    output logic done,
    output logic vec_ready,
    input  logic vec_valid,
    input  logic [TILE*16-1:0] q_vec_bf16,
    input  logic [TILE*16-1:0] k_vec_bf16,
    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] req_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] req_row_base,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] req_col_base,
    output logic [((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM))-1:0] req_dim,
    output logic score_valid,
    input  logic score_ready,
    output logic [15:0] score_bf16,
    output logic [31:0] score_fp32_debug,
    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] score_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] score_row,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] score_col,
    output logic score_last,
    output logic [31:0] qk_tiles_computed,
    output logic [31:0] qk_tiles_skipped,
    output logic [31:0] masked_tiles_emitted,
    output logic causal_skip_error
);
    localparam int ITEMS = TILE*TILE;
    localparam int TILES_PER_DIM = SEQ_LEN/TILE;
    localparam int TOTAL_TILES = Q_HEADS*TILES_PER_DIM*TILES_PER_DIM;
    localparam int TOTAL_ITEMS = TOTAL_TILES*ITEMS;

    logic [31:0] emit_index;
    integer tile_index;
    integer tile_in_head;
    integer local_index;

    always_comb begin
        tile_index = $unsigned(emit_index) / ITEMS;
        tile_in_head = tile_index % (TILES_PER_DIM*TILES_PER_DIM);
        local_index = $unsigned(emit_index) % ITEMS;

        score_valid = busy;
        score_bf16 = 16'h3000 + emit_index[15:0];
        score_fp32_debug = {score_bf16, 16'h0000};
        score_head = tile_index / (TILES_PER_DIM*TILES_PER_DIM);
        score_row = ((tile_in_head / TILES_PER_DIM)*TILE) +
                    (local_index / TILE);
        score_col = ((tile_in_head % TILES_PER_DIM)*TILE) +
                    (local_index % TILE);
        score_last = busy && ($unsigned(emit_index) == TOTAL_ITEMS-1);

        vec_ready = 1'b0;
        req_head = '0;
        req_row_base = '0;
        req_col_base = '0;
        req_dim = '0;
        qk_tiles_computed = TOTAL_TILES;
        qk_tiles_skipped = '0;
        masked_tiles_emitted = '0;
        causal_skip_error = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            emit_index <= '0;
        end else begin
            done <= 1'b0;
            if (start && !busy) begin
                busy <= 1'b1;
                emit_index <= '0;
            end else if (score_valid && score_ready) begin
                if ($unsigned(emit_index) == TOTAL_ITEMS-1) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    emit_index <= emit_index + 1'b1;
                end
            end
        end
    end

    wire unused_inputs = &{1'b0, causal_en, vec_valid, q_vec_bf16,
                           k_vec_bf16, QK_LANES[0], CAUSAL_TILE_SKIP,
                           MASK_BF16, SCALE_FP32};
endmodule

// Inactive legacy branch model, included so every simulator can resolve both
// generate alternatives during parsing.
module qk_systolic_gqa_top #(
    parameter int TILE = 4,
    parameter int SEQ_LEN = 8,
    parameter int HEAD_DIM = 4,
    parameter int Q_HEADS = 2,
    parameter logic [31:0] SCALE_FP32 = 32'h3DB504F3
) (
    input logic clk, input logic rst_n, input logic start,
    output logic busy, output logic done,
    output logic vec_ready, input logic vec_valid,
    input logic [TILE*16-1:0] q_vec_bf16,
    input logic [TILE*16-1:0] k_vec_bf16,
    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] req_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] req_row_base,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] req_col_base,
    output logic [((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM))-1:0] req_dim,
    output logic score_valid, input logic score_ready,
    output logic [15:0] score_bf16,
    output logic [31:0] score_fp32_debug,
    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] score_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] score_row,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] score_col,
    output logic score_last
);
    always_comb begin
        busy = 1'b0;
        done = 1'b0;
        vec_ready = 1'b0;
        req_head = '0;
        req_row_base = '0;
        req_col_base = '0;
        req_dim = '0;
        score_valid = 1'b0;
        score_bf16 = '0;
        score_fp32_debug = '0;
        score_head = '0;
        score_row = '0;
        score_col = '0;
        score_last = 1'b0;
    end
    wire unused_inputs = &{1'b0, clk, rst_n, start, vec_valid,
                           q_vec_bf16, k_vec_bf16, score_ready,
                           SCALE_FP32};
endmodule

// Frontend model checks every FIFO output item, creates deliberate downstream
// stalls, and emits one final probability beat after the complete score stream.
module qk_softmax_frontend #(
    parameter int SEQ_LEN = 8,
    parameter int TILE = 4,
    parameter int Q_HEADS = 2,
    parameter int HEAD_W = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int POS_W = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter EXP_LUT_FILE = "exp_lut_q15.mem"
) (
    input logic clk, input logic rst_n, input logic causal_en,
    input logic qk_valid, output logic qk_ready,
    input logic [15:0] qk_score,
    input logic [HEAD_W-1:0] qk_head,
    input logic [POS_W-1:0] qk_row,
    input logic [POS_W-1:0] qk_col,
    input logic qk_global_last,
    output logic prob_valid, input logic prob_ready,
    output logic [15:0] prob_data,
    output logic prob_first, output logic prob_last,
    output logic prob_group_last, output logic prob_global_last,
    output logic [HEAD_W-1:0] prob_head,
    output logic [POS_W-1:0] prob_row,
    output logic [POS_W-1:0] prob_col,
    output logic group_done, output logic pipeline_done,
    output logic busy, output logic adapter_busy,
    output logic softmax_busy,
    output logic adapter_protocol_error,
    output logic adapter_global_last_error,
    output logic softmax_row_error,
    output logic softmax_metadata_error
);
    localparam int ITEMS = TILE*TILE;
    localparam int TILES_PER_DIM = SEQ_LEN/TILE;
    localparam int TOTAL_TILES = Q_HEADS*TILES_PER_DIM*TILES_PER_DIM;
    localparam int TOTAL_ITEMS = TOTAL_TILES*ITEMS;

    typedef enum logic {S_SCORE, S_PROB} state_t;
    state_t state;
    logic active;
    logic [31:0] consume_index;
    logic [31:0] cycle_count;
    integer tile_index;
    integer tile_in_head;
    integer local_index;
    integer expected_head;
    integer expected_row;
    integer expected_col;

    always_comb begin
        tile_index = $unsigned(consume_index) / ITEMS;
        tile_in_head = tile_index % (TILES_PER_DIM*TILES_PER_DIM);
        local_index = $unsigned(consume_index) % ITEMS;
        expected_head = tile_index / (TILES_PER_DIM*TILES_PER_DIM);
        expected_row = ((tile_in_head / TILES_PER_DIM)*TILE) +
                       (local_index / TILE);
        expected_col = ((tile_in_head % TILES_PER_DIM)*TILE) +
                       (local_index % TILE);

        // Hold the consumer for 100 cycles so the depth-3 FIFO must fill,
        // then keep periodic stalls active for payload-stability coverage.
        qk_ready = (state == S_SCORE) && (cycle_count > 100) &&
                   (cycle_count[2:0] != 3'b001);

        prob_valid = (state == S_PROB);
        prob_data = 16'h3F80;
        prob_first = prob_valid;
        prob_last = prob_valid;
        prob_group_last = prob_valid;
        prob_global_last = prob_valid;
        prob_head = Q_HEADS-1;
        prob_row = SEQ_LEN-1;
        prob_col = SEQ_LEN-1;
        group_done = prob_valid && prob_ready;
        pipeline_done = group_done;
        busy = active || qk_valid || prob_valid;
        adapter_busy = active && (state == S_SCORE);
        softmax_busy = active && (state == S_PROB);
        softmax_row_error = 1'b0;
        softmax_metadata_error = 1'b0;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_SCORE;
            active <= 1'b0;
            consume_index <= '0;
            cycle_count <= '0;
            adapter_protocol_error <= 1'b0;
            adapter_global_last_error <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1'b1;

            if (qk_valid)
                active <= 1'b1;

            if (qk_valid && qk_ready) begin
                if ((qk_score !== (16'h3000 + consume_index[15:0])) ||
                    ($unsigned(qk_head) != expected_head) ||
                    ($unsigned(qk_row) != expected_row) ||
                    ($unsigned(qk_col) != expected_col))
                    adapter_protocol_error <= 1'b1;

                if (qk_global_last !==
                    ($unsigned(consume_index) == TOTAL_ITEMS-1))
                    adapter_global_last_error <= 1'b1;

                if ($unsigned(consume_index) == TOTAL_ITEMS-1) begin
                    state <= S_PROB;
                end else begin
                    consume_index <= consume_index + 1'b1;
                end
            end

            if (prob_valid && prob_ready) begin
                state <= S_SCORE;
                active <= 1'b0;
                consume_index <= '0;
            end
        end
    end

    wire unused_inputs = &{1'b0, causal_en, EXP_LUT_FILE[0]};
endmodule
