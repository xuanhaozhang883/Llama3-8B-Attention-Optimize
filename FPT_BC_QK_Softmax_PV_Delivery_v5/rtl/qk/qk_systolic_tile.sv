`timescale 1ns/1ps

// ============================================================================
// qk_systolic_tile
// ----------------------------------------------------------------------------
// Parameterized, globally-stallable BF16 systolic tile.
//
// Input stream:
//   One accepted beat corresponds to one head-dimension index d.
//   q_rows_bf16[i] = Q[row_base+i][d]
//   k_cols_bf16[j] = K[col_base+j][d]
//   Exactly HEAD_DIM beats are accepted for each tile.
//
// Dataflow:
//   Q data moves left -> right.
//   K data moves top  -> bottom.
//   Row/column skew and wavefront flushing are internal.
//
// Output stream:
//   TILE*TILE BF16 scores, row-major by local_row/local_col.
//
// This first implementation intentionally stalls the whole array until every
// active PE finishes the current floating-point MAC.  It is much easier to
// verify bit-for-bit against the validated serial core and still computes
// TILE*TILE output scores in parallel.
// ============================================================================
module qk_systolic_tile #(
    parameter int TILE      = 2,
    parameter int HEAD_DIM  = 128,
    parameter logic [31:0] SCALE_FP32 = 32'h3DB504F3
)(
    input  logic                   clk,
    input  logic                   rst_n,

    input  logic                   tile_start,
    output logic                   tile_busy,
    output logic                   tile_done,

    input  logic                   in_valid,
    output logic                   in_ready,
    input  logic [TILE*16-1:0]     q_rows_bf16,
    input  logic [TILE*16-1:0]     k_cols_bf16,

    output logic                   out_valid,
    input  logic                   out_ready,
    output logic [15:0]            out_score_bf16,
    output logic [((TILE <= 1) ? 1 : $clog2(TILE))-1:0] out_local_row,
    output logic [((TILE <= 1) ? 1 : $clog2(TILE))-1:0] out_local_col,
    output logic                   out_last,
    output logic [31:0]            out_score_fp32_debug
);

    localparam int FLUSH_STEPS = 2 * (TILE - 1);
    localparam int FEED_W      = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM + 1);
    localparam int FLUSH_W     = (FLUSH_STEPS <= 1) ? 1 : $clog2(FLUSH_STEPS + 1);
    localparam int RESULT_N    = TILE * TILE;
    localparam int RESULT_W    = (RESULT_N <= 1) ? 1 : $clog2(RESULT_N);
    localparam int LOCAL_W     = (TILE <= 1) ? 1 : $clog2(TILE);

    typedef enum logic [3:0] {
        S_IDLE          = 4'd0,
        S_CLEAR         = 4'd1,
        S_WAIT_INPUT    = 4'd2,
        S_SHIFT         = 4'd3,
        S_ISSUE         = 4'd4,
        S_WAIT_PE       = 4'd5,
        S_WAIT_RESULTS  = 4'd6,
        S_SEND_RESULT   = 4'd7,
        S_WAIT_SCALER   = 4'd8
    } state_t;

    state_t state;

    logic [FEED_W-1:0]  feed_count;
    logic [FLUSH_W-1:0] flush_count;
    logic [RESULT_W-1:0] result_index;

    logic [TILE*16-1:0] edge_q_reg;
    logic [TILE*16-1:0] edge_k_reg;
    logic               edge_valid_reg;
    logic               edge_first_reg;
    logic               edge_last_reg;

    logic [15:0] a_pipe       [0:TILE-1][0:TILE-1];
    logic [15:0] b_pipe       [0:TILE-1][0:TILE-1];
    logic        a_valid_pipe [0:TILE-1][0:TILE-1];
    logic        b_valid_pipe [0:TILE-1][0:TILE-1];
    logic        a_first_pipe [0:TILE-1][0:TILE-1];
    logic        b_first_pipe [0:TILE-1][0:TILE-1];
    logic        a_last_pipe  [0:TILE-1][0:TILE-1];
    logic        b_last_pipe  [0:TILE-1][0:TILE-1];

    // Full-size skew arrays keep the RTL simple.  Synthesis removes unused
    // stages because row i only consumes stage i-1 and column j stage j-1.
    logic [15:0] a_skew_data  [0:TILE-1][0:TILE-1];
    logic [15:0] b_skew_data  [0:TILE-1][0:TILE-1];
    logic        a_skew_valid [0:TILE-1][0:TILE-1];
    logic        b_skew_valid [0:TILE-1][0:TILE-1];
    logic        a_skew_first [0:TILE-1][0:TILE-1];
    logic        b_skew_first [0:TILE-1][0:TILE-1];
    logic        a_skew_last  [0:TILE-1][0:TILE-1];
    logic        b_skew_last  [0:TILE-1][0:TILE-1];

    logic [RESULT_N-1:0] pe_ready_vec;
    logic [RESULT_N-1:0] pe_result_valid_vec;
    logic [RESULT_N*32-1:0] pe_result_flat;

    logic pe_step_start;
    logic pe_tile_clear;
    logic all_pe_ready;
    logic all_results_valid;

    assign pe_step_start    = (state == S_ISSUE);
    assign pe_tile_clear    = (state == S_CLEAR);
    assign all_pe_ready     = &pe_ready_vec;
    assign all_results_valid = &pe_result_valid_vec;

    assign tile_busy = (state != S_IDLE);
    assign in_ready  = (state == S_WAIT_INPUT) &&
                       (feed_count < HEAD_DIM) &&
                       all_pe_ready;

    // ------------------------------------------------------------------------
    // PE grid
    // ------------------------------------------------------------------------
    genvar gr, gc;
    generate
        for (gr = 0; gr < TILE; gr = gr + 1) begin : GEN_ROW
            for (gc = 0; gc < TILE; gc = gc + 1) begin : GEN_COL
                localparam int P = gr*TILE + gc;

                qk_systolic_pe u_pe (
                    .clk          (clk),
                    .rst_n        (rst_n),
                    .tile_clear   (pe_tile_clear),
                    .step_start   (pe_step_start),
                    .data_valid   (a_valid_pipe[gr][gc] && b_valid_pipe[gr][gc]),
                    .first        (a_first_pipe[gr][gc] && b_first_pipe[gr][gc]),
                    .last         (a_last_pipe[gr][gc]  && b_last_pipe[gr][gc]),
                    .a_bf16       (a_pipe[gr][gc]),
                    .b_bf16       (b_pipe[gr][gc]),
                    .ready        (pe_ready_vec[P]),
                    .result_valid (pe_result_valid_vec[P]),
                    .result_fp32  (pe_result_flat[P*32 +: 32])
                );
            end
        end
    endgenerate

    // ------------------------------------------------------------------------
    // Shared result scaler
    // ------------------------------------------------------------------------
    logic        scaler_in_valid;
    logic        scaler_in_ready;
    logic [31:0] scaler_in_data;
    logic        scaler_out_valid;
    logic        scaler_out_ready;
    logic [15:0] scaler_out_bf16;
    logic [31:0] scaler_out_fp32;

    logic [LOCAL_W-1:0] result_row_meta;
    logic [LOCAL_W-1:0] result_col_meta;
    logic               result_last_meta;

    assign scaler_in_valid = (state == S_SEND_RESULT);
    assign scaler_in_data  = pe_result_flat[result_index*32 +: 32];
    assign scaler_out_ready = (state == S_WAIT_SCALER) && out_ready;

    assign out_valid            = (state == S_WAIT_SCALER) && scaler_out_valid;
    assign out_score_bf16       = scaler_out_bf16;
    assign out_score_fp32_debug = scaler_out_fp32;
    assign out_local_row        = result_row_meta;
    assign out_local_col        = result_col_meta;
    assign out_last             = result_last_meta;

    qk_result_scaler #(.SCALE_FP32(SCALE_FP32)) u_scaler (
        .clk                 (clk),
        .rst_n               (rst_n),
        .in_valid            (scaler_in_valid),
        .in_ready            (scaler_in_ready),
        .raw_sum_fp32        (scaler_in_data),
        .out_valid           (scaler_out_valid),
        .out_ready           (scaler_out_ready),
        .score_bf16          (scaler_out_bf16),
        .scaled_fp32_debug   (scaler_out_fp32)
    );

    integer r, c, s;

    // ------------------------------------------------------------------------
    // Systolic data/skew registers.  They advance only in S_SHIFT, so the
    // entire array can stall while the floating-point PEs finish a MAC.
    // ------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n || pe_tile_clear) begin
            for (r = 0; r < TILE; r = r + 1) begin
                for (c = 0; c < TILE; c = c + 1) begin
                    a_pipe[r][c]       <= 16'h0000;
                    b_pipe[r][c]       <= 16'h0000;
                    a_valid_pipe[r][c] <= 1'b0;
                    b_valid_pipe[r][c] <= 1'b0;
                    a_first_pipe[r][c] <= 1'b0;
                    b_first_pipe[r][c] <= 1'b0;
                    a_last_pipe[r][c]  <= 1'b0;
                    b_last_pipe[r][c]  <= 1'b0;

                    a_skew_data[r][c]  <= 16'h0000;
                    b_skew_data[r][c]  <= 16'h0000;
                    a_skew_valid[r][c] <= 1'b0;
                    b_skew_valid[r][c] <= 1'b0;
                    a_skew_first[r][c] <= 1'b0;
                    b_skew_first[r][c] <= 1'b0;
                    a_skew_last[r][c]  <= 1'b0;
                    b_skew_last[r][c]  <= 1'b0;
                end
            end
        end else if (state == S_SHIFT) begin
            // Shift the main horizontal/vertical data paths.
            for (r = 0; r < TILE; r = r + 1) begin
                for (c = TILE-1; c > 0; c = c - 1) begin
                    a_pipe[r][c]       <= a_pipe[r][c-1];
                    a_valid_pipe[r][c] <= a_valid_pipe[r][c-1];
                    a_first_pipe[r][c] <= a_first_pipe[r][c-1];
                    a_last_pipe[r][c]  <= a_last_pipe[r][c-1];
                end
            end

            for (c = 0; c < TILE; c = c + 1) begin
                for (r = TILE-1; r > 0; r = r - 1) begin
                    b_pipe[r][c]       <= b_pipe[r-1][c];
                    b_valid_pipe[r][c] <= b_valid_pipe[r-1][c];
                    b_first_pipe[r][c] <= b_first_pipe[r-1][c];
                    b_last_pipe[r][c]  <= b_last_pipe[r-1][c];
                end
            end

            // Boundary injection after row/column skew.
            for (r = 0; r < TILE; r = r + 1) begin
                if (r == 0) begin
                    a_pipe[r][0]       <= edge_q_reg[r*16 +: 16];
                    a_valid_pipe[r][0] <= edge_valid_reg;
                    a_first_pipe[r][0] <= edge_first_reg;
                    a_last_pipe[r][0]  <= edge_last_reg;
                end else begin
                    a_pipe[r][0]       <= a_skew_data[r][r-1];
                    a_valid_pipe[r][0] <= a_skew_valid[r][r-1];
                    a_first_pipe[r][0] <= a_skew_first[r][r-1];
                    a_last_pipe[r][0]  <= a_skew_last[r][r-1];
                end
            end

            for (c = 0; c < TILE; c = c + 1) begin
                if (c == 0) begin
                    b_pipe[0][c]       <= edge_k_reg[c*16 +: 16];
                    b_valid_pipe[0][c] <= edge_valid_reg;
                    b_first_pipe[0][c] <= edge_first_reg;
                    b_last_pipe[0][c]  <= edge_last_reg;
                end else begin
                    b_pipe[0][c]       <= b_skew_data[c][c-1];
                    b_valid_pipe[0][c] <= b_skew_valid[c][c-1];
                    b_first_pipe[0][c] <= b_skew_first[c][c-1];
                    b_last_pipe[0][c]  <= b_skew_last[c][c-1];
                end
            end

            // Update skew chains with this cycle's edge vectors.
            for (r = 0; r < TILE; r = r + 1) begin
                a_skew_data[r][0]  <= edge_q_reg[r*16 +: 16];
                a_skew_valid[r][0] <= edge_valid_reg;
                a_skew_first[r][0] <= edge_first_reg;
                a_skew_last[r][0]  <= edge_last_reg;

                for (s = 1; s < TILE; s = s + 1) begin
                    a_skew_data[r][s]  <= a_skew_data[r][s-1];
                    a_skew_valid[r][s] <= a_skew_valid[r][s-1];
                    a_skew_first[r][s] <= a_skew_first[r][s-1];
                    a_skew_last[r][s]  <= a_skew_last[r][s-1];
                end
            end

            for (c = 0; c < TILE; c = c + 1) begin
                b_skew_data[c][0]  <= edge_k_reg[c*16 +: 16];
                b_skew_valid[c][0] <= edge_valid_reg;
                b_skew_first[c][0] <= edge_first_reg;
                b_skew_last[c][0]  <= edge_last_reg;

                for (s = 1; s < TILE; s = s + 1) begin
                    b_skew_data[c][s]  <= b_skew_data[c][s-1];
                    b_skew_valid[c][s] <= b_skew_valid[c][s-1];
                    b_skew_first[c][s] <= b_skew_first[c][s-1];
                    b_skew_last[c][s]  <= b_skew_last[c][s-1];
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Tile controller
    // ------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            tile_done        <= 1'b0;
            feed_count       <= '0;
            flush_count      <= '0;
            result_index     <= '0;
            edge_q_reg       <= '0;
            edge_k_reg       <= '0;
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
                        edge_q_reg       <= '0;
                        edge_k_reg       <= '0;
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
                    if (feed_count < HEAD_DIM) begin
                        if (in_valid && in_ready) begin
                            edge_q_reg     <= q_rows_bf16;
                            edge_k_reg     <= k_cols_bf16;
                            edge_valid_reg <= 1'b1;
                            edge_first_reg <= (feed_count == 0);
                            edge_last_reg  <= (feed_count == HEAD_DIM-1);
                            feed_count     <= feed_count + 1'b1;
                            state          <= S_SHIFT;
                        end
                    end else if (flush_count < FLUSH_STEPS) begin
                        edge_q_reg       <= '0;
                        edge_k_reg       <= '0;
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
                    if (scaler_in_valid && scaler_in_ready) begin
                        result_row_meta  <= result_index / TILE;
                        result_col_meta  <= result_index % TILE;
                        result_last_meta <= (result_index == RESULT_N-1);
                        state            <= S_WAIT_SCALER;
                    end
                end

                S_WAIT_SCALER: begin
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
            $error("qk_systolic_tile: TILE must be >= 1");
        if (HEAD_DIM < 1)
            $error("qk_systolic_tile: HEAD_DIM must be >= 1");
    end

endmodule
