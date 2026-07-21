`timescale 1ns/1ps

// Fixed synthesis configuration for the uploaded PV workload.
module pv_systolic_gqa_tile4_cfg (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    output logic        busy,
    output logic        done,

    output logic        vec_ready,
    input  logic        vec_valid,
    input  logic [63:0] p_vec_bf16,
    input  logic [63:0] v_vec_bf16,

    output logic [1:0]  req_head,
    output logic [6:0]  req_row_base,
    output logic [6:0]  req_col_base,
    output logic [6:0]  req_reduce,

    output logic        context_valid,
    input  logic        context_ready,
    output logic [15:0] context_bf16,
    output logic [31:0] context_fp32_debug,
    output logic [1:0]  context_head,
    output logic [6:0]  context_row,
    output logic [6:0]  context_col,
    output logic        context_last
);

    pv_systolic_gqa_top #(
        .TILE       (4),
        .QUERY_LEN  (128),
        .REDUCE_LEN (128),
        .HEAD_DIM   (128),
        .Q_HEADS    (4)
    ) u_pv (
        .clk                (clk),
        .rst_n              (rst_n),
        .start              (start),
        .busy               (busy),
        .done               (done),
        .vec_ready          (vec_ready),
        .vec_valid          (vec_valid),
        .p_vec_bf16         (p_vec_bf16),
        .v_vec_bf16         (v_vec_bf16),
        .req_head           (req_head),
        .req_row_base       (req_row_base),
        .req_col_base       (req_col_base),
        .req_reduce         (req_reduce),
        .context_valid      (context_valid),
        .context_ready      (context_ready),
        .context_bf16       (context_bf16),
        .context_fp32_debug (context_fp32_debug),
        .context_head       (context_head),
        .context_row        (context_row),
        .context_col        (context_col),
        .context_last       (context_last)
    );

endmodule
