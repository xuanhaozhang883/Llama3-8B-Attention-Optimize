`timescale 1ns/1ps

// QK tile-major score stream -> causal mask -> complete row-major stream.
module qk_softmax_adapter #(
    parameter int SCORE_W  = 16,
    parameter int SEQ_LEN  = 128,
    parameter int TILE     = 4,
    parameter int Q_HEADS  = 4,
    parameter int HEAD_W   = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int POS_W    = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter logic [SCORE_W-1:0] MASK_VALUE = 16'hFF80,
    parameter bit STRICT_TILE_ORDER = 1'b1
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 causal_en,

    input  logic                 qk_valid,
    output logic                 qk_ready,
    input  logic [SCORE_W-1:0]   qk_score,
    input  logic [HEAD_W-1:0]    qk_head,
    input  logic [POS_W-1:0]     qk_row,
    input  logic [POS_W-1:0]     qk_col,
    input  logic                 qk_global_last,

    output logic                 row_valid,
    input  logic                 row_ready,
    output logic [SCORE_W-1:0]   row_data,
    output logic                 row_mask,
    output logic [HEAD_W-1:0]    row_head,
    output logic [POS_W-1:0]     row_index,
    output logic [POS_W-1:0]     row_col,
    output logic                 row_first,
    output logic                 row_last,
    output logic                 row_global_last,

    output logic                 busy,
    output logic                 protocol_error,
    output logic                 global_last_error
);

    logic                 mask_valid;
    logic                 mask_ready;
    logic [SCORE_W-1:0]   mask_score;
    logic                 mask_bit;
    logic [HEAD_W-1:0]    mask_head;
    logic [POS_W-1:0]     mask_row;
    logic [POS_W-1:0]     mask_col;
    logic                 mask_global_last;
    logic                 buffer_busy;
    logic                 expected_qk_global_last;

    assign expected_qk_global_last =
        ($unsigned(qk_head) == Q_HEADS-1) &&
        ($unsigned(qk_row)  == SEQ_LEN-1) &&
        ($unsigned(qk_col)  == SEQ_LEN-1);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            global_last_error <= 1'b0;
        end else if (qk_valid && qk_ready) begin
            if (qk_global_last !== expected_qk_global_last)
                global_last_error <= 1'b1;
        end
    end

    causal_mask_stream #(
        .SCORE_W(SCORE_W), .HEAD_W(HEAD_W), .POS_W(POS_W)
    ) u_causal_mask (
        .clk(clk), .rst_n(rst_n), .causal_en(causal_en),
        .mask_value(MASK_VALUE),
        .s_valid(qk_valid), .s_ready(qk_ready), .s_score(qk_score),
        .s_head(qk_head), .s_row(qk_row), .s_col(qk_col),
        .s_global_last(qk_global_last),
        .m_valid(mask_valid), .m_ready(mask_ready), .m_score(mask_score),
        .m_mask(mask_bit), .m_head(mask_head), .m_row(mask_row),
        .m_col(mask_col), .m_global_last(mask_global_last)
    );

    score_rowtile_buffer #(
        .SCORE_W(SCORE_W), .SEQ_LEN(SEQ_LEN), .TILE(TILE),
        .HEAD_W(HEAD_W), .POS_W(POS_W),
        .STRICT_TILE_ORDER(STRICT_TILE_ORDER)
    ) u_rowtile_buffer (
        .clk(clk), .rst_n(rst_n),
        .s_valid(mask_valid), .s_ready(mask_ready), .s_score(mask_score),
        .s_mask(mask_bit), .s_head(mask_head), .s_row(mask_row), .s_col(mask_col),
        .m_valid(row_valid), .m_ready(row_ready), .m_data(row_data),
        .m_mask(row_mask), .m_head(row_head), .m_row(row_index),
        .m_col(row_col), .m_first(row_first), .m_last(row_last),
        .busy(buffer_busy), .protocol_error(protocol_error)
    );

    assign row_global_last = row_valid && row_last &&
                             ($unsigned(row_head) == Q_HEADS-1) &&
                             ($unsigned(row_index) == SEQ_LEN-1) &&
                             ($unsigned(row_col) == SEQ_LEN-1);
    // Include a presented QK item so busy is already high on the first transfer.
    assign busy = buffer_busy || mask_valid || qk_valid;

    // The registered marker is checked at the QK boundary above; row boundaries
    // are always regenerated from row/column metadata.
    logic unused_mask_global_last;
    assign unused_mask_global_last = mask_global_last;

    initial begin
        if (SCORE_W != 16)
            $warning("qk_softmax_adapter: project data format is BF16 (16 bits)");
    end
endmodule
