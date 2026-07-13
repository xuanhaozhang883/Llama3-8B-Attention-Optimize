`timescale 1ns/1ps

// ============================================================================
// qk_systolic_gqa_top
// ----------------------------------------------------------------------------
// Full matrix/tile scheduler around qk_systolic_tile.
//
// The module generates metadata describing which vector beat is required:
//   req_head, req_row_base, req_col_base, req_dim
// The upstream loader must present TILE Q values and TILE K values on the
// vec_* stream for that metadata.  This cleanly separates matrix scheduling
// from BRAM/DDR banking and AXI implementation.
//
// Current single-GQA-group use case:
//   Q_HEADS=4, SEQ_LEN=128, HEAD_DIM=128, one shared K head.
// ============================================================================
module qk_systolic_gqa_top #(
    parameter int TILE      = 2,
    parameter int SEQ_LEN   = 128,
    parameter int HEAD_DIM  = 128,
    parameter int Q_HEADS   = 4,
    parameter logic [31:0] SCALE_FP32 = 32'h3DB504F3
)(
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     start,
    output logic                     busy,
    output logic                     done,

    // Vector-loader stream.  Metadata remains stable until vec_valid&&vec_ready.
    output logic                     vec_ready,
    input  logic                     vec_valid,
    input  logic [TILE*16-1:0]       q_vec_bf16,
    input  logic [TILE*16-1:0]       k_vec_bf16,

    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] req_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] req_row_base,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] req_col_base,
    output logic [((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM))-1:0] req_dim,

    // Global score stream.
    output logic                     score_valid,
    input  logic                     score_ready,
    output logic [15:0]              score_bf16,
    output logic [31:0]              score_fp32_debug,
    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] score_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] score_row,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] score_col,
    output logic                     score_last
);

    localparam int HEAD_W = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS);
    localparam int SEQ_W  = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN);
    localparam int DIM_W  = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM);
    localparam int LOC_W  = (TILE <= 1) ? 1 : $clog2(TILE);

    typedef enum logic [2:0] {
        S_IDLE       = 3'd0,
        S_START_TILE = 3'd1,
        S_FEED_TILE  = 3'd2,
        S_WAIT_TILE  = 3'd3
    } state_t;

    state_t state;

    logic [HEAD_W-1:0] head_reg;
    logic [SEQ_W-1:0]  row_base_reg;
    logic [SEQ_W-1:0]  col_base_reg;
    logic [DIM_W-1:0]  dim_reg;

    logic tile_start;
    logic tile_busy;
    logic tile_done;
    logic tile_in_ready;
    logic tile_out_valid;
    logic tile_out_ready;
    logic [15:0] tile_out_score;
    logic [31:0] tile_out_fp32;
    logic [LOC_W-1:0] tile_local_row;
    logic [LOC_W-1:0] tile_local_col;
    logic tile_out_last;

    assign busy = (state != S_IDLE);

    assign req_head     = head_reg;
    assign req_row_base = row_base_reg;
    assign req_col_base = col_base_reg;
    assign req_dim      = dim_reg;

    assign vec_ready = (state == S_FEED_TILE) && tile_in_ready;

    assign score_valid      = tile_out_valid;
    assign score_bf16       = tile_out_score;
    assign score_fp32_debug = tile_out_fp32;
    assign score_head       = head_reg;
    assign score_row        = row_base_reg + tile_local_row;
    assign score_col        = col_base_reg + tile_local_col;
    assign score_last       = (head_reg == Q_HEADS-1) &&
                              ((row_base_reg + tile_local_row) == SEQ_LEN-1) &&
                              ((col_base_reg + tile_local_col) == SEQ_LEN-1);

    assign tile_out_ready = score_ready;

    qk_systolic_tile #(
        .TILE       (TILE),
        .HEAD_DIM   (HEAD_DIM),
        .SCALE_FP32 (SCALE_FP32)
    ) u_tile (
        .clk                    (clk),
        .rst_n                  (rst_n),
        .tile_start             (tile_start),
        .tile_busy              (tile_busy),
        .tile_done              (tile_done),
        .in_valid               ((state == S_FEED_TILE) && vec_valid),
        .in_ready               (tile_in_ready),
        .q_rows_bf16            (q_vec_bf16),
        .k_cols_bf16            (k_vec_bf16),
        .out_valid              (tile_out_valid),
        .out_ready              (tile_out_ready),
        .out_score_bf16         (tile_out_score),
        .out_local_row          (tile_local_row),
        .out_local_col          (tile_local_col),
        .out_last               (tile_out_last),
        .out_score_fp32_debug   (tile_out_fp32)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            done         <= 1'b0;
            tile_start   <= 1'b0;
            head_reg     <= '0;
            row_base_reg <= '0;
            col_base_reg <= '0;
            dim_reg      <= '0;
        end else begin
            done       <= 1'b0;
            tile_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        head_reg     <= '0;
                        row_base_reg <= '0;
                        col_base_reg <= '0;
                        dim_reg      <= '0;
                        state        <= S_START_TILE;
                    end
                end

                S_START_TILE: begin
                    tile_start <= 1'b1;
                    dim_reg    <= '0;
                    state      <= S_FEED_TILE;
                end

                S_FEED_TILE: begin
                    if (vec_valid && vec_ready) begin
                        if (dim_reg == HEAD_DIM-1) begin
                            state <= S_WAIT_TILE;
                        end else begin
                            dim_reg <= dim_reg + 1'b1;
                        end
                    end
                end

                S_WAIT_TILE: begin
                    if (tile_done) begin
                        if (col_base_reg + TILE < SEQ_LEN) begin
                            col_base_reg <= col_base_reg + TILE;
                            dim_reg      <= '0;
                            state        <= S_START_TILE;
                        end else begin
                            col_base_reg <= '0;

                            if (row_base_reg + TILE < SEQ_LEN) begin
                                row_base_reg <= row_base_reg + TILE;
                                dim_reg      <= '0;
                                state        <= S_START_TILE;
                            end else begin
                                row_base_reg <= '0;

                                if (head_reg + 1 < Q_HEADS) begin
                                    head_reg <= head_reg + 1'b1;
                                    dim_reg  <= '0;
                                    state    <= S_START_TILE;
                                end else begin
                                    done  <= 1'b1;
                                    state <= S_IDLE;
                                end
                            end
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    initial begin
        if ((SEQ_LEN % TILE) != 0)
            $error("qk_systolic_gqa_top: SEQ_LEN must be divisible by TILE");
    end

endmodule
