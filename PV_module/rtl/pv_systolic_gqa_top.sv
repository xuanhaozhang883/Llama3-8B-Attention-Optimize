`timescale 1ns/1ps

// ============================================================================
// pv_systolic_gqa_top
// ----------------------------------------------------------------------------
// Full matrix scheduler for one GQA group:
//
//   Context[h] = P[h] x V
//
//   P shape       = [Q_HEADS, QUERY_LEN, REDUCE_LEN]
//   V shape       = [1,       REDUCE_LEN, HEAD_DIM]
//   Context shape = [Q_HEADS, QUERY_LEN, HEAD_DIM]
//
// The upstream loader must provide, for the current request metadata:
//   p_vec_bf16[i] = P[req_head][req_row_base+i][req_reduce]
//   v_vec_bf16[j] = V[req_reduce][req_col_base+j]
// ============================================================================
module pv_systolic_gqa_top #(
    parameter int TILE       = 4,
    parameter int QUERY_LEN  = 128,
    parameter int REDUCE_LEN = 128,
    parameter int HEAD_DIM   = 128,
    parameter int Q_HEADS    = 4
)(
    input  logic                     clk,
    input  logic                     rst_n,

    input  logic                     start,
    output logic                     busy,
    output logic                     done,

    output logic                     vec_ready,
    input  logic                     vec_valid,
    input  logic [TILE*16-1:0]       p_vec_bf16,
    input  logic [TILE*16-1:0]       v_vec_bf16,

    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0]
                                           req_head,
    output logic [((QUERY_LEN <= 1) ? 1 : $clog2(QUERY_LEN))-1:0]
                                           req_row_base,
    output logic [((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM))-1:0]
                                           req_col_base,
    output logic [((REDUCE_LEN <= 1) ? 1 : $clog2(REDUCE_LEN))-1:0]
                                           req_reduce,

    output logic                     context_valid,
    input  logic                     context_ready,
    output logic [15:0]              context_bf16,
    output logic [31:0]              context_fp32_debug,
    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0]
                                           context_head,
    output logic [((QUERY_LEN <= 1) ? 1 : $clog2(QUERY_LEN))-1:0]
                                           context_row,
    output logic [((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM))-1:0]
                                           context_col,
    output logic                     context_last
);

    localparam int HEAD_W =
        (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS);
    localparam int ROW_W =
        (QUERY_LEN <= 1) ? 1 : $clog2(QUERY_LEN);
    localparam int COL_W =
        (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM);
    localparam int RED_W =
        (REDUCE_LEN <= 1) ? 1 : $clog2(REDUCE_LEN);
    localparam int LOC_W =
        (TILE <= 1) ? 1 : $clog2(TILE);

    typedef enum logic [2:0] {
        S_IDLE       = 3'd0,
        S_START_TILE = 3'd1,
        S_FEED_TILE  = 3'd2,
        S_WAIT_TILE  = 3'd3
    } state_t;

    state_t state;

    logic [HEAD_W-1:0] head_reg;
    logic [ROW_W-1:0]  row_base_reg;
    logic [COL_W-1:0]  col_base_reg;
    logic [RED_W-1:0]  reduce_reg;

    logic tile_start;
    logic tile_busy;
    logic tile_done;
    logic tile_in_ready;
    logic tile_out_valid;
    logic tile_out_ready;
    logic [15:0] tile_out_context;
    logic [31:0] tile_out_fp32;
    logic [LOC_W-1:0] tile_local_row;
    logic [LOC_W-1:0] tile_local_col;
    logic tile_out_last;

    assign busy = (state != S_IDLE);

    assign req_head     = head_reg;
    assign req_row_base = row_base_reg;
    assign req_col_base = col_base_reg;
    assign req_reduce   = reduce_reg;

    assign vec_ready =
        (state == S_FEED_TILE) && tile_in_ready;

    assign context_valid      = tile_out_valid;
    assign context_bf16       = tile_out_context;
    assign context_fp32_debug = tile_out_fp32;
    assign context_head       = head_reg;
    assign context_row        =
        row_base_reg + tile_local_row;
    assign context_col        =
        col_base_reg + tile_local_col;
    assign context_last       =
        (head_reg == Q_HEADS-1) &&
        ((row_base_reg + tile_local_row) == QUERY_LEN-1) &&
        ((col_base_reg + tile_local_col) == HEAD_DIM-1);

    assign tile_out_ready = context_ready;

    pv_systolic_tile #(
        .TILE       (TILE),
        .REDUCE_LEN (REDUCE_LEN)
    ) u_tile (
        .clk                       (clk),
        .rst_n                     (rst_n),
        .tile_start                (tile_start),
        .tile_busy                 (tile_busy),
        .tile_done                 (tile_done),
        .in_valid                  (
            (state == S_FEED_TILE) && vec_valid
        ),
        .in_ready                  (tile_in_ready),
        .p_rows_bf16               (p_vec_bf16),
        .v_cols_bf16               (v_vec_bf16),
        .out_valid                 (tile_out_valid),
        .out_ready                 (tile_out_ready),
        .out_context_bf16          (tile_out_context),
        .out_local_row             (tile_local_row),
        .out_local_col             (tile_local_col),
        .out_last                  (tile_out_last),
        .out_context_fp32_debug    (tile_out_fp32)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            done         <= 1'b0;
            tile_start   <= 1'b0;
            head_reg     <= '0;
            row_base_reg <= '0;
            col_base_reg <= '0;
            reduce_reg   <= '0;
        end else begin
            done       <= 1'b0;
            tile_start <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        head_reg     <= '0;
                        row_base_reg <= '0;
                        col_base_reg <= '0;
                        reduce_reg   <= '0;
                        state        <= S_START_TILE;
                    end
                end

                S_START_TILE: begin
                    tile_start <= 1'b1;
                    reduce_reg <= '0;
                    state      <= S_FEED_TILE;
                end

                S_FEED_TILE: begin
                    if (vec_valid && vec_ready) begin
                        if (reduce_reg == REDUCE_LEN-1) begin
                            state <= S_WAIT_TILE;
                        end else begin
                            reduce_reg <= reduce_reg + 1'b1;
                        end
                    end
                end

                S_WAIT_TILE: begin
                    if (tile_done) begin
                        if (col_base_reg + TILE < HEAD_DIM) begin
                            col_base_reg <= col_base_reg + TILE;
                            reduce_reg   <= '0;
                            state        <= S_START_TILE;
                        end else begin
                            col_base_reg <= '0;

                            if (row_base_reg + TILE < QUERY_LEN) begin
                                row_base_reg <= row_base_reg + TILE;
                                reduce_reg   <= '0;
                                state        <= S_START_TILE;
                            end else begin
                                row_base_reg <= '0;

                                if (head_reg + 1 < Q_HEADS) begin
                                    head_reg   <= head_reg + 1'b1;
                                    reduce_reg <= '0;
                                    state      <= S_START_TILE;
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
        if ((QUERY_LEN % TILE) != 0)
            $error(
                "pv_systolic_gqa_top: QUERY_LEN must be divisible by TILE"
            );
        if ((HEAD_DIM % TILE) != 0)
            $error(
                "pv_systolic_gqa_top: HEAD_DIM must be divisible by TILE"
            );
        if (REDUCE_LEN < 1)
            $error(
                "pv_systolic_gqa_top: REDUCE_LEN must be >= 1"
            );
    end

endmodule
