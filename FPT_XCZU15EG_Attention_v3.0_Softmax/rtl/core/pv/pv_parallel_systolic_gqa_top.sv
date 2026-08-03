`timescale 1ns/1ps

// Parallel TILE4 P x V scheduler with causal row-effective reduction.
//
// One P vector is broadcast to PV_LANES adjacent column tiles.  V contains
// PV_LANES independent TILE-wide vectors.  The arithmetic tiles advance in
// lockstep and their result streams are serialized back into the legacy
// tile-major order required by fpt_context_ddr_writer.
//
// With causal_en asserted, local row i only starts a MAC when
//   reduce <= row_base + i
// and receives its own last marker at reduce == row_base+i.  The shared input
// stream ends at row_base+TILE-1, so all reductions that are guaranteed to
// multiply a causal Softmax zero are removed.
module pv_parallel_systolic_gqa_top #(
    parameter int TILE       = 4,
    parameter int PV_LANES   = 2,
    parameter int QUERY_LEN  = 128,
    parameter int REDUCE_LEN = 128,
    parameter int HEAD_DIM   = 128,
    parameter int Q_HEADS    = 4,
    parameter bit CAUSAL_ROW_EFFECTIVE = 1'b1
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic causal_en,
    output logic busy,
    output logic done,

    output logic vec_ready,
    input  logic vec_valid,
    input  logic [TILE*16-1:0] p_vec_bf16,
    input  logic [PV_LANES*TILE*16-1:0] v_vec_bf16,

    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0]
        req_head,
    output logic [((QUERY_LEN <= 1) ? 1 : $clog2(QUERY_LEN))-1:0]
        req_row_base,
    output logic [((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM))-1:0]
        req_col_base,
    output logic [((REDUCE_LEN <= 1) ? 1 : $clog2(REDUCE_LEN))-1:0]
        req_reduce,

    output logic context_valid,
    input  logic context_ready,
    output logic [15:0] context_bf16,
    output logic [31:0] context_fp32_debug,
    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0]
        context_head,
    output logic [((QUERY_LEN <= 1) ? 1 : $clog2(QUERY_LEN))-1:0]
        context_row,
    output logic [((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM))-1:0]
        context_col,
    output logic context_last,

    // Counts are FP32 MAC reduction terms, not clock cycles.
    output logic [31:0] pv_reductions_computed,
    output logic [31:0] pv_reductions_skipped,
    output logic pv_zero_probability_violation
);
    localparam int HEAD_W = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS);
    localparam int ROW_W  = (QUERY_LEN <= 1) ? 1 : $clog2(QUERY_LEN);
    localparam int COL_W  = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM);
    localparam int RED_W  = (REDUCE_LEN <= 1) ? 1 : $clog2(REDUCE_LEN);
    localparam int LOC_W  = (TILE <= 1) ? 1 : $clog2(TILE);
    localparam int LANE_W = (PV_LANES <= 1) ? 1 : $clog2(PV_LANES);
    localparam int PAIR_SPAN = PV_LANES*TILE;

    typedef enum logic [1:0] {
        S_IDLE   = 2'd0,
        S_START  = 2'd1,
        S_FEED   = 2'd2,
        S_OUTPUT = 2'd3
    } state_t;

    state_t state;
    logic [HEAD_W-1:0] head_reg;
    logic [ROW_W-1:0] row_base_reg;
    logic [COL_W-1:0] pair_col_base_reg;
    logic [RED_W-1:0] reduce_reg;

    logic [PV_LANES-1:0] lane_active;
    logic [PV_LANES-1:0] tile_start;
    logic [PV_LANES-1:0] tile_in_ready;
    logic [PV_LANES-1:0] tile_out_valid;
    logic [PV_LANES-1:0] tile_out_ready;
    logic [PV_LANES-1:0] tile_out_last;
    logic [15:0] tile_out_context [0:PV_LANES-1];
    logic [31:0] tile_out_fp32 [0:PV_LANES-1];
    logic [LOC_W-1:0] tile_out_row [0:PV_LANES-1];
    logic [LOC_W-1:0] tile_out_col [0:PV_LANES-1];
    logic [LANE_W-1:0] emit_lane;

    logic [TILE-1:0] row_enable;
    logic [TILE-1:0] row_first;
    logic [TILE-1:0] row_last;
    logic effective_last_beat;
    logic all_active_tiles_ready;
    logic [31:0] pair_total_terms;
    logic [31:0] pair_computed_terms;
    logic [31:0] pair_skipped_terms;

    integer lane;
    integer row;
    integer active_lane_count;
    integer enabled_reductions_per_lane;

    always_comb begin
        active_lane_count = 0;
        for (lane = 0; lane < PV_LANES; lane = lane + 1) begin
            lane_active[lane] =
                ($unsigned(pair_col_base_reg) + lane*TILE) < HEAD_DIM;
            if (lane_active[lane])
                active_lane_count = active_lane_count + 1;
        end

        for (row = 0; row < TILE; row = row + 1) begin
            row_enable[row] =
                !(CAUSAL_ROW_EFFECTIVE && causal_en) ||
                ($unsigned(reduce_reg) <=
                 ($unsigned(row_base_reg) + row));
            row_first[row] =
                row_enable[row] && ($unsigned(reduce_reg) == 0);
            row_last[row] =
                row_enable[row] &&
                ((CAUSAL_ROW_EFFECTIVE && causal_en) ?
                    ($unsigned(reduce_reg) ==
                     ($unsigned(row_base_reg) + row)) :
                    ($unsigned(reduce_reg) == REDUCE_LEN-1));
        end

        effective_last_beat =
            (CAUSAL_ROW_EFFECTIVE && causal_en) ?
                ($unsigned(reduce_reg) ==
                 ($unsigned(row_base_reg) + TILE-1)) :
                ($unsigned(reduce_reg) == REDUCE_LEN-1);

        all_active_tiles_ready = 1'b1;
        for (lane = 0; lane < PV_LANES; lane = lane + 1) begin
            if (lane_active[lane] && !tile_in_ready[lane])
                all_active_tiles_ready = 1'b0;
        end

        pair_total_terms =
            active_lane_count * TILE * TILE * REDUCE_LEN;
        enabled_reductions_per_lane =
            TILE * ($unsigned(row_base_reg) + 1) +
            (TILE * (TILE-1))/2;
        if (CAUSAL_ROW_EFFECTIVE && causal_en)
            pair_computed_terms =
                active_lane_count * TILE * enabled_reductions_per_lane;
        else
            pair_computed_terms = pair_total_terms;
        pair_skipped_terms = pair_total_terms - pair_computed_terms;
    end

    assign busy = (state != S_IDLE);
    assign vec_ready =
        (state == S_FEED) && all_active_tiles_ready;

    assign req_head = head_reg;
    assign req_row_base = row_base_reg;
    assign req_col_base = pair_col_base_reg;
    assign req_reduce = reduce_reg;

    genvar g;
    generate
        for (g = 0; g < PV_LANES; g = g + 1) begin : GEN_PV_LANE
            logic unused_tile_busy;
            logic unused_tile_done;

            pv_systolic_tile #(
                .TILE(TILE),
                .REDUCE_LEN(REDUCE_LEN)
            ) u_tile (
                .clk(clk),
                .rst_n(rst_n),
                .tile_start(tile_start[g]),
                .tile_busy(unused_tile_busy),
                .tile_done(unused_tile_done),
                .in_valid(
                    (state == S_FEED) &&
                    vec_valid &&
                    vec_ready &&
                    lane_active[g]
                ),
                .in_ready(tile_in_ready[g]),
                .p_rows_bf16(p_vec_bf16),
                .v_cols_bf16(
                    v_vec_bf16[g*TILE*16 +: TILE*16]
                ),
                .in_row_enable(row_enable),
                .in_row_first(row_first),
                .in_row_last(row_last),
                .in_last_beat(effective_last_beat),
                .out_valid(tile_out_valid[g]),
                .out_ready(tile_out_ready[g]),
                .out_context_bf16(tile_out_context[g]),
                .out_local_row(tile_out_row[g]),
                .out_local_col(tile_out_col[g]),
                .out_last(tile_out_last[g]),
                .out_context_fp32_debug(tile_out_fp32[g])
            );
        end
    endgenerate

    always_comb begin
        context_valid =
            (state == S_OUTPUT) &&
            lane_active[emit_lane] &&
            tile_out_valid[emit_lane];
        context_bf16 = tile_out_context[emit_lane];
        context_fp32_debug = tile_out_fp32[emit_lane];
        context_head = head_reg;
        context_row = row_base_reg + tile_out_row[emit_lane];
        context_col = pair_col_base_reg +
                      $unsigned(emit_lane)*TILE +
                      tile_out_col[emit_lane];
        context_last =
            (context_head == Q_HEADS-1) &&
            (context_row == QUERY_LEN-1) &&
            (context_col == HEAD_DIM-1);

        tile_out_ready = '0;
        if ((state == S_OUTPUT) && lane_active[emit_lane])
            tile_out_ready[emit_lane] = context_ready;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done <= 1'b0;
            head_reg <= '0;
            row_base_reg <= '0;
            pair_col_base_reg <= '0;
            reduce_reg <= '0;
            tile_start <= '0;
            emit_lane <= '0;
            pv_reductions_computed <= '0;
            pv_reductions_skipped <= '0;
            pv_zero_probability_violation <= 1'b0;
        end else begin
            done <= 1'b0;
            tile_start <= '0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        head_reg <= '0;
                        row_base_reg <= '0;
                        pair_col_base_reg <= '0;
                        reduce_reg <= '0;
                        emit_lane <= '0;
                        pv_reductions_computed <= '0;
                        pv_reductions_skipped <= '0;
                        pv_zero_probability_violation <= 1'b0;
                        state <= S_START;
                    end
                end

                S_START: begin
                    reduce_reg <= '0;
                    emit_lane <= '0;
                    pv_reductions_computed <=
                        pv_reductions_computed + pair_computed_terms;
                    pv_reductions_skipped <=
                        pv_reductions_skipped + pair_skipped_terms;
                    for (lane = 0; lane < PV_LANES; lane = lane + 1) begin
                        if (lane_active[lane])
                            tile_start[lane] <= 1'b1;
                    end
                    state <= S_FEED;
                end

                S_FEED: begin
                    if (vec_valid && vec_ready) begin
                        if (CAUSAL_ROW_EFFECTIVE && causal_en) begin
                            for (row = 0; row < TILE; row = row + 1) begin
                                if (!row_enable[row] &&
                                    (p_vec_bf16[row*16 +: 16] != 16'h0000))
                                    pv_zero_probability_violation <= 1'b1;
                            end
                        end

                        if (effective_last_beat) begin
                            state <= S_OUTPUT;
                        end else begin
                            reduce_reg <= reduce_reg + 1'b1;
                        end
                    end
                end

                S_OUTPUT: begin
                    if (context_valid && context_ready &&
                        tile_out_last[emit_lane]) begin
                        if (($unsigned(emit_lane) + 1 < PV_LANES) &&
                            lane_active[emit_lane + 1'b1]) begin
                            emit_lane <= emit_lane + 1'b1;
                        end else begin
                            if ($unsigned(pair_col_base_reg) + PAIR_SPAN <
                                HEAD_DIM) begin
                                pair_col_base_reg <=
                                    pair_col_base_reg + PAIR_SPAN;
                                state <= S_START;
                            end else begin
                                pair_col_base_reg <= '0;
                                if ($unsigned(row_base_reg) + TILE <
                                    QUERY_LEN) begin
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
                    pv_zero_probability_violation <= 1'b1;
                    state <= S_IDLE;
                end
            endcase
        end
    end

    initial begin
        if ((PV_LANES < 1) || (PV_LANES > 2))
            $error("pv_parallel_systolic_gqa_top: PV_LANES must be 1 or 2");
        if ((QUERY_LEN % TILE) != 0)
            $error("pv_parallel_systolic_gqa_top: TILE must divide QUERY_LEN");
        if ((HEAD_DIM % (PV_LANES*TILE)) != 0)
            $error("pv_parallel_systolic_gqa_top: PV_LANES*TILE must divide HEAD_DIM");
        if (REDUCE_LEN != QUERY_LEN)
            $error("pv_parallel_systolic_gqa_top: causal mode requires REDUCE_LEN=QUERY_LEN");
    end
endmodule
