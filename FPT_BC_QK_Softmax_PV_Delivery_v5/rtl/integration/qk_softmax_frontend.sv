`timescale 1ns/1ps

// QK score stream -> mask/reorder adapter -> BF16 Softmax.
// This module processes one local GQA group. Group ID is attached by the
// outer qk_softmax_pipeline_top because it is constant for the whole launch.
module qk_softmax_frontend #(
    parameter int SEQ_LEN = 128,
    parameter int TILE    = 4,
    parameter int Q_HEADS = 4,
    parameter int HEAD_W  = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int POS_W   = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter EXP_LUT_FILE = "exp_lut_q15.mem"
) (
    input  logic                 clk,
    input  logic                 rst_n,
    input  logic                 causal_en,

    input  logic                 qk_valid,
    output logic                 qk_ready,
    input  logic [15:0]          qk_score,
    input  logic [HEAD_W-1:0]    qk_head,
    input  logic [POS_W-1:0]     qk_row,
    input  logic [POS_W-1:0]     qk_col,
    input  logic                 qk_global_last,

    output logic                 prob_valid,
    input  logic                 prob_ready,
    output logic [15:0]          prob_data,
    output logic                 prob_first,
    output logic                 prob_last,
    output logic                 prob_group_last,

    // Compatibility alias retained from v3.
    output logic                 prob_global_last,

    output logic [HEAD_W-1:0]    prob_head,
    output logic [POS_W-1:0]     prob_row,
    output logic [POS_W-1:0]     prob_col,
    output logic                 group_done,

    // Compatibility alias retained from v3.
    output logic                 pipeline_done,

    output logic                 busy,
    output logic                 adapter_protocol_error,
    output logic                 adapter_global_last_error,
    output logic                 softmax_row_error,
    output logic                 softmax_metadata_error
);

    logic              row_valid;
    logic              row_ready;
    logic [15:0]       row_data;
    logic              row_mask;
    logic [HEAD_W-1:0] row_head;
    logic [POS_W-1:0]  row_index;
    logic [POS_W-1:0]  row_col;
    logic              row_first;
    logic              row_last;
    logic              row_global_last;
    logic              adapter_busy;
    logic              softmax_busy;

    qk_softmax_adapter #(
        .SCORE_W(16), .SEQ_LEN(SEQ_LEN), .TILE(TILE), .Q_HEADS(Q_HEADS),
        .HEAD_W(HEAD_W), .POS_W(POS_W)
    ) u_adapter (
        .clk(clk), .rst_n(rst_n), .causal_en(causal_en),
        .qk_valid(qk_valid), .qk_ready(qk_ready), .qk_score(qk_score),
        .qk_head(qk_head), .qk_row(qk_row), .qk_col(qk_col),
        .qk_global_last(qk_global_last),
        .row_valid(row_valid), .row_ready(row_ready), .row_data(row_data),
        .row_mask(row_mask), .row_head(row_head), .row_index(row_index),
        .row_col(row_col), .row_first(row_first), .row_last(row_last),
        .row_global_last(row_global_last), .busy(adapter_busy),
        .protocol_error(adapter_protocol_error),
        .global_last_error(adapter_global_last_error)
    );

    softmax_bf16 #(
        .MAX_LEN(SEQ_LEN), .HEAD_W(HEAD_W), .POS_W(POS_W),
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_softmax (
        .clk(clk), .rst_n(rst_n),
        .in_valid(row_valid), .in_ready(row_ready), .in_data(row_data),
        .in_last(row_last), .in_mask(row_mask), .in_head(row_head),
        .in_row(row_index), .in_col(row_col),
        .out_valid(prob_valid), .out_ready(prob_ready), .out_data(prob_data),
        .out_first(prob_first), .out_last(prob_last), .out_head(prob_head),
        .out_row(prob_row), .out_col(prob_col), .busy(softmax_busy),
        .row_error(softmax_row_error), .metadata_error(softmax_metadata_error)
    );

    assign prob_group_last = prob_valid && prob_last &&
                             ($unsigned(prob_head) == Q_HEADS-1) &&
                             ($unsigned(prob_row) == SEQ_LEN-1) &&
                             ($unsigned(prob_col) == SEQ_LEN-1);

    // v3 compatibility aliases.
    assign prob_global_last = prob_group_last;
    assign group_done       = prob_valid && prob_ready && prob_group_last;
    assign pipeline_done    = group_done;
    assign busy             = adapter_busy || softmax_busy;

    logic unused_row_first;
    logic unused_row_global_last;
    assign unused_row_first       = row_first;
    assign unused_row_global_last = row_global_last;
endmodule
