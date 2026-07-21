`timescale 1ns/1ps

// 固定为2x2 PE、4Q/1K、SEQ=128、HEAD_DIM=128的综合配置。
// 用于直接查看TILE=2的资源和时序，不包含BRAM/DDR loader。
module qk_systolic_gqa_tile2_cfg (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    output logic        busy,
    output logic        done,

    output logic        vec_ready,
    input  logic        vec_valid,
    input  logic [31:0] q_vec_bf16,
    input  logic [31:0] k_vec_bf16,

    output logic [1:0]  req_head,
    output logic [6:0]  req_row_base,
    output logic [6:0]  req_col_base,
    output logic [6:0]  req_dim,

    output logic        score_valid,
    input  logic        score_ready,
    output logic [15:0] score_bf16,
    output logic [31:0] score_fp32_debug,
    output logic [1:0]  score_head,
    output logic [6:0]  score_row,
    output logic [6:0]  score_col,
    output logic        score_last
);

    qk_systolic_gqa_top #(
        .TILE     (2),
        .SEQ_LEN  (128),
        .HEAD_DIM (128),
        .Q_HEADS  (4)
    ) u_qk (
        .clk                (clk),
        .rst_n              (rst_n),
        .start              (start),
        .busy               (busy),
        .done               (done),
        .vec_ready          (vec_ready),
        .vec_valid          (vec_valid),
        .q_vec_bf16         (q_vec_bf16),
        .k_vec_bf16         (k_vec_bf16),
        .req_head           (req_head),
        .req_row_base       (req_row_base),
        .req_col_base       (req_col_base),
        .req_dim            (req_dim),
        .score_valid        (score_valid),
        .score_ready        (score_ready),
        .score_bf16         (score_bf16),
        .score_fp32_debug   (score_fp32_debug),
        .score_head         (score_head),
        .score_row          (score_row),
        .score_col          (score_col),
        .score_last         (score_last)
    );

endmodule
