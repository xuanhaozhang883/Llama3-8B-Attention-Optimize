`timescale 1ns/1ps

// Formal one-Group RoPE -> QK -> Mask -> Softmax -> P/PV-input integration.
// Raw memory returns split-half pairs; Q/K vector loading is internal.
module rope_qk_softmax_pv_pipeline_top #(
    parameter int QK_TILE=4, PV_TILE=2, SEQ_LEN=128, HEAD_DIM=128,
    parameter int Q_HEADS=4, GQA_GROUPS=8,
    parameter int HEAD_W=(Q_HEADS<=1)?1:$clog2(Q_HEADS),
    parameter int GROUP_W=(GQA_GROUPS<=1)?1:$clog2(GQA_GROUPS),
    parameter int GLOBAL_Q_HEAD_W=((Q_HEADS*GQA_GROUPS)<=1)?1:$clog2(Q_HEADS*GQA_GROUPS),
    parameter int POS_W=(SEQ_LEN<=1)?1:$clog2(SEQ_LEN),
    parameter int DIM_W=(HEAD_DIM<=1)?1:$clog2(HEAD_DIM),
    parameter int PAIR_W=((HEAD_DIM/2)<=1)?1:$clog2(HEAD_DIM/2),
    parameter int V_ADDR_W=((GQA_GROUPS*SEQ_LEN*HEAD_DIM)<=1)?1:$clog2(GQA_GROUPS*SEQ_LEN*HEAD_DIM),
    parameter int ROM_DEPTH=SEQ_LEN*(HEAD_DIM/2),
    parameter logic [31:0] SCALE_FP32=32'h3DB504F3,
    parameter EXP_LUT_FILE="exp_lut_q15.mem",
    parameter SIN_ROM_FILE="sin_bf16.hex",
    parameter COS_ROM_FILE="cos_bf16.hex"
) (
    input logic clk, rst_n,
    input logic group_start,
    input logic [GROUP_W-1:0] group_id,
    output logic group_start_ready,
    output logic [GROUP_W-1:0] active_group_id,
    input logic causal_en,

    output logic raw_req_valid,
    input logic raw_req_ready,
    output logic raw_req_is_k,
    output logic [GLOBAL_Q_HEAD_W-1:0] raw_req_head,
    output logic [POS_W-1:0] raw_req_token,
    output logic [PAIR_W-1:0] raw_req_pair,
    input logic raw_rsp_valid,
    output logic raw_rsp_ready,
    input logic [15:0] raw_rsp_x0, raw_rsp_x1,

    output logic v_req_valid,
    input logic v_req_ready,
    output logic [GROUP_W-1:0] v_req_kv_head,
    output logic [POS_W-1:0] v_req_reduce_index,
    output logic [DIM_W-1:0] v_req_feature_base,
    output logic [V_ADDR_W-1:0] v_req_addr,
    input logic v_rsp_valid,
    output logic v_rsp_ready,
    input logic [PV_TILE*16-1:0] v_rsp_data,

    output logic [PV_TILE*16-1:0] p_vec_bf16, v_vec_bf16,
    output logic pv_vec_valid,
    input logic pv_vec_ready,
    output logic pv_vec_first, pv_vec_last, pv_vec_group_last,
    output logic [GROUP_W-1:0] pv_vec_group_id,
    output logic [HEAD_W-1:0] pv_vec_head,
    output logic [GLOBAL_Q_HEAD_W-1:0] pv_vec_global_q_head,
    output logic [POS_W-1:0] pv_vec_row_base,
    output logic [DIM_W-1:0] pv_vec_feature_base,
    output logic [POS_W-1:0] pv_vec_reduce_index,

    output logic [HEAD_W-1:0] req_head,
    output logic [GROUP_W-1:0] req_group_id,
    output logic [GLOBAL_Q_HEAD_W-1:0] req_global_q_head,
    output logic [GROUP_W-1:0] req_kv_head,
    output logic [POS_W-1:0] req_row_base, req_col_base,
    output logic [DIM_W-1:0] req_dim,
    output logic mon_prob_valid, mon_prob_ready,
    output logic [15:0] mon_prob_data,
    output logic [GROUP_W-1:0] mon_prob_group_id,
    output logic [HEAD_W-1:0] mon_prob_head,
    output logic [POS_W-1:0] mon_prob_row, mon_prob_col,
    output logic mon_prob_first, mon_prob_last, mon_prob_group_last,
    output logic rope_busy, rope_done, qk_busy, qk_done,
    output logic b_frontend_busy, c_backend_busy, busy, prob_input_done, done,
    output logic protocol_error
);
    logic bridge_start_ready, pipeline_start, pipeline_start_ready;
    logic [GROUP_W-1:0] pipeline_group_id;
    logic pipeline_busy, pipeline_done;
    logic qk_vec_ready, qk_vec_valid;
    logic [QK_TILE*16-1:0] q_vec_bf16, k_vec_bf16;
    logic pipeline_error;
    logic wrapper_start_error;
    logic unused_start_busy, unused_invalid_group;
    logic unused_adapter_protocol, unused_adapter_last;
    logic unused_softmax_row, unused_softmax_metadata, unused_c_protocol;

    assign group_start_ready = bridge_start_ready;
    assign busy = rope_busy || pipeline_busy;
    assign done = pipeline_done;
    assign protocol_error = wrapper_start_error || pipeline_error;

    always_ff @(posedge clk) begin
        if (!rst_n)
            wrapper_start_error <= 1'b0;
        else begin
            if (group_start && group_start_ready)
                wrapper_start_error <= 1'b0;
            else if (group_start && !group_start_ready)
                wrapper_start_error <= 1'b1;
        end
    end

    rope_group_bridge #(
        .QK_TILE(QK_TILE), .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS), .GQA_GROUPS(GQA_GROUPS), .HEAD_W(HEAD_W),
        .GROUP_W(GROUP_W), .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W),
        .POS_W(POS_W), .DIM_W(DIM_W), .PAIR_W(PAIR_W),
        .ROM_DEPTH(ROM_DEPTH), .SIN_ROM_FILE(SIN_ROM_FILE),
        .COS_ROM_FILE(COS_ROM_FILE)
    ) u_rope_bridge (
        .clk, .rst_n, .group_start, .group_id,
        .group_start_ready(bridge_start_ready), .active_group_id,
        .busy(rope_busy), .rope_done,
        .raw_req_valid, .raw_req_ready, .raw_req_is_k, .raw_req_head,
        .raw_req_token, .raw_req_pair, .raw_rsp_valid, .raw_rsp_ready,
        .raw_rsp_x0, .raw_rsp_x1,
        .pipeline_group_start(pipeline_start),
        .pipeline_group_start_ready(pipeline_start_ready),
        .pipeline_group_id, .pipeline_done,
        .req_head, .req_row_base, .req_col_base, .req_dim,
        .qk_vec_ready, .qk_vec_valid, .q_vec_bf16, .k_vec_bf16
    );

    qk_softmax_pv_pipeline_top #(
        .QK_TILE(QK_TILE), .PV_TILE(PV_TILE), .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM), .Q_HEADS(Q_HEADS), .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W), .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W), .POS_W(POS_W), .DIM_W(DIM_W),
        .V_ADDR_W(V_ADDR_W), .SCALE_FP32(SCALE_FP32),
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_pipeline (
        .clk, .rst_n, .group_start(pipeline_start), .group_id(pipeline_group_id),
        .group_start_ready(pipeline_start_ready), .active_group_id(), .causal_en,
        .qk_vec_ready, .qk_vec_valid, .q_vec_bf16, .k_vec_bf16,
        .req_head, .req_group_id, .req_global_q_head, .req_kv_head,
        .req_row_base, .req_col_base, .req_dim,
        .v_req_valid, .v_req_ready, .v_req_kv_head, .v_req_reduce_index,
        .v_req_feature_base, .v_req_addr, .v_rsp_valid, .v_rsp_ready, .v_rsp_data,
        .p_vec_bf16, .v_vec_bf16, .pv_vec_valid, .pv_vec_ready,
        .pv_vec_first, .pv_vec_last, .pv_vec_group_last, .pv_vec_group_id,
        .pv_vec_head, .pv_vec_global_q_head, .pv_vec_row_base,
        .pv_vec_feature_base, .pv_vec_reduce_index,
        .mon_prob_valid, .mon_prob_ready, .mon_prob_data, .mon_prob_group_id,
        .mon_prob_head, .mon_prob_row, .mon_prob_col, .mon_prob_first,
        .mon_prob_last, .mon_prob_group_last,
        .qk_busy, .qk_done, .b_frontend_busy, .c_backend_busy,
        .busy(pipeline_busy), .prob_input_done, .done(pipeline_done),
        .start_while_busy_error(unused_start_busy),
        .invalid_group_id_error(unused_invalid_group),
        .adapter_protocol_error(unused_adapter_protocol),
        .adapter_global_last_error(unused_adapter_last),
        .softmax_row_error(unused_softmax_row),
        .softmax_metadata_error(unused_softmax_metadata),
        .c_protocol_error(unused_c_protocol), .protocol_error(pipeline_error)
    );
endmodule
