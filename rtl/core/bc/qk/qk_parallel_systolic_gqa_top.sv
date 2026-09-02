`timescale 1ns/1ps

// Parameterized 1/2/4/8-way QK tile scheduler.
//
// Adjacent column tiles are computed together.  A single registered Q/K-cache
// read channel is shared between the lanes; requests are interleaved while the
// floating-point PEs are busy.  Results are merged back into the exact legacy
// order:
//   head -> row tile -> column tile -> local row -> local column.
//
// When causal_en and CAUSAL_TILE_SKIP are both asserted, a tile whose aligned
// column base is greater than its row base is wholly above the causal diagonal.
// No Q/K vector is requested for that tile.  Sixteen masked scores are emitted
// instead so the downstream Row Buffer still observes a dense coordinate
// stream and the Softmax numerical contract is unchanged.
module qk_parallel_systolic_gqa_top #(
    parameter int TILE       = 4,
    parameter int QK_LANES   = 2,
    parameter int SEQ_LEN    = 128,
    parameter int HEAD_DIM   = 128,
    parameter int Q_HEADS    = 4,
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

    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0]
        req_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0]
        req_row_base,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0]
        req_col_base,
    output logic [((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM))-1:0]
        req_dim,

    output logic score_valid,
    input  logic score_ready,
    output logic [15:0] score_bf16,
    output logic [31:0] score_fp32_debug,
    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0]
        score_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0]
        score_row,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0]
        score_col,
    output logic score_last,

    output logic [31:0] qk_tiles_computed,
    output logic [31:0] qk_tiles_skipped,
    output logic [31:0] masked_tiles_emitted,
    output logic causal_skip_error
);
    localparam int HEAD_W = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS);
    localparam int POS_W  = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN);
    localparam int DIM_W  = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM);
    localparam int LOC_W  = (TILE <= 1) ? 1 : $clog2(TILE);
    localparam int LANE_W = (QK_LANES <= 1) ? 1 : $clog2(QK_LANES);
    localparam int LANE_COUNT_W = $clog2(QK_LANES + 1);
    localparam int PAIR_SPAN = QK_LANES*TILE;
    localparam int RESULT_N = TILE*TILE;
    localparam int RESULT_W = (RESULT_N <= 1) ? 1 : $clog2(RESULT_N);

    typedef enum logic [1:0] {
        S_IDLE  = 2'd0,
        S_START = 2'd1,
        S_RUN   = 2'd2
    } state_t;

    state_t state;
    logic [HEAD_W-1:0] head_reg;
    logic [POS_W-1:0] row_base_reg;
    logic [POS_W-1:0] pair_col_base_reg;

    logic [QK_LANES-1:0] tile_start;
    logic [QK_LANES-1:0] tile_in_ready;
    logic [QK_LANES-1:0] tile_out_valid;
    logic [QK_LANES-1:0] tile_out_ready;
    logic [QK_LANES-1:0] tile_out_last;
    logic [15:0] tile_out_score [0:QK_LANES-1];
    logic [31:0] tile_out_fp32 [0:QK_LANES-1];
    logic [LOC_W-1:0] tile_out_row [0:QK_LANES-1];
    logic [LOC_W-1:0] tile_out_col [0:QK_LANES-1];
    logic [DIM_W-1:0] lane_feed_count [0:QK_LANES-1];

    logic [QK_LANES-1:0] lane_active;
    logic [QK_LANES-1:0] lane_skip;
    logic [QK_LANES-1:0] lane_needs_vector;

    logic request_pending;
    logic [LANE_W-1:0] request_owner;
    logic [LANE_W-1:0] arb_lane;
    logic arb_valid;
    logic [LANE_W-1:0] round_robin_lane;
    logic [LANE_W-1:0] data_owner;

    logic [LANE_W-1:0] emit_lane;
    logic [RESULT_W-1:0] skip_result_index [0:QK_LANES-1];
    logic [LOC_W-1:0] selected_local_row;
    logic [LOC_W-1:0] selected_local_col;
    logic selected_last;
    logic selected_skip;
    logic [LANE_COUNT_W-1:0] start_compute_count;
    logic [LANE_COUNT_W-1:0] start_skip_count;

    integer comb_lane;
    integer seq_lane;
    integer scan;
    integer scan_index;

    always_comb begin
        start_compute_count = '0;
        start_skip_count = '0;
        for (comb_lane = 0; comb_lane < QK_LANES;
             comb_lane = comb_lane + 1) begin
            lane_active[comb_lane] =
                ($unsigned(pair_col_base_reg) + comb_lane*TILE) < SEQ_LEN;
            lane_skip[comb_lane] =
                lane_active[comb_lane] &&
                CAUSAL_TILE_SKIP &&
                causal_en &&
                (($unsigned(pair_col_base_reg) + comb_lane*TILE) >
                 $unsigned(row_base_reg));
            lane_needs_vector[comb_lane] =
                (state == S_RUN) &&
                lane_active[comb_lane] &&
                !lane_skip[comb_lane] &&
                tile_in_ready[comb_lane] &&
                ($unsigned(lane_feed_count[comb_lane]) < HEAD_DIM);
            if (lane_active[comb_lane]) begin
                if (lane_skip[comb_lane])
                    start_skip_count = start_skip_count + 1'b1;
                else
                    start_compute_count = start_compute_count + 1'b1;
            end
        end
    end

    // Round-robin arbitration keeps one cache request outstanding at a time.
    always_comb begin
        arb_lane = '0;
        arb_valid = 1'b0;
        for (scan = 0; scan < QK_LANES; scan = scan + 1) begin
            scan_index = ($unsigned(round_robin_lane) + scan) % QK_LANES;
            if (!arb_valid && lane_needs_vector[scan_index]) begin
                arb_lane = scan_index[LANE_W-1:0];
                arb_valid = 1'b1;
            end
        end
    end

    assign data_owner = request_pending ? request_owner : arb_lane;
    assign vec_ready =
        (state == S_RUN) &&
        (request_pending ?
            tile_in_ready[request_owner] :
            (arb_valid && tile_in_ready[arb_lane]));

    assign req_head = head_reg;
    assign req_row_base = row_base_reg;
    assign req_col_base =
        pair_col_base_reg + $unsigned(data_owner)*TILE;
    assign req_dim = lane_feed_count[data_owner];

    genvar g;
    generate
        for (g = 0; g < QK_LANES; g = g + 1) begin : GEN_QK_LANE
            logic unused_tile_busy;
            logic unused_tile_done;

            qk_systolic_tile #(
                .TILE(TILE),
                .HEAD_DIM(HEAD_DIM),
                .SCALE_FP32(SCALE_FP32)
            ) u_tile (
                .clk(clk),
                .rst_n(rst_n),
                .tile_start(tile_start[g]),
                .tile_busy(unused_tile_busy),
                .tile_done(unused_tile_done),
                .in_valid(
                    (state == S_RUN) &&
                    vec_valid &&
                    vec_ready &&
                    ($unsigned(data_owner) == g)
                ),
                .in_ready(tile_in_ready[g]),
                .q_rows_bf16(q_vec_bf16),
                .k_cols_bf16(k_vec_bf16),
                .out_valid(tile_out_valid[g]),
                .out_ready(tile_out_ready[g]),
                .out_score_bf16(tile_out_score[g]),
                .out_local_row(tile_out_row[g]),
                .out_local_col(tile_out_col[g]),
                .out_last(tile_out_last[g]),
                .out_score_fp32_debug(tile_out_fp32[g])
            );
        end
    endgenerate

    always_comb begin
        selected_skip = lane_skip[emit_lane];
        if (selected_skip) begin
            selected_local_row = skip_result_index[emit_lane] / TILE;
            selected_local_col = skip_result_index[emit_lane] % TILE;
            selected_last =
                (skip_result_index[emit_lane] == RESULT_N-1);
            score_valid = (state == S_RUN) && lane_active[emit_lane];
            score_bf16 = MASK_BF16;
            score_fp32_debug = 32'hFF80_0000;
        end else begin
            selected_local_row = tile_out_row[emit_lane];
            selected_local_col = tile_out_col[emit_lane];
            selected_last = tile_out_last[emit_lane];
            score_valid =
                (state == S_RUN) &&
                lane_active[emit_lane] &&
                tile_out_valid[emit_lane];
            score_bf16 = tile_out_score[emit_lane];
            score_fp32_debug = tile_out_fp32[emit_lane];
        end

        score_head = head_reg;
        score_row = row_base_reg + selected_local_row;
        score_col = pair_col_base_reg +
                    $unsigned(emit_lane)*TILE +
                    selected_local_col;
        score_last =
            (head_reg == Q_HEADS-1) &&
            (score_row == SEQ_LEN-1) &&
            (score_col == SEQ_LEN-1);

        tile_out_ready = '0;
        if ((state == S_RUN) && !selected_skip &&
            lane_active[emit_lane])
            tile_out_ready[emit_lane] = score_ready;
    end

    assign busy = (state != S_IDLE);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done <= 1'b0;
            head_reg <= '0;
            row_base_reg <= '0;
            pair_col_base_reg <= '0;
            tile_start <= '0;
            request_pending <= 1'b0;
            request_owner <= '0;
            round_robin_lane <= '0;
            emit_lane <= '0;
            qk_tiles_computed <= '0;
            qk_tiles_skipped <= '0;
            masked_tiles_emitted <= '0;
            causal_skip_error <= 1'b0;
            for (seq_lane = 0; seq_lane < QK_LANES;
                 seq_lane = seq_lane + 1) begin
                lane_feed_count[seq_lane] <= '0;
                skip_result_index[seq_lane] <= '0;
            end
        end else begin
            done <= 1'b0;
            tile_start <= '0;

            case (state)
                S_IDLE: begin
                    request_pending <= 1'b0;
                    if (start) begin
                        head_reg <= '0;
                        row_base_reg <= '0;
                        pair_col_base_reg <= '0;
                        emit_lane <= '0;
                        round_robin_lane <= '0;
                        qk_tiles_computed <= '0;
                        qk_tiles_skipped <= '0;
                        masked_tiles_emitted <= '0;
                        causal_skip_error <= 1'b0;
                        state <= S_START;
                    end
                end

                S_START: begin
                    request_pending <= 1'b0;
                    emit_lane <= '0;
                    qk_tiles_computed <=
                        qk_tiles_computed + start_compute_count;
                    qk_tiles_skipped <=
                        qk_tiles_skipped + start_skip_count;
                    for (seq_lane = 0; seq_lane < QK_LANES;
                         seq_lane = seq_lane + 1) begin
                        lane_feed_count[seq_lane] <= '0;
                        skip_result_index[seq_lane] <= '0;
                        if (lane_active[seq_lane]) begin
                            if (!lane_skip[seq_lane]) begin
                                tile_start[seq_lane] <= 1'b1;
                            end
                        end
                    end
                    state <= S_RUN;
                end

                S_RUN: begin
                    if (request_pending) begin
                        if (lane_skip[request_owner])
                            causal_skip_error <= 1'b1;
                        if (vec_valid && vec_ready) begin
                            lane_feed_count[request_owner] <=
                                lane_feed_count[request_owner] + 1'b1;
                            request_pending <= 1'b0;
                            round_robin_lane <=
                                (request_owner == QK_LANES-1) ?
                                '0 : request_owner + 1'b1;
                        end
                    end else if (arb_valid) begin
                        if (vec_valid && vec_ready) begin
                            lane_feed_count[arb_lane] <=
                                lane_feed_count[arb_lane] + 1'b1;
                            round_robin_lane <=
                                (arb_lane == QK_LANES-1) ?
                                '0 : arb_lane + 1'b1;
                        end else begin
                            request_pending <= 1'b1;
                            request_owner <= arb_lane;
                        end
                    end

                    if (selected_skip && score_valid && score_ready) begin
                        if (($unsigned(score_col) <= $unsigned(score_row)) ||
                            !causal_en)
                            causal_skip_error <= 1'b1;
                        if (!selected_last)
                            skip_result_index[emit_lane] <=
                                skip_result_index[emit_lane] + 1'b1;
                    end

                    if (score_valid && score_ready && selected_last) begin
                        if (selected_skip)
                            masked_tiles_emitted <=
                                masked_tiles_emitted + 1'b1;

                        if (($unsigned(emit_lane) + 1 < QK_LANES) &&
                            lane_active[emit_lane + 1'b1]) begin
                            emit_lane <= emit_lane + 1'b1;
                        end else begin
                            request_pending <= 1'b0;
                            if ($unsigned(pair_col_base_reg) + PAIR_SPAN <
                                SEQ_LEN) begin
                                pair_col_base_reg <=
                                    pair_col_base_reg + PAIR_SPAN;
                                state <= S_START;
                            end else begin
                                pair_col_base_reg <= '0;
                                if ($unsigned(row_base_reg) + TILE <
                                    SEQ_LEN) begin
                                    row_base_reg <= row_base_reg + TILE;
                                    state <= S_START;
                                end else begin
                                    row_base_reg <= '0;
                                    if ($unsigned(head_reg) + 1 <
                                        Q_HEADS) begin
                                        head_reg <= head_reg + 1'b1;
                                        state <= S_START;
                                    end else begin
                                        done <= 1'b1;
                                        state <= S_IDLE;
                                    end
                                end
                            end
                        end
                    end
                end

                default: begin
                    causal_skip_error <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

    initial begin
        if (!((QK_LANES == 1) || (QK_LANES == 2) ||
              (QK_LANES == 4) || (QK_LANES == 8)))
            $error("qk_parallel_systolic_gqa_top: QK_LANES must be 1, 2, 4, or 8");
        if ((SEQ_LEN % TILE) != 0)
            $error("qk_parallel_systolic_gqa_top: TILE must divide SEQ_LEN");
    end
endmodule
