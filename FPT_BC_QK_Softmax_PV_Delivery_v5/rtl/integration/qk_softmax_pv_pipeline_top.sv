`timescale 1ns/1ps

// Responsibility B + C integration shell.
//
// One accepted group_start processes exactly one GQA group:
//   B: real QK -> causal mask -> row-tile buffer -> BF16 Softmax
//   C: probability buffer -> P replay/V loader -> PV input vectors
//
// This module intentionally stops at the PV input ready/valid interface.  Its
// done pulse means that the final PV input vector was accepted and the final P
// bank was released; a future PV MAC must provide the final-result completion.
module qk_softmax_pv_pipeline_top #(
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

    // One-group launch protocol. group_start_ready describes physical
    // readiness; an out-of-range group_id is rejected and flagged.
    input  logic                         group_start,
    input  logic [GROUP_W-1:0]           group_id,
    output logic                         group_start_ready,
    output logic [GROUP_W-1:0]           active_group_id,
    input  logic                         causal_en,

    // Q/K loader interface used by the B-side QK engine.
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

    // External V-memory request/response. v_req_addr is the scalar BF16
    // address of lane zero; v_rsp_data packs two consecutive BF16 values for
    // the selected PV_TILE=2 baseline.
    output logic                         v_req_valid,
    input  logic                         v_req_ready,
    output logic [GROUP_W-1:0]           v_req_kv_head,
    output logic [POS_W-1:0]             v_req_reduce_index,
    output logic [DIM_W-1:0]             v_req_feature_base,
    output logic [V_ADDR_W-1:0]          v_req_addr,
    input  logic                         v_rsp_valid,
    output logic                         v_rsp_ready,
    input  logic [PV_TILE*16-1:0]        v_rsp_data,

    // PV input stream. Both vectors and every metadata field are stable while
    // pv_vec_valid=1 and pv_vec_ready=0.
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

    // Read-only B->C boundary monitor for verification.  There is deliberately
    // no second ready input: mon_prob_ready is the real C backpressure.
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

    output logic                         qk_busy,
    output logic                         qk_done,
    output logic                         b_frontend_busy,
    output logic                         c_backend_busy,
    output logic                         busy,
    output logic                         prob_input_done,
    output logic                         done,

    output logic                         start_while_busy_error,
    output logic                         invalid_group_id_error,
    output logic                         adapter_protocol_error,
    output logic                         adapter_global_last_error,
    output logic                         softmax_row_error,
    output logic                         softmax_metadata_error,
    output logic                         c_protocol_error,
    output logic                         protocol_error
);
    logic transaction_active;
    logic accepted_start;
    logic group_id_valid;
    logic [GROUP_W-1:0] group_id_reg;

    logic b_group_start_ready;
    logic b_pipeline_busy;
    logic b_group_done;
    logic b_pipeline_done;
    logic b_start_while_busy_error;
    logic b_invalid_group_id_error;

    logic prob_valid;
    logic prob_ready;
    logic [15:0] prob_data;
    logic [GROUP_W-1:0] prob_group_id;
    logic [HEAD_W-1:0] prob_head;
    logic [POS_W-1:0] prob_row;
    logic [POS_W-1:0] prob_col;
    logic prob_first;
    logic prob_last;
    logic prob_group_last;
    logic prob_global_last;
    logic c_done;

    assign group_id_valid = ($unsigned(group_id) < GQA_GROUPS);
    assign group_start_ready = !transaction_active &&
                               b_group_start_ready && !c_backend_busy;
    assign accepted_start = group_start && group_start_ready && group_id_valid;

    assign active_group_id = group_id_reg;
    assign busy = transaction_active || b_pipeline_busy || c_backend_busy;
    assign prob_input_done = b_group_done;
    assign done = c_done;

    assign mon_prob_valid      = prob_valid;
    assign mon_prob_ready      = prob_ready;
    assign mon_prob_data       = prob_data;
    assign mon_prob_group_id   = prob_group_id;
    assign mon_prob_head       = prob_head;
    assign mon_prob_row        = prob_row;
    assign mon_prob_col        = prob_col;
    assign mon_prob_first      = prob_first;
    assign mon_prob_last       = prob_last;
    assign mon_prob_group_last = prob_group_last;

    assign pv_vec_group_id = group_id_reg;
    assign pv_vec_global_q_head =
        ($unsigned(group_id_reg) * Q_HEADS) + $unsigned(pv_vec_head);
    assign pv_vec_group_last = pv_vec_valid && pv_vec_last &&
                               ($unsigned(pv_vec_head) == Q_HEADS-1) &&
                               ($unsigned(pv_vec_row_base) == SEQ_LEN-PV_TILE) &&
                               ($unsigned(pv_vec_feature_base) == HEAD_DIM-PV_TILE);

    assign protocol_error = start_while_busy_error ||
                            invalid_group_id_error ||
                            b_start_while_busy_error ||
                            b_invalid_group_id_error ||
                            adapter_protocol_error ||
                            adapter_global_last_error ||
                            softmax_row_error ||
                            softmax_metadata_error ||
                            c_protocol_error;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            transaction_active       <= 1'b0;
            group_id_reg             <= '0;
            start_while_busy_error   <= 1'b0;
            invalid_group_id_error   <= 1'b0;
        end else begin
            if (accepted_start) begin
                transaction_active       <= 1'b1;
                group_id_reg             <= group_id;
                start_while_busy_error   <= 1'b0;
                invalid_group_id_error   <= 1'b0;
            end else begin
                if (group_start && !group_start_ready)
                    start_while_busy_error <= 1'b1;
                if (group_start && group_start_ready && !group_id_valid)
                    invalid_group_id_error <= 1'b1;
            end

            if (c_done)
                transaction_active <= 1'b0;
        end
    end

    qk_softmax_pipeline_top #(
        .TILE(QK_TILE),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W),
        .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W),
        .POS_W(POS_W),
        .DIM_W(DIM_W),
        .SCALE_FP32(SCALE_FP32),
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_b_pipeline (
        .clk(clk),
        .rst_n(rst_n),
        .group_start(accepted_start),
        .group_id(group_id),
        .group_start_ready(b_group_start_ready),
        .active_group_id(),
        .causal_en(causal_en),
        .vec_ready(qk_vec_ready),
        .vec_valid(qk_vec_valid),
        .q_vec_bf16(q_vec_bf16),
        .k_vec_bf16(k_vec_bf16),
        .req_head(req_head),
        .req_group_id(req_group_id),
        .req_global_q_head(req_global_q_head),
        .req_kv_head(req_kv_head),
        .req_row_base(req_row_base),
        .req_col_base(req_col_base),
        .req_dim(req_dim),
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
        .prob_global_last(prob_global_last),
        .qk_busy(qk_busy),
        .qk_done(qk_done),
        .frontend_busy(b_frontend_busy),
        .pipeline_busy(b_pipeline_busy),
        .group_done(b_group_done),
        .pipeline_done(b_pipeline_done),
        .start_while_busy_error(b_start_while_busy_error),
        .invalid_group_id_error(b_invalid_group_id_error),
        .adapter_protocol_error(adapter_protocol_error),
        .adapter_global_last_error(adapter_global_last_error),
        .softmax_row_error(softmax_row_error),
        .softmax_metadata_error(softmax_metadata_error)
    );

    softmax_pv_backend #(
        .Q_HEADS(Q_HEADS),
        .KV_HEADS(1),
        .V_KV_HEADS(GQA_GROUPS),
        .USE_GROUP_ID_FOR_KV(1'b1),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .TILE(PV_TILE)
    ) u_c_backend (
        .clk(clk),
        .rst_n(rst_n),
        .start(accepted_start),
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
        .vec_valid(pv_vec_valid),
        .vec_ready(pv_vec_ready),
        .vec_first(pv_vec_first),
        .vec_last(pv_vec_last),
        .vec_head(pv_vec_head),
        .vec_row_base(pv_vec_row_base),
        .vec_feature_base(pv_vec_feature_base),
        .vec_reduce_index(pv_vec_reduce_index),
        .done(c_done),
        .busy(c_backend_busy),
        .protocol_error(c_protocol_error)
    );

    // Compatibility-only signals are consumed intentionally so lint tools do
    // not report accidental floating outputs from the B delivery.
    logic unused_prob_global_last;
    logic unused_b_pipeline_done;
    assign unused_prob_global_last = prob_global_last;
    assign unused_b_pipeline_done  = b_pipeline_done;

    initial begin
        if (Q_HEADS != 4)
            $error("qk_softmax_pv_pipeline_top: formal delivery expects Q_HEADS=4");
        if ((GQA_GROUPS < 1) || (GQA_GROUPS > 8))
            $error("qk_softmax_pv_pipeline_top: GQA_GROUPS must be in [1,8]");
        if (PV_TILE != 2)
            $error("qk_softmax_pv_pipeline_top: this delivery is fixed to PV_TILE=2");
        if ((SEQ_LEN % PV_TILE) != 0 || (HEAD_DIM % PV_TILE) != 0)
            $error("qk_softmax_pv_pipeline_top: PV_TILE must divide sequence and head dimensions");
    end
endmodule
