`timescale 1ns/1ps

// Complete Softmax-output to PV-input backend.
module softmax_pv_backend #(
    parameter int Q_HEADS = 4,
    parameter int KV_HEADS = 1,
    parameter int V_KV_HEADS = KV_HEADS,
    parameter bit USE_GROUP_ID_FOR_KV = 1'b0,
    parameter int SEQ_LEN = 128,
    parameter int HEAD_DIM = 128,
    parameter int TILE = 2
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    input  logic [2:0] group_id,

    input  logic        prob_valid,
    output logic        prob_ready,
    input  logic [15:0] prob_data,
    input  logic [2:0]  prob_group_id,
    input  logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] prob_head,
    input  logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] prob_row,
    input  logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] prob_col,
    input  logic        prob_first,
    input  logic        prob_last,
    input  logic        prob_group_last,

    output logic        v_req_valid,
    input  logic        v_req_ready,
    output logic [((V_KV_HEADS <= 1) ? 1 : $clog2(V_KV_HEADS))-1:0] v_req_kv_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] v_req_reduce_index,
    output logic [((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM))-1:0] v_req_feature_base,
    output logic [(((V_KV_HEADS*SEQ_LEN*HEAD_DIM) <= 1) ? 1 : $clog2(V_KV_HEADS*SEQ_LEN*HEAD_DIM))-1:0] v_req_addr,
    input  logic        v_rsp_valid,
    output logic        v_rsp_ready,
    input  logic [TILE*16-1:0] v_rsp_data,

    output logic [TILE*16-1:0] p_vec_bf16,
    output logic [TILE*16-1:0] v_vec_bf16,
    output logic        vec_valid,
    input  logic        vec_ready,
    output logic        vec_first,
    output logic        vec_last,
    output logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] vec_head,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] vec_row_base,
    output logic [((HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM))-1:0] vec_feature_base,
    output logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] vec_reduce_index,

    output logic        done,
    output logic        busy,
    output logic        protocol_error
);

    logic p_tile_valid;
    logic p_tile_ready;
    logic [((Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS))-1:0] p_tile_head;
    logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] p_tile_row_base;
    logic p_tile_release;

    logic p_req_valid;
    logic p_req_ready;
    logic [((SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN))-1:0] p_req_reduce_index;
    logic p_rsp_valid;
    logic p_rsp_ready;
    logic [TILE*16-1:0] p_rsp_data;

    logic p_input_done;
    logic p_buffer_busy;
    logic p_buffer_error;
    logic loader_busy;
    logic loader_error;
    logic loader_done;

    assign busy = p_buffer_busy || loader_busy;
    // loader_done is generated after the final bank-release edge. Requiring
    // both children idle makes done an unambiguous transaction-complete pulse.
    assign done = loader_done && p_input_done && !p_buffer_busy && !loader_busy;
    assign protocol_error = p_buffer_error || loader_error;

    softmax_output_buffer #(
        .Q_HEADS(Q_HEADS),
        .SEQ_LEN(SEQ_LEN),
        .TILE(TILE)
    ) u_p_buffer (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .active_group_id(group_id),
        .s_valid(prob_valid),
        .s_ready(prob_ready),
        .s_data(prob_data),
        .s_group_id(prob_group_id),
        .s_head(prob_head),
        .s_row(prob_row),
        .s_col(prob_col),
        .s_first(prob_first),
        .s_last(prob_last),
        .s_group_last(prob_group_last),
        .p_tile_valid(p_tile_valid),
        .p_tile_ready(p_tile_ready),
        .p_tile_head(p_tile_head),
        .p_tile_row_base(p_tile_row_base),
        .p_req_valid(p_req_valid),
        .p_req_ready(p_req_ready),
        .p_req_reduce_index(p_req_reduce_index),
        .p_rsp_valid(p_rsp_valid),
        .p_rsp_ready(p_rsp_ready),
        .p_rsp_data(p_rsp_data),
        .p_tile_release(p_tile_release),
        .input_done(p_input_done),
        .busy(p_buffer_busy),
        .protocol_error(p_buffer_error)
    );

    pv_input_loader #(
        .Q_HEADS(Q_HEADS),
        .KV_HEADS(KV_HEADS),
        .V_KV_HEADS(V_KV_HEADS),
        .USE_GROUP_ID_FOR_KV(USE_GROUP_ID_FOR_KV),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .TILE(TILE)
    ) u_loader (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .group_id(group_id),
        .p_tile_valid(p_tile_valid),
        .p_tile_ready(p_tile_ready),
        .p_tile_head(p_tile_head),
        .p_tile_row_base(p_tile_row_base),
        .p_tile_release(p_tile_release),
        .p_req_valid(p_req_valid),
        .p_req_ready(p_req_ready),
        .p_req_reduce_index(p_req_reduce_index),
        .p_rsp_valid(p_rsp_valid),
        .p_rsp_ready(p_rsp_ready),
        .p_rsp_data(p_rsp_data),
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
        .done(loader_done),
        .busy(loader_busy),
        .protocol_error(loader_error)
    );

endmodule
