`timescale 1ns/1ps

// Reference system shell for the completed "currently actionable" B+C scope:
// one start -> Groups 0..7 -> real V-cache -> PV input stream.
// It still stops before the future PV MAC array.
module qk_softmax_pv_system_top #(
    parameter int QK_TILE     = 4,
    parameter int PV_TILE     = 2,
    parameter int SEQ_LEN     = 128,
    parameter int HEAD_DIM    = 128,
    parameter int Q_HEADS     = 4,
    parameter int GQA_GROUPS  = 8,
    parameter int HEAD_W      = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int GROUP_W     = (GQA_GROUPS <= 1) ? 1 : $clog2(GQA_GROUPS),
    parameter int GLOBAL_Q_HEAD_W = ((Q_HEADS*GQA_GROUPS) <= 1) ? 1 :
                                      $clog2(Q_HEADS*GQA_GROUPS),
    parameter int POS_W       = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter int DIM_W       = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM),
    parameter int V_ADDR_W    = ((GQA_GROUPS*SEQ_LEN*HEAD_DIM) <= 1) ? 1 :
                               $clog2(GQA_GROUPS*SEQ_LEN*HEAD_DIM),
    parameter logic [31:0] SCALE_FP32 = 32'h3DB504F3,
    parameter EXP_LUT_FILE = "exp_lut_q15.mem"
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,
    output logic                         start_ready,
    output logic                         busy,
    output logic                         done,
    input  logic                         causal_en,

    // Q/K loader owned by the surrounding Attention memory system.
    output logic                         qk_vec_ready,
    input  logic                         qk_vec_valid,
    input  logic [QK_TILE*16-1:0]        q_vec_bf16,
    input  logic [QK_TILE*16-1:0]        k_vec_bf16,
    output logic [HEAD_W-1:0]            req_head,
    output logic [GROUP_W-1:0]           req_group_id,
    output logic [GLOBAL_Q_HEAD_W-1:0]   req_global_q_head,
    output logic [GROUP_W-1:0]           req_kv_head,
    output logic [POS_W-1:0]             req_row_base,
    output logic [POS_W-1:0]             req_col_base,
    output logic [DIM_W-1:0]             req_dim,

    // Vectorized V-cache load/update interface.
    input  logic                         v_load_valid,
    output logic                         v_load_ready,
    input  logic [V_ADDR_W-1:0]          v_load_addr,
    input  logic [PV_TILE*16-1:0]        v_load_data,

    // Output boundary to the future real PV MAC.
    output logic [PV_TILE*16-1:0]        p_vec_bf16,
    output logic [PV_TILE*16-1:0]        v_vec_bf16,
    output logic                         pv_vec_valid,
    input  logic                         pv_vec_ready,
    output logic                         pv_vec_first,
    output logic                         pv_vec_last,
    output logic                         pv_vec_group_last,
    output logic [GROUP_W-1:0]           pv_vec_group_id,
    output logic [HEAD_W-1:0]            pv_vec_head,
    output logic [GLOBAL_Q_HEAD_W-1:0]   pv_vec_global_q_head,
    output logic [POS_W-1:0]             pv_vec_row_base,
    output logic [DIM_W-1:0]             pv_vec_feature_base,
    output logic [POS_W-1:0]             pv_vec_reduce_index,

    // Verification/bring-up monitors.
    output logic                         mon_prob_valid,
    output logic                         mon_prob_ready,
    output logic [15:0]                  mon_prob_data,
    output logic [GROUP_W-1:0]           mon_prob_group_id,
    output logic [HEAD_W-1:0]            mon_prob_head,
    output logic [POS_W-1:0]             mon_prob_row,
    output logic [POS_W-1:0]             mon_prob_col,
    output logic                         mon_prob_first,
    output logic                         mon_prob_last,
    output logic                         mon_prob_group_last,

    output logic                         group_complete,
    output logic [GROUP_W-1:0]           completed_group_id,
    output logic [GROUP_W-1:0]           active_group_id,
    output logic                         pipeline_group_start,
    output logic                         pipeline_group_start_ready,
    output logic                         pipeline_qk_busy,
    output logic                         pipeline_b_busy,
    output logic                         pipeline_c_busy,
    output logic                         controller_error,
    output logic                         pipeline_error,
    output logic                         v_cache_error,
    output logic                         protocol_error
);
    logic [GROUP_W-1:0] launch_group_id;
    logic pipeline_done;
    logic controller_busy;
    logic controller_done;
    logic controller_start_busy_error;

    logic v_req_valid;
    logic v_req_ready;
    logic [GROUP_W-1:0] v_req_kv_head;
    logic [POS_W-1:0] v_req_reduce_index;
    logic [DIM_W-1:0] v_req_feature_base;
    logic [V_ADDR_W-1:0] v_req_addr;
    logic v_rsp_valid;
    logic v_rsp_ready;
    logic [PV_TILE*16-1:0] v_rsp_data;

    logic pipeline_busy;
    logic pipeline_prob_done;
    logic pipeline_start_busy_error;
    logic pipeline_invalid_group_error;
    logic unused_qk_done;

    assign busy = controller_busy || pipeline_busy;
    assign done = controller_done;
    assign protocol_error = controller_error || controller_start_busy_error ||
                            pipeline_error || v_cache_error;

    gqa_group_controller #(
        .NUM_GROUPS(GQA_GROUPS),
        .GROUP_W(GROUP_W)
    ) u_group_controller (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .start_ready(start_ready),
        .busy(controller_busy),
        .done(controller_done),
        .group_start(pipeline_group_start),
        .group_start_ready(pipeline_group_start_ready),
        .group_id(launch_group_id),
        .group_done(pipeline_done),
        .group_protocol_error(pipeline_error || v_cache_error),
        .group_complete(group_complete),
        .completed_group_id(completed_group_id),
        .start_while_busy_error(controller_start_busy_error),
        .protocol_error(controller_error)
    );

    qk_softmax_pv_pipeline_top #(
        .QK_TILE(QK_TILE),
        .PV_TILE(PV_TILE),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W),
        .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W),
        .POS_W(POS_W),
        .DIM_W(DIM_W),
        .V_ADDR_W(V_ADDR_W),
        .SCALE_FP32(SCALE_FP32),
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_pipeline (
        .clk(clk),
        .rst_n(rst_n),
        .group_start(pipeline_group_start),
        .group_id(launch_group_id),
        .group_start_ready(pipeline_group_start_ready),
        .active_group_id(active_group_id),
        .causal_en(causal_en),
        .qk_vec_ready(qk_vec_ready),
        .qk_vec_valid(qk_vec_valid),
        .q_vec_bf16(q_vec_bf16),
        .k_vec_bf16(k_vec_bf16),
        .req_head(req_head),
        .req_group_id(req_group_id),
        .req_global_q_head(req_global_q_head),
        .req_kv_head(req_kv_head),
        .req_row_base(req_row_base),
        .req_col_base(req_col_base),
        .req_dim(req_dim),
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
        .pv_vec_valid(pv_vec_valid),
        .pv_vec_ready(pv_vec_ready),
        .pv_vec_first(pv_vec_first),
        .pv_vec_last(pv_vec_last),
        .pv_vec_group_last(pv_vec_group_last),
        .pv_vec_group_id(pv_vec_group_id),
        .pv_vec_head(pv_vec_head),
        .pv_vec_global_q_head(pv_vec_global_q_head),
        .pv_vec_row_base(pv_vec_row_base),
        .pv_vec_feature_base(pv_vec_feature_base),
        .pv_vec_reduce_index(pv_vec_reduce_index),
        .mon_prob_valid(mon_prob_valid),
        .mon_prob_ready(mon_prob_ready),
        .mon_prob_data(mon_prob_data),
        .mon_prob_group_id(mon_prob_group_id),
        .mon_prob_head(mon_prob_head),
        .mon_prob_row(mon_prob_row),
        .mon_prob_col(mon_prob_col),
        .mon_prob_first(mon_prob_first),
        .mon_prob_last(mon_prob_last),
        .mon_prob_group_last(mon_prob_group_last),
        .qk_busy(pipeline_qk_busy),
        .qk_done(unused_qk_done),
        .b_frontend_busy(pipeline_b_busy),
        .c_backend_busy(pipeline_c_busy),
        .busy(pipeline_busy),
        .prob_input_done(pipeline_prob_done),
        .done(pipeline_done),
        .start_while_busy_error(pipeline_start_busy_error),
        .invalid_group_id_error(pipeline_invalid_group_error),
        .adapter_protocol_error(),
        .adapter_global_last_error(),
        .softmax_row_error(),
        .softmax_metadata_error(),
        .c_protocol_error(),
        .protocol_error(pipeline_error)
    );

    bf16_v_cache #(
        .NUM_KV_HEADS(GQA_GROUPS),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .LANES(PV_TILE),
        .ADDR_W(V_ADDR_W)
    ) u_v_cache (
        .clk(clk),
        .rst_n(rst_n),
        .load_valid(v_load_valid),
        .load_ready(v_load_ready),
        .load_addr(v_load_addr),
        .load_data(v_load_data),
        .req_valid(v_req_valid),
        .req_ready(v_req_ready),
        .req_addr(v_req_addr),
        .rsp_valid(v_rsp_valid),
        .rsp_ready(v_rsp_ready),
        .rsp_data(v_rsp_data),
        .protocol_error(v_cache_error)
    );

    // Metadata already checked inside pv_input_loader; keep these request-side
    // fields visible to synthesis/lint without exporting redundant ports.
    logic [GROUP_W-1:0] unused_v_req_kv_head;
    logic [POS_W-1:0] unused_v_req_reduce;
    logic [DIM_W-1:0] unused_v_req_feature;
    assign unused_v_req_kv_head = v_req_kv_head;
    assign unused_v_req_reduce  = v_req_reduce_index;
    assign unused_v_req_feature = v_req_feature_base;

    initial begin
        if (GQA_GROUPS != 8)
            $error("qk_softmax_pv_system_top: formal system run expects 8 Groups");
        if (PV_TILE != 2)
            $error("qk_softmax_pv_system_top: delivery fixes PV_TILE=2");
    end
endmodule
