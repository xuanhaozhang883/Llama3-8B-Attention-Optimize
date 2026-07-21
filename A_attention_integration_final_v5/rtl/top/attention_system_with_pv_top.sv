`timescale 1ns/1ps

// ============================================================================
// attention_system_with_pv_top
// ----------------------------------------------------------------------------
// Corrected A-owned integration based on the already-verified A/B+C boundary.
//
// Important facts preserved from the exact uploaded sources:
//   - B+C v5 qk_softmax_pv_pipeline_top is formally fixed to PV_TILE=2.
//   - Uploaded real pv_systolic_gqa_top uses TILE=4.
//   - Therefore direct parameter replacement PV_TILE=4 is NOT used.
//   - A captures one complete TILE2 Group, repacks it, then drives TILE4 PV.
//
// Existing B/C RTL and existing PV RTL are not modified.
// Current Q/K interface still expects RoPE-after vectors.
// ============================================================================
module attention_system_with_pv_top #(
    parameter int QK_TILE       = 4,
    parameter int BC_PV_TILE    = 2,
    parameter int REAL_PV_TILE  = 4,
    parameter int SEQ_LEN       = 128,
    parameter int HEAD_DIM      = 128,
    parameter int Q_HEADS       = 4,
    parameter int GQA_GROUPS    = 8,
    parameter int HEAD_W        =
        (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int GROUP_W       =
        (GQA_GROUPS <= 1) ? 1 : $clog2(GQA_GROUPS),
    parameter int GLOBAL_Q_HEAD_W =
        ((Q_HEADS*GQA_GROUPS) <= 1) ? 1 :
        $clog2(Q_HEADS*GQA_GROUPS),
    parameter int POS_W         =
        (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter int DIM_W         =
        (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM),
    parameter int V_ADDR_W      =
        ((GQA_GROUPS*SEQ_LEN*HEAD_DIM) <= 1) ? 1 :
        $clog2(GQA_GROUPS*SEQ_LEN*HEAD_DIM),
    parameter logic [31:0] SCALE_FP32 = 32'h3DB504F3,
    parameter EXP_LUT_FILE = "exp_lut_q15.mem"
) (
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    output logic start_ready,
    output logic busy,
    output logic done,
    input  logic causal_en,

    // RoPE-after Q/K loader boundary.
    output logic qk_vec_ready,
    input  logic qk_vec_valid,
    input  logic [QK_TILE*16-1:0] q_vec_bf16,
    input  logic [QK_TILE*16-1:0] k_vec_bf16,
    output logic [HEAD_W-1:0] req_head,
    output logic [GROUP_W-1:0] req_group_id,
    output logic [GLOBAL_Q_HEAD_W-1:0] req_global_q_head,
    output logic [GROUP_W-1:0] req_kv_head,
    output logic [POS_W-1:0] req_row_base,
    output logic [POS_W-1:0] req_col_base,
    output logic [DIM_W-1:0] req_dim,

    // Keep the already-verified B+C v5 TILE2 V-load contract.
    input  logic v_load_valid,
    output logic v_load_ready,
    input  logic [V_ADDR_W-1:0] v_load_addr,
    input  logic [BC_PV_TILE*16-1:0] v_load_data,

    // Real PV Context output.
    output logic context_valid,
    input  logic context_ready,
    output logic [15:0] context_bf16,
    output logic [31:0] context_fp32_debug,
    output logic [GROUP_W-1:0] context_group_id,
    output logic [HEAD_W-1:0] context_head,
    output logic [GLOBAL_Q_HEAD_W-1:0] context_global_q_head,
    output logic [POS_W-1:0] context_row,
    output logic [DIM_W-1:0] context_col,
    output logic context_group_last,
    output logic context_global_last,

    // Probability monitor.
    output logic mon_prob_valid,
    output logic mon_prob_ready,
    output logic [15:0] mon_prob_data,
    output logic [GROUP_W-1:0] mon_prob_group_id,
    output logic [HEAD_W-1:0] mon_prob_head,
    output logic [POS_W-1:0] mon_prob_row,
    output logic [POS_W-1:0] mon_prob_col,
    output logic mon_prob_first,
    output logic mon_prob_last,
    output logic mon_prob_group_last,

    // B+C TILE2 stream monitor.
    output logic mon_bc_pv_valid,
    output logic mon_bc_pv_ready,
    output logic [31:0] mon_bc_p_vec_bf16,
    output logic [31:0] mon_bc_v_vec_bf16,
    output logic [GROUP_W-1:0] mon_bc_pv_group_id,
    output logic [HEAD_W-1:0] mon_bc_pv_head,
    output logic [POS_W-1:0] mon_bc_pv_row_base,
    output logic [DIM_W-1:0] mon_bc_pv_feature_base,
    output logic [POS_W-1:0] mon_bc_pv_reduce_index,

    // Real TILE4 PV feed monitor.
    output logic mon_real_pv_valid,
    output logic mon_real_pv_ready,
    output logic [63:0] mon_real_p_vec_bf16,
    output logic [63:0] mon_real_v_vec_bf16,
    output logic [HEAD_W-1:0] mon_real_pv_req_head,
    output logic [POS_W-1:0] mon_real_pv_req_row_base,
    output logic [DIM_W-1:0] mon_real_pv_req_col_base,
    output logic [POS_W-1:0] mon_real_pv_req_reduce,

    output logic group_complete,
    output logic [GROUP_W-1:0] completed_group_id,
    output logic [GROUP_W-1:0] active_group_id,

    output logic bc_group_done,
    output logic capture_complete,
    output logic pv_group_done,

    output logic bc_busy,
    output logic pv_busy,

    output logic start_while_busy_error,
    output logic controller_error,
    output logic bc_protocol_error,
    output logic v_cache_error,
    output logic repack_error,
    output logic protocol_error
);

    attention_with_pv_config_guard #(
        .QK_TILE(QK_TILE),
        .BC_PV_TILE(BC_PV_TILE),
        .REAL_PV_TILE(REAL_PV_TILE),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS)
    ) u_config_guard ();

    logic controller_busy;
    logic bc_group_start;
    logic bc_group_start_ready;
    logic capture_start;
    logic capture_done;
    logic pv_start;
    logic pv_feed_enable;

    logic [GROUP_W-1:0] bc_active_group_id;

    logic v_req_valid;
    logic v_req_ready;
    logic [GROUP_W-1:0] v_req_kv_head;
    logic [POS_W-1:0] v_req_reduce_index;
    logic [DIM_W-1:0] v_req_feature_base;
    logic [V_ADDR_W-1:0] v_req_addr;
    logic v_rsp_valid;
    logic v_rsp_ready;
    logic [BC_PV_TILE*16-1:0] v_rsp_data;

    logic [BC_PV_TILE*16-1:0] bc_p_vec_bf16;
    logic [BC_PV_TILE*16-1:0] bc_v_vec_bf16;
    logic bc_pv_vec_valid;
    logic bc_pv_vec_ready;
    logic bc_pv_vec_first;
    logic bc_pv_vec_last;
    logic bc_pv_vec_group_last;
    logic [GROUP_W-1:0] bc_pv_vec_group_id;
    logic [HEAD_W-1:0] bc_pv_vec_head;
    logic [GLOBAL_Q_HEAD_W-1:0] bc_pv_vec_global_q_head;
    logic [POS_W-1:0] bc_pv_vec_row_base;
    logic [DIM_W-1:0] bc_pv_vec_feature_base;
    logic [POS_W-1:0] bc_pv_vec_reduce_index;

    logic [REAL_PV_TILE*16-1:0] real_p_vec_bf16;
    logic [REAL_PV_TILE*16-1:0] real_v_vec_bf16;
    logic real_pv_vec_valid;
    logic real_pv_vec_ready;

    logic [HEAD_W-1:0] real_pv_req_head;
    logic [POS_W-1:0] real_pv_req_row_base;
    logic [DIM_W-1:0] real_pv_req_col_base;
    logic [POS_W-1:0] real_pv_req_reduce;

    logic pv_context_last;

    logic unused_qk_done;
    logic unused_b_frontend_busy;
    logic unused_c_backend_busy;
    logic unused_prob_input_done;

    logic bc_start_busy_error;
    logic bc_invalid_group_error;
    logic bc_adapter_protocol_error;
    logic bc_adapter_global_last_error;
    logic bc_softmax_row_error;
    logic bc_softmax_metadata_error;
    logic bc_c_protocol_error;

    assign busy = controller_busy || bc_busy || pv_busy;

    attention_group_pv_controller #(
        .NUM_GROUPS(GQA_GROUPS),
        .GROUP_W(GROUP_W)
    ) u_group_controller (
        .clk(clk),
        .rst_n(rst_n),

        .start(start),
        .start_ready(start_ready),
        .busy(controller_busy),
        .done(done),

        .active_group_id(active_group_id),

        .bc_group_start(bc_group_start),
        .bc_group_start_ready(bc_group_start_ready),
        .bc_group_done(bc_group_done),

        .capture_start(capture_start),
        .capture_complete(capture_complete),

        .pv_start(pv_start),
        .pv_feed_enable(pv_feed_enable),
        .pv_done(pv_group_done),

        .child_protocol_error(
            bc_protocol_error |
            v_cache_error |
            repack_error
        ),

        .group_complete(group_complete),
        .completed_group_id(completed_group_id),
        .start_while_busy_error(start_while_busy_error),
        .protocol_error(controller_error)
    );

    qk_softmax_pv_pipeline_top #(
        .QK_TILE(QK_TILE),
        .PV_TILE(BC_PV_TILE),
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
    ) u_bc_group (
        .clk(clk),
        .rst_n(rst_n),

        .group_start(bc_group_start),
        .group_id(active_group_id),
        .group_start_ready(bc_group_start_ready),
        .active_group_id(bc_active_group_id),
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

        .p_vec_bf16(bc_p_vec_bf16),
        .v_vec_bf16(bc_v_vec_bf16),
        .pv_vec_valid(bc_pv_vec_valid),
        .pv_vec_ready(bc_pv_vec_ready),
        .pv_vec_first(bc_pv_vec_first),
        .pv_vec_last(bc_pv_vec_last),
        .pv_vec_group_last(bc_pv_vec_group_last),
        .pv_vec_group_id(bc_pv_vec_group_id),
        .pv_vec_head(bc_pv_vec_head),
        .pv_vec_global_q_head(bc_pv_vec_global_q_head),
        .pv_vec_row_base(bc_pv_vec_row_base),
        .pv_vec_feature_base(bc_pv_vec_feature_base),
        .pv_vec_reduce_index(bc_pv_vec_reduce_index),

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

        .qk_busy(),
        .qk_done(unused_qk_done),
        .b_frontend_busy(unused_b_frontend_busy),
        .c_backend_busy(unused_c_backend_busy),
        .busy(bc_busy),
        .prob_input_done(unused_prob_input_done),
        .done(bc_group_done),

        .start_while_busy_error(bc_start_busy_error),
        .invalid_group_id_error(bc_invalid_group_error),
        .adapter_protocol_error(bc_adapter_protocol_error),
        .adapter_global_last_error(bc_adapter_global_last_error),
        .softmax_row_error(bc_softmax_row_error),
        .softmax_metadata_error(bc_softmax_metadata_error),
        .c_protocol_error(bc_c_protocol_error),
        .protocol_error(bc_protocol_error)
    );

    bf16_v_cache #(
        .NUM_KV_HEADS(GQA_GROUPS),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .LANES(BC_PV_TILE),
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

    pv_tile2_to_tile4_buffer_adapter #(
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W),
        .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W),
        .POS_W(POS_W),
        .DIM_W(DIM_W)
    ) u_repack (
        .clk(clk),
        .rst_n(rst_n),

        .capture_start(capture_start),
        .expected_group_id(active_group_id),

        .in_p_vec_bf16(bc_p_vec_bf16),
        .in_v_vec_bf16(bc_v_vec_bf16),
        .in_valid(bc_pv_vec_valid),
        .in_ready(bc_pv_vec_ready),
        .in_first(bc_pv_vec_first),
        .in_last(bc_pv_vec_last),
        .in_group_last(bc_pv_vec_group_last),
        .in_group_id(bc_pv_vec_group_id),
        .in_head(bc_pv_vec_head),
        .in_global_q_head(bc_pv_vec_global_q_head),
        .in_row_base(bc_pv_vec_row_base),
        .in_feature_base(bc_pv_vec_feature_base),
        .in_reduce_index(bc_pv_vec_reduce_index),

        .capture_complete(capture_complete),
        .capture_done(capture_done),

        .feed_enable(pv_feed_enable),
        .req_head(real_pv_req_head),
        .req_row_base(real_pv_req_row_base),
        .req_col_base(real_pv_req_col_base),
        .req_reduce(real_pv_req_reduce),

        .out_p_vec_bf16(real_p_vec_bf16),
        .out_v_vec_bf16(real_v_vec_bf16),
        .out_valid(real_pv_vec_valid),
        .out_ready(real_pv_vec_ready),

        .protocol_error(repack_error)
    );

    pv_systolic_gqa_top #(
        .TILE(REAL_PV_TILE),
        .QUERY_LEN(SEQ_LEN),
        .REDUCE_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS)
    ) u_real_pv (
        .clk(clk),
        .rst_n(rst_n),

        .start(pv_start),
        .busy(pv_busy),
        .done(pv_group_done),

        .vec_ready(real_pv_vec_ready),
        .vec_valid(real_pv_vec_valid),
        .p_vec_bf16(real_p_vec_bf16),
        .v_vec_bf16(real_v_vec_bf16),

        .req_head(real_pv_req_head),
        .req_row_base(real_pv_req_row_base),
        .req_col_base(real_pv_req_col_base),
        .req_reduce(real_pv_req_reduce),

        .context_valid(context_valid),
        .context_ready(context_ready),
        .context_bf16(context_bf16),
        .context_fp32_debug(context_fp32_debug),
        .context_head(context_head),
        .context_row(context_row),
        .context_col(context_col),
        .context_last(pv_context_last)
    );

    assign context_group_id = active_group_id;
    assign context_global_q_head =
        ($unsigned(active_group_id) * Q_HEADS) +
        $unsigned(context_head);
    assign context_group_last = pv_context_last;
    assign context_global_last =
        pv_context_last &&
        ($unsigned(active_group_id) == GQA_GROUPS-1);

    assign mon_bc_pv_valid             = bc_pv_vec_valid;
    assign mon_bc_pv_ready             = bc_pv_vec_ready;
    assign mon_bc_p_vec_bf16           = bc_p_vec_bf16;
    assign mon_bc_v_vec_bf16           = bc_v_vec_bf16;
    assign mon_bc_pv_group_id          = bc_pv_vec_group_id;
    assign mon_bc_pv_head              = bc_pv_vec_head;
    assign mon_bc_pv_row_base          = bc_pv_vec_row_base;
    assign mon_bc_pv_feature_base      = bc_pv_vec_feature_base;
    assign mon_bc_pv_reduce_index      = bc_pv_vec_reduce_index;

    assign mon_real_pv_valid           = real_pv_vec_valid;
    assign mon_real_pv_ready           = real_pv_vec_ready;
    assign mon_real_p_vec_bf16         = real_p_vec_bf16;
    assign mon_real_v_vec_bf16         = real_v_vec_bf16;
    assign mon_real_pv_req_head        = real_pv_req_head;
    assign mon_real_pv_req_row_base    = real_pv_req_row_base;
    assign mon_real_pv_req_col_base    = real_pv_req_col_base;
    assign mon_real_pv_req_reduce      = real_pv_req_reduce;

    assign protocol_error =
        start_while_busy_error |
        controller_error |
        bc_protocol_error |
        v_cache_error |
        repack_error;

endmodule
