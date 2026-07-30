`timescale 1ns/1ps

// Full Responsibility-B integration shell:
// one GQA group of real QK -> Causal Mask -> Row Tile Buffer -> Softmax.
//
// v4 group contract:
//   * One launch processes exactly one 4Q/1KV GQA group.
//   * group_id identifies the global KV head (0..7 for Llama-3.1-8B).
//   * req_head/prob_head remain local Q-head numbers inside the group (0..3).
//   * req_global_q_head = group_id * Q_HEADS + req_head.
//   * The same group_start/group_id must be delivered to the C backend.
module qk_softmax_pipeline_top #(
    parameter int TILE      = 4,
    parameter int SEQ_LEN   = 128,
    parameter int HEAD_DIM  = 128,
    parameter int Q_HEADS   = 4,
    parameter int GQA_GROUPS = 8,
    parameter int HEAD_W    = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int GROUP_W   = (GQA_GROUPS <= 1) ? 1 : $clog2(GQA_GROUPS),
    parameter int GLOBAL_Q_HEAD_W = ((Q_HEADS*GQA_GROUPS) <= 1) ? 1 : $clog2(Q_HEADS*GQA_GROUPS),
    parameter int POS_W     = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter int DIM_W     = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM),
    parameter logic [31:0] SCALE_FP32 = 32'h3DB504F3,
    parameter EXP_LUT_FILE = "exp_lut_q15.mem"
) (
    input  logic                         clk,
    input  logic                         rst_n,

    input  logic                         group_start,
    input  logic [GROUP_W-1:0]           group_id,
    output logic                         group_start_ready,
    output logic [GROUP_W-1:0]           active_group_id,
    input  logic                         causal_en,

    // Q/K vector-loader stream. req_head is local inside the active group.
    output logic                         vec_ready,
    input  logic                         vec_valid,
    input  logic [TILE*16-1:0]           q_vec_bf16,
    input  logic [TILE*16-1:0]           k_vec_bf16,
    output logic [HEAD_W-1:0]            req_head,
    output logic [GROUP_W-1:0]           req_group_id,
    output logic [GLOBAL_Q_HEAD_W-1:0]   req_global_q_head,
    output logic [GROUP_W-1:0]           req_kv_head,
    output logic [POS_W-1:0]             req_row_base,
    output logic [POS_W-1:0]             req_col_base,
    output logic [DIM_W-1:0]             req_dim,

    // Complete B -> C probability interface.
    output logic                         prob_valid,
    input  logic                         prob_ready,
    output logic [15:0]                  prob_data,
    output logic [GROUP_W-1:0]           prob_group_id,
    output logic [HEAD_W-1:0]            prob_head,
    output logic [POS_W-1:0]             prob_row,
    output logic [POS_W-1:0]             prob_col,
    output logic                         prob_first,
    output logic                         prob_last,
    output logic                         prob_group_last,

    // Compatibility alias retained for v3 testbenches/integration code.
    output logic                         prob_global_last,

    output logic                         qk_busy,
    output logic                         qk_done,
    output logic                         frontend_busy,
    output logic                         pipeline_busy,
    output logic                         group_done,

    // Compatibility alias: in v4 this means the same as group_done.
    output logic                         pipeline_done,

    output logic                         start_while_busy_error,
    output logic                         invalid_group_id_error,
    output logic                         adapter_protocol_error,
    output logic                         adapter_global_last_error,
    output logic                         softmax_row_error,
    output logic                         softmax_metadata_error
);
    logic              qk_start;
    logic [GROUP_W-1:0] group_id_reg;
    logic              group_id_valid;

    logic              score_valid;
    logic              score_ready;
    logic [15:0]       score_bf16;
    logic [31:0]       score_fp32_debug;
    logic [HEAD_W-1:0] score_head;
    logic [POS_W-1:0]  score_row;
    logic [POS_W-1:0]  score_col;
    logic              score_last;

    logic              frontend_group_done;
    logic              frontend_pipeline_done;
    logic              frontend_prob_group_last;
    logic              frontend_prob_global_last;

    assign pipeline_busy    = qk_busy || frontend_busy;
    assign group_start_ready = !pipeline_busy;
    assign group_id_valid    = ($unsigned(group_id) < GQA_GROUPS);
    assign qk_start          = group_start && group_start_ready && group_id_valid;

    assign active_group_id   = group_id_reg;
    assign req_group_id      = group_id_reg;
    assign req_kv_head       = group_id_reg;
    assign req_global_q_head = ($unsigned(group_id_reg) * Q_HEADS) + $unsigned(req_head);

    assign prob_group_id     = group_id_reg;
    assign prob_group_last   = frontend_prob_group_last;
    assign prob_global_last  = frontend_prob_global_last;
    assign group_done        = frontend_group_done;
    assign pipeline_done     = frontend_pipeline_done;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            group_id_reg           <= '0;
            start_while_busy_error <= 1'b0;
            invalid_group_id_error <= 1'b0;
        end else begin
            if (qk_start) begin
                group_id_reg           <= group_id;
                start_while_busy_error <= 1'b0;
                invalid_group_id_error <= 1'b0;
            end else begin
                if (group_start && !group_start_ready)
                    start_while_busy_error <= 1'b1;
                if (group_start && group_start_ready && !group_id_valid)
                    invalid_group_id_error <= 1'b1;
            end
        end
    end

    qk_systolic_gqa_top #(
        .TILE(TILE), .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS), .SCALE_FP32(SCALE_FP32)
    ) u_qk (
        .clk(clk), .rst_n(rst_n), .start(qk_start), .busy(qk_busy), .done(qk_done),
        .vec_ready(vec_ready), .vec_valid(vec_valid),
        .q_vec_bf16(q_vec_bf16), .k_vec_bf16(k_vec_bf16),
        .req_head(req_head), .req_row_base(req_row_base),
        .req_col_base(req_col_base), .req_dim(req_dim),
        .score_valid(score_valid), .score_ready(score_ready),
        .score_bf16(score_bf16), .score_fp32_debug(score_fp32_debug),
        .score_head(score_head), .score_row(score_row), .score_col(score_col),
        .score_last(score_last)
    );

    qk_softmax_frontend #(
        .SEQ_LEN(SEQ_LEN), .TILE(TILE), .Q_HEADS(Q_HEADS),
        .HEAD_W(HEAD_W), .POS_W(POS_W), .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_frontend (
        .clk(clk), .rst_n(rst_n), .causal_en(causal_en),
        .qk_valid(score_valid), .qk_ready(score_ready), .qk_score(score_bf16),
        .qk_head(score_head), .qk_row(score_row), .qk_col(score_col),
        .qk_global_last(score_last),
        .prob_valid(prob_valid), .prob_ready(prob_ready), .prob_data(prob_data),
        .prob_first(prob_first), .prob_last(prob_last),
        .prob_group_last(frontend_prob_group_last),
        .prob_global_last(frontend_prob_global_last),
        .prob_head(prob_head), .prob_row(prob_row), .prob_col(prob_col),
        .group_done(frontend_group_done),
        .pipeline_done(frontend_pipeline_done),
        .busy(frontend_busy), .adapter_protocol_error(adapter_protocol_error),
        .adapter_global_last_error(adapter_global_last_error),
        .softmax_row_error(softmax_row_error),
        .softmax_metadata_error(softmax_metadata_error)
    );

    logic [31:0] unused_score_fp32_debug;
    assign unused_score_fp32_debug = score_fp32_debug;

    initial begin
        if (GQA_GROUPS < 1)
            $error("qk_softmax_pipeline_top: GQA_GROUPS must be at least 1");
        if (Q_HEADS < 1)
            $error("qk_softmax_pipeline_top: Q_HEADS must be at least 1");
    end
endmodule
