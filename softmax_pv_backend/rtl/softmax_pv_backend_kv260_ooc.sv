`timescale 1ns/1ps

// Fixed-parameter wrapper for KV260 out-of-context synthesis only.
// The final board design should instantiate softmax_pv_backend inside the
// system top and connect its clock/reset, V memory adapter and PV MAC.
module softmax_pv_backend_kv260_ooc (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic [2:0] group_id,

    input  logic        prob_valid,
    output logic        prob_ready,
    input  logic [15:0] prob_data,
    input  logic [2:0]  prob_group_id,
    input  logic [4:0]  prob_head,
    input  logic [6:0]  prob_row,
    input  logic [6:0]  prob_col,
    input  logic        prob_first,
    input  logic        prob_last,
    input  logic        prob_group_last,

    output logic        v_req_valid,
    input  logic        v_req_ready,
    output logic [2:0]  v_req_kv_head,
    output logic [6:0]  v_req_reduce_index,
    output logic [6:0]  v_req_feature_base,
    output logic [16:0] v_req_addr,
    input  logic        v_rsp_valid,
    output logic        v_rsp_ready,
    input  logic [31:0] v_rsp_data,

    output logic [31:0] p_vec_bf16,
    output logic [31:0] v_vec_bf16,
    output logic        vec_valid,
    input  logic        vec_ready,
    output logic        vec_first,
    output logic        vec_last,
    output logic [4:0]  vec_head,
    output logic [6:0]  vec_row_base,
    output logic [6:0]  vec_feature_base,
    output logic [6:0]  vec_reduce_index,

    output logic done,
    output logic busy,
    output logic protocol_error
);

    (* keep_hierarchy = "yes" *) softmax_pv_backend #(
        .Q_HEADS(32),
        .KV_HEADS(8),
        .V_KV_HEADS(8),
        .USE_GROUP_ID_FOR_KV(1'b0),
        .SEQ_LEN(128),
        .HEAD_DIM(128),
        .TILE(2)
    ) u_backend (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .group_id(group_id),
        .prob_valid(prob_valid),
        .prob_ready(prob_ready),
        .prob_data(prob_data),
        .prob_group_id(prob_group_id),
        .prob_head(prob_head),
        .prob_row(prob_row),
        .prob_col(prob_col),
        .prob_first(prob_first),
        .prob_last(prob_last),
        .prob_group_last(prob_group_last),
        .v_req_valid(v_req_valid),
        .v_req_ready(v_req_ready),
        .v_req_kv_head(v_req_kv_head),
        .v_req_reduce_index(v_req_reduce_index),
        .v_req_feature_base(v_req_feature_base),
        .v_req_addr(v_req_addr),
        .v_rsp_valid(v_rsp_valid),
        .v_rsp_ready(v_rsp_ready),
        .v_rsp_data(v_rsp_data),
        .p_vec_bf16(p_vec_bf16),
        .v_vec_bf16(v_vec_bf16),
        .vec_valid(vec_valid),
        .vec_ready(vec_ready),
        .vec_first(vec_first),
        .vec_last(vec_last),
        .vec_head(vec_head),
        .vec_row_base(vec_row_base),
        .vec_feature_base(vec_feature_base),
        .vec_reduce_index(vec_reduce_index),
        .done(done),
        .busy(busy),
        .protocol_error(protocol_error)
    );

endmodule
