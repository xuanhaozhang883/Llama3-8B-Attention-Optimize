`timescale 1ns/1ps

// ============================================================================
// pv_systolic_tile
// ----------------------------------------------------------------------------
// Parameterized, globally-stallable BF16 systolic tile for P x V.
//
// One accepted input beat corresponds to one reduction index k:
//   p_rows_bf16[i] = P[row_base+i][k]
//   v_cols_bf16[j] = V[k][col_base+j]
//
// Exactly REDUCE_LEN beats are accepted per tile. P moves left-to-right and V
// moves top-to-bottom. The whole array stalls until all active PEs finish each
// FP32 multiply/add step, preserving the validated bit-exact arithmetic order.
// ============================================================================
module pv_systolic_tile #(
    parameter int TILE       = 4,
    parameter int REDUCE_LEN = 128
)(
    input  logic                   clk,
    input  logic                   rst_n,

    input  logic                   tile_start,
    output logic                   tile_busy,
    output logic                   tile_done,

    input  logic                   in_valid,
    output logic                   in_ready,
    input  logic [TILE*16-1:0]     p_rows_bf16,
    input  logic [TILE*16-1:0]     v_cols_bf16,

    output logic                   out_valid,
    input  logic                   out_ready,
    output logic [15:0]            out_context_bf16,
    output logic [((TILE <= 1) ? 1 : $clog2(TILE))-1:0]
                                   out_local_row,
    output logic [((TILE <= 1) ? 1 : $clog2(TILE))-1:0]
                                   out_local_col,
    output logic                   out_last,
    output logic [31:0]            out_context_fp32_debug
);

    localparam int FLUSH_STEPS = 2 * (TILE - 1);
    localparam int FEED_W      =
        (REDUCE_LEN <= 1) ? 1 : $clog2(REDUCE_LEN + 1);
    localparam int FLUSH_W     =
        (FLUSH_STEPS <= 1) ? 1 : $clog2(FLUSH_STEPS + 1);
    localparam int RESULT_N    = TILE * TILE;
    localparam int RESULT_W    =
        (RESULT_N <= 1) ? 1 : $clog2(RESULT_N);
    localparam int LOCAL_W     =
        (TILE <= 1) ? 1 : $clog2(TILE);

    typedef enum logic [3:0] {
        S_IDLE           = 4'd0,
        S_CLEAR          = 4'd1,
        S_WAIT_INPUT     = 4'd2,
        S_SHIFT          = 4'd3,
        S_ISSUE          = 4'd4,
        S_WAIT_PE        = 4'd5,
        S_WAIT_RESULTS   = 4'd6,
        S_SEND_RESULT    = 4'd7,
        S_WAIT_CONVERTER = 4'd8
    } state_t;

    state_t state;

    logic [FEED_W-1:0]   feed_count;
    logic [FLUSH_W-1:0]  flush_count;
    logic [RESULT_W-1:0] result_index;

    logic [TILE*16-1:0] edge_p_reg;
    logic [TILE*16-1:0] edge_v_reg;
    logic               edge_valid_reg;
    logic               edge_first_reg;
    logic               edge_last_reg;

    logic [15:0] p_pipe       [0:TILE-1][0:TILE-1];
    logic [15:0] v_pipe       [0:TILE-1][0:TILE-1];
    logic        p_valid_pipe [0:TILE-1][0:TILE-1];
    logic        v_valid_pipe [0:TILE-1][0:TILE-1];
    logic        p_first_pipe [0:TILE-1][0:TILE-1];
    logic        v_first_pipe [0:TILE-1][0:TILE-1];
    logic        p_last_pipe  [0:TILE-1][0:TILE-1];
    logic        v_last_pipe  [0:TILE-1][0:TILE-1];

    logic [15:0] p_skew_data  [0:TILE-1][0:TILE-1];
    logic [15:0] v_skew_data  [0:TILE-1][0:TILE-1];
    logic        p_skew_valid [0:TILE-1][0:TILE-1];
    logic        v_skew_valid [0:TILE-1][0:TILE-1];
    logic        p_skew_first [0:TILE-1][0:TILE-1];
    logic        v_skew_first [0:TILE-1][0:TILE-1];
    logic        p_skew_last  [0:TILE-1][0:TILE-1];
    logic        v_skew_last  [0:TILE-1][0:TILE-1];

    logic [RESULT_N-1:0]    pe_ready_vec;
    logic [RESULT_N-1:0]    pe_result_valid_vec;
    logic [RESULT_N*32-1:0] pe_result_flat;

    logic pe_step_start;
    logic pe_tile_clear;
    logic all_pe_ready;
    logic all_results_valid;

    assign pe_step_start     = (state == S_ISSUE);
    assign pe_tile_clear     = (state == S_CLEAR);
    assign all_pe_ready      = &pe_ready_vec;
    assign all_results_valid = &pe_result_valid_vec;

    assign tile_busy = (state != S_IDLE);
    assign in_ready  = (state == S_WAIT_INPUT) &&
                       (feed_count < REDUCE_LEN) &&
                       all_pe_ready;

    genvar gr, gc;
    generate
        for (gr = 0; gr < TILE; gr = gr + 1) begin : GEN_ROW
            for (gc = 0; gc < TILE; gc = gc + 1) begin : GEN_COL
                localparam int P_INDEX = gr*TILE + gc;

                pv_systolic_pe u_pe (
                    .clk          (clk),
                    .rst_n        (rst_n),
                    .tile_clear   (pe_tile_clear),
                    .step_start   (pe_step_start),
                    .data_valid   (
                        p_valid_pipe[gr][gc] &&
                        v_valid_pipe[gr][gc]
                    ),
                    .first        (
                        p_first_pipe[gr][gc] &&
                        v_first_pipe[gr][gc]
                    ),
                    .last         (
                        p_last_pipe[gr][gc] &&
                        v_last_pipe[gr][gc]
                    ),
                    .p_bf16       (p_pipe[gr][gc]),
                    .v_bf16       (v_pipe[gr][gc]),
                    .ready        (pe_ready_vec[P_INDEX]),
                    .result_valid (pe_result_valid_vec[P_INDEX]),
                    .result_fp32  (
                        pe_result_flat[P_INDEX*32 +: 32]
                    )
                );
            end
        end
    endgenerate

    logic        converter_in_valid;
    logic        converter_in_ready;
    logic [31:0] converter_in_data;
    logic        converter_out_valid;
    logic        converter_out_ready;
    logic [15:0] converter_out_bf16;
    logic [31:0] converter_out_fp32;

    logic [LOCAL_W-1:0] result_row_meta;
    logic [LOCAL_W-1:0] result_col_meta;
    logic               result_last_meta;

    assign converter_in_valid =
        (state == S_SEND_RESULT);
    assign converter_in_data =
        pe_result_flat[result_index*32 +: 32];
    assign converter_out_ready =
        (state == S_WAIT_CONVERTER) && out_ready;

    assign out_valid              =
        (state == S_WAIT_CONVERTER) && converter_out_valid;
    assign out_context_bf16       = converter_out_bf16;
    assign out_context_fp32_debug = converter_out_fp32;
    assign out_local_row          = result_row_meta;
    assign out_local_col          = result_col_meta;
    assign out_last               = result_last_meta;

    pv_result_converter u_converter (
        .clk                  (clk),
        .rst_n                (rst_n),
        .in_valid             (converter_in_valid),
        .in_ready             (converter_in_ready),
        .raw_sum_fp32         (converter_in_data),
        .out_valid            (converter_out_valid),
        .out_ready            (converter_out_ready),
        .context_bf16         (converter_out_bf16),
        .context_fp32_debug   (converter_out_fp32)
    );

    integer r;
    integer c;
    integer s;

    always_ff @(posedge clk) begin
        if (!rst_n || pe_tile_clear) begin
            for (r = 0; r < TILE; r = r + 1) begin
                for (c = 0; c < TILE; c = c + 1) begin
                    p_pipe[r][c]       <= 16'h0000;
                    v_pipe[r][c]       <= 16'h0000;
                    p_valid_pipe[r][c] <= 1'b0;
                    v_valid_pipe[r][c] <= 1'b0;
                    p_first_pipe[r][c] <= 1'b0;
                    v_first_pipe[r][c] <= 1'b0;
                    p_last_pipe[r][c]  <= 1'b0;
                    v_last_pipe[r][c]  <= 1'b0;

                    p_skew_data[r][c]  <= 16'h0000;
                    v_skew_data[r][c]  <= 16'h0000;
                    p_skew_valid[r][c] <= 1'b0;
                    v_skew_valid[r][c] <= 1'b0;
                    p_skew_first[r][c] <= 1'b0;
                    v_skew_first[r][c] <= 1'b0;
                    p_skew_last[r][c]  <= 1'b0;
                    v_skew_last[r][c]  <= 1'b0;
                end
            end
        end else if (state == S_SHIFT) begin
            for (r = 0; r < TILE; r = r + 1) begin
                for (c = TILE-1; c > 0; c = c - 1) begin
                    p_pipe[r][c]       <= p_pipe[r][c-1];
                    p_valid_pipe[r][c] <= p_valid_pipe[r][c-1];
                    p_first_pipe[r][c] <= p_first_pipe[r][c-1];
                    p_last_pipe[r][c]  <= p_last_pipe[r][c-1];
                end
            end

            for (c = 0; c < TILE; c = c + 1) begin
                for (r = TILE-1; r > 0; r = r - 1) begin
                    v_pipe[r][c]       <= v_pipe[r-1][c];
                    v_valid_pipe[r][c] <= v_valid_pipe[r-1][c];
                    v_first_pipe[r][c] <= v_first_pipe[r-1][c];
                    v_last_pipe[r][c]  <= v_last_pipe[r-1][c];
                end
            end

            for (r = 0; r < TILE; r = r + 1) begin
                if (r == 0) begin
                    p_pipe[r][0]       <= edge_p_reg[r*16 +: 16];
                    p_valid_pipe[r][0] <= edge_valid_reg;
                    p_first_pipe[r][0] <= edge_first_reg;
                    p_last_pipe[r][0]  <= edge_last_reg;
                end else begin
                    p_pipe[r][0]       <= p_skew_data[r][r-1];
                    p_valid_pipe[r][0] <= p_skew_valid[r][r-1];
                    p_first_pipe[r][0] <= p_skew_first[r][r-1];
                    p_last_pipe[r][0]  <= p_skew_last[r][r-1];
                end
            end

            for (c = 0; c < TILE; c = c + 1) begin
                if (c == 0) begin
                    v_pipe[0][c]       <= edge_v_reg[c*16 +: 16];
                    v_valid_pipe[0][c] <= edge_valid_reg;
                    v_first_pipe[0][c] <= edge_first_reg;
                    v_last_pipe[0][c]  <= edge_last_reg;
                end else begin
                    v_pipe[0][c]       <= v_skew_data[c][c-1];
                    v_valid_pipe[0][c] <= v_skew_valid[c][c-1];
                    v_first_pipe[0][c] <= v_skew_first[c][c-1];
                    v_last_pipe[0][c]  <= v_skew_last[c][c-1];
                end
            end

            for (r = 0; r < TILE; r = r + 1) begin
                p_skew_data[r][0]  <= edge_p_reg[r*16 +: 16];
                p_skew_valid[r][0] <= edge_valid_reg;
                p_skew_first[r][0] <= edge_first_reg;
                p_skew_last[r][0]  <= edge_last_reg;

                for (s = 1; s < TILE; s = s + 1) begin
                    p_skew_data[r][s]  <= p_skew_data[r][s-1];
                    p_skew_valid[r][s] <= p_skew_valid[r][s-1];
                    p_skew_first[r][s] <= p_skew_first[r][s-1];
                    p_skew_last[r][s]  <= p_skew_last[r][s-1];
                end
            end

            for (c = 0; c < TILE; c = c + 1) begin
                v_skew_data[c][0]  <= edge_v_reg[c*16 +: 16];
                v_skew_valid[c][0] <= edge_valid_reg;
                v_skew_first[c][0] <= edge_first_reg;
                v_skew_last[c][0]  <= edge_last_reg;

                for (s = 1; s < TILE; s = s + 1) begin
                    v_skew_data[c][s]  <= v_skew_data[c][s-1];
                    v_skew_valid[c][s] <= v_skew_valid[c][s-1];
                    v_skew_first[c][s] <= v_skew_first[c][s-1];
                    v_skew_last[c][s]  <= v_skew_last[c][s-1];
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            tile_done        <= 1'b0;
            feed_count       <= '0;
            flush_count      <= '0;
            result_index     <= '0;
            edge_p_reg       <= '0;
            edge_v_reg       <= '0;
            edge_valid_reg   <= 1'b0;
            edge_first_reg   <= 1'b0;
            edge_last_reg    <= 1'b0;
            result_row_meta  <= '0;
            result_col_meta  <= '0;
            result_last_meta <= 1'b0;
        end else begin
            tile_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (tile_start) begin
                        feed_count       <= '0;
                        flush_count      <= '0;
                        result_index     <= '0;
                        edge_p_reg       <= '0;
                        edge_v_reg       <= '0;
                        edge_valid_reg   <= 1'b0;
                        edge_first_reg   <= 1'b0;
                        edge_last_reg    <= 1'b0;
                        result_row_meta  <= '0;
                        result_col_meta  <= '0;
                        result_last_meta <= 1'b0;
                        state            <= S_CLEAR;
                    end
                end

                S_CLEAR: begin
                    state <= S_WAIT_INPUT;
                end

                S_WAIT_INPUT: begin
                    if (feed_count < REDUCE_LEN) begin
                        if (in_valid && in_ready) begin
                            edge_p_reg     <= p_rows_bf16;
                            edge_v_reg     <= v_cols_bf16;
                            edge_valid_reg <= 1'b1;
                            edge_first_reg <= (feed_count == 0);
                            edge_last_reg  <=
                                (feed_count == REDUCE_LEN-1);
                            feed_count     <= feed_count + 1'b1;
                            state          <= S_SHIFT;
                        end
                    end else if (flush_count < FLUSH_STEPS) begin
                        edge_p_reg       <= '0;
                        edge_v_reg       <= '0;
                        edge_valid_reg   <= 1'b0;
                        edge_first_reg   <= 1'b0;
                        edge_last_reg    <= 1'b0;
                        flush_count      <= flush_count + 1'b1;
                        state            <= S_SHIFT;
                    end else begin
                        state <= S_WAIT_RESULTS;
                    end
                end

                S_SHIFT: begin
                    state <= S_ISSUE;
                end

                S_ISSUE: begin
                    state <= S_WAIT_PE;
                end

                S_WAIT_PE: begin
                    if (all_pe_ready)
                        state <= S_WAIT_INPUT;
                end

                S_WAIT_RESULTS: begin
                    if (all_results_valid) begin
                        result_index <= '0;
                        state        <= S_SEND_RESULT;
                    end
                end

                S_SEND_RESULT: begin
                    if (converter_in_valid && converter_in_ready) begin
                        result_row_meta  <= result_index / TILE;
                        result_col_meta  <= result_index % TILE;
                        result_last_meta <=
                            (result_index == RESULT_N-1);
                        state <= S_WAIT_CONVERTER;
                    end
                end

                S_WAIT_CONVERTER: begin
                    if (out_valid && out_ready) begin
                        if (result_last_meta) begin
                            tile_done <= 1'b1;
                            state     <= S_IDLE;
                        end else begin
                            result_index <= result_index + 1'b1;
                            state        <= S_SEND_RESULT;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    initial begin
        if (TILE < 1)
            $error("pv_systolic_tile: TILE must be >= 1");
        if (REDUCE_LEN < 1)
            $error("pv_systolic_tile: REDUCE_LEN must be >= 1");
    end

endmodule
