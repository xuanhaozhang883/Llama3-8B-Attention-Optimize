`timescale 1ns/1ps

// System shell: one start prepares and executes every GQA Group in order.
// Raw Q/K pairs are supplied by the surrounding memory adapter; V is loaded
// through the existing synthesizable cache interface.
module rope_qk_softmax_pv_system_top #(
    parameter int QK_TILE=4, PV_TILE=2, SEQ_LEN=128, HEAD_DIM=128,
    parameter int Q_HEADS=4, GQA_GROUPS=8,
    parameter int HEAD_W=(Q_HEADS<=1)?1:$clog2(Q_HEADS),
    parameter int GROUP_W=(GQA_GROUPS<=1)?1:$clog2(GQA_GROUPS),
    parameter int GLOBAL_Q_HEAD_W=((Q_HEADS*GQA_GROUPS)<=1)?1:$clog2(Q_HEADS*GQA_GROUPS),
    parameter int POS_W=(SEQ_LEN<=1)?1:$clog2(SEQ_LEN),
    parameter int DIM_W=(HEAD_DIM<=1)?1:$clog2(HEAD_DIM),
    parameter int PAIR_W=((HEAD_DIM/2)<=1)?1:$clog2(HEAD_DIM/2),
    parameter int V_ADDR_W=((GQA_GROUPS*SEQ_LEN*HEAD_DIM)<=1)?1:$clog2(GQA_GROUPS*SEQ_LEN*HEAD_DIM),
    parameter logic [31:0] SCALE_FP32=32'h3DB504F3,
    parameter EXP_LUT_FILE="exp_lut_q15.mem",
    parameter SIN_ROM_FILE="sin_bf16.hex",
    parameter COS_ROM_FILE="cos_bf16.hex"
) (
    input logic clk, rst_n, start,
    output logic start_ready, busy, done,
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
    input logic v_load_valid,
    output logic v_load_ready,
    input logic [V_ADDR_W-1:0] v_load_addr,
    input logic [PV_TILE*16-1:0] v_load_data,
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
    output logic [GROUP_W-1:0] active_group_id, completed_group_id,
    output logic group_complete, rope_done,
    output logic protocol_error
);
    logic group_launch, group_launch_ready, group_done;
    logic [GROUP_W-1:0] launch_group_id;
    logic controller_busy, controller_done, controller_error, controller_start_error;
    logic pipeline_busy, pipeline_error;
    logic v_req_valid, v_req_ready, v_rsp_valid, v_rsp_ready;
    logic [GROUP_W-1:0] v_req_kv_head;
    logic [POS_W-1:0] v_req_reduce_index;
    logic [DIM_W-1:0] v_req_feature_base;
    logic [V_ADDR_W-1:0] v_req_addr;
    logic [PV_TILE*16-1:0] v_rsp_data;
    logic v_cache_error;

    assign busy=controller_busy || pipeline_busy;
    assign done=controller_done;
    assign protocol_error=controller_error || controller_start_error ||
                          pipeline_error || v_cache_error;

    gqa_group_controller #(.NUM_GROUPS(GQA_GROUPS),.GROUP_W(GROUP_W)) u_controller (
        .clk,.rst_n,.start,.start_ready,.busy(controller_busy),.done(controller_done),
        .group_start(group_launch),.group_start_ready(group_launch_ready),
        .group_id(launch_group_id),.group_done,
        .group_protocol_error(pipeline_error||v_cache_error),
        .group_complete,.completed_group_id,
        .start_while_busy_error(controller_start_error),.protocol_error(controller_error)
    );

    rope_qk_softmax_pv_pipeline_top #(
        .QK_TILE(QK_TILE),.PV_TILE(PV_TILE),.SEQ_LEN(SEQ_LEN),.HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),.GQA_GROUPS(GQA_GROUPS),.HEAD_W(HEAD_W),.GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W),.POS_W(POS_W),.DIM_W(DIM_W),
        .PAIR_W(PAIR_W),.V_ADDR_W(V_ADDR_W),.SCALE_FP32(SCALE_FP32),
        .EXP_LUT_FILE(EXP_LUT_FILE),.SIN_ROM_FILE(SIN_ROM_FILE),.COS_ROM_FILE(COS_ROM_FILE)
    ) u_group_pipeline (
        .clk,.rst_n,.group_start(group_launch),.group_id(launch_group_id),
        .group_start_ready(group_launch_ready),.active_group_id,.causal_en,
        .raw_req_valid,.raw_req_ready,.raw_req_is_k,.raw_req_head,
        .raw_req_token,.raw_req_pair,.raw_rsp_valid,.raw_rsp_ready,.raw_rsp_x0,.raw_rsp_x1,
        .v_req_valid,.v_req_ready,.v_req_kv_head,.v_req_reduce_index,
        .v_req_feature_base,.v_req_addr,.v_rsp_valid,.v_rsp_ready,.v_rsp_data,
        .p_vec_bf16,.v_vec_bf16,.pv_vec_valid,.pv_vec_ready,.pv_vec_first,
        .pv_vec_last,.pv_vec_group_last,.pv_vec_group_id,.pv_vec_head,
        .pv_vec_global_q_head,.pv_vec_row_base,.pv_vec_feature_base,.pv_vec_reduce_index,
        .req_head(),.req_group_id(),.req_global_q_head(),.req_kv_head(),
        .req_row_base(),.req_col_base(),.req_dim(),
        .mon_prob_valid(),.mon_prob_ready(),.mon_prob_data(),.mon_prob_group_id(),
        .mon_prob_head(),.mon_prob_row(),.mon_prob_col(),.mon_prob_first(),
        .mon_prob_last(),.mon_prob_group_last(),
        .rope_busy(),.rope_done,.qk_busy(),.qk_done(),.b_frontend_busy(),
        .c_backend_busy(),.busy(pipeline_busy),.prob_input_done(),
        .done(group_done),.protocol_error(pipeline_error)
    );

    bf16_v_cache #(
        .NUM_KV_HEADS(GQA_GROUPS),.SEQ_LEN(SEQ_LEN),.HEAD_DIM(HEAD_DIM),
        .LANES(PV_TILE),.ADDR_W(V_ADDR_W)
    ) u_v_cache (
        .clk,.rst_n,.load_valid(v_load_valid),.load_ready(v_load_ready),
        .load_addr(v_load_addr),.load_data(v_load_data),
        .req_valid(v_req_valid),.req_ready(v_req_ready),.req_addr(v_req_addr),
        .rsp_valid(v_rsp_valid),.rsp_ready(v_rsp_ready),.rsp_data(v_rsp_data),
        .protocol_error(v_cache_error)
    );

    logic [GROUP_W-1:0] unused_v_head;
    logic [POS_W-1:0] unused_v_reduce;
    logic [DIM_W-1:0] unused_v_feature;
    assign unused_v_head=v_req_kv_head;
    assign unused_v_reduce=v_req_reduce_index;
    assign unused_v_feature=v_req_feature_base;
endmodule
