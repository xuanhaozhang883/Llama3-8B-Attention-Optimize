`timescale 1ns/1ps

// Full Responsibility-B integration shell:
// one GQA group of real QK -> Complete Score Tile FIFO ->
// Causal Mask -> Row Tile Buffer -> Softmax.
//
// FlashAttention Stage 1 inserts an atomic 4x4 tile boundary while preserving
// the verified scalar interfaces and all existing Softmax/PV mathematics.
//
// v4 group contract:
//   * One launch processes exactly one 4Q/1KV GQA group.
//   * group_id identifies the global KV head (0..7 for Llama-3.1-8B).
//   * req_head/prob_head remain local Q-head numbers inside the group (0..3).
//   * req_global_q_head = group_id * Q_HEADS + req_head.
//   * The same group_start/group_id must be delivered to the C backend.
module qk_softmax_pipeline_top #(
    parameter int TILE      = 4,
    parameter int QK_LANES  = 1,
    parameter bit CAUSAL_QK_TILE_SKIP = 1'b0,
    parameter int SCORE_FIFO_DEPTH = 8,
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
    output logic [31:0]                  qk_tiles_computed,
    output logic [31:0]                  qk_tiles_skipped,
    output logic [31:0]                  masked_tiles_emitted,
    output logic                         causal_skip_error,
    output logic                         frontend_busy,
    output logic                         mask_adapter_busy,
    output logic                         softmax_busy,
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

    logic              qk_score_valid;
    logic              qk_score_ready;
    logic [15:0]       qk_score_bf16;
    logic [31:0]       score_fp32_debug;
    logic [HEAD_W-1:0] qk_score_head;
    logic [POS_W-1:0]  qk_score_row;
    logic [POS_W-1:0]  qk_score_col;
    logic              qk_score_last;

    logic              score_valid;
    logic              score_ready;
    logic [15:0]       score_bf16;
    logic [HEAD_W-1:0] score_head;
    logic [POS_W-1:0]  score_row;
    logic [POS_W-1:0]  score_col;
    logic              score_last;

    logic              score_fifo_busy;
    logic [31:0]       score_fifo_tiles_enqueued;
    logic [31:0]       score_fifo_tiles_dequeued;
    logic [31:0]       score_fifo_backpressure_cycles;
    logic [7:0]        score_fifo_occupancy;
    logic [7:0]        score_fifo_max_occupancy;
    logic              score_fifo_protocol_error;
    logic              score_fifo_group_boundary_error;

    logic              frontend_group_done;
    logic              frontend_pipeline_done;
    logic              frontend_prob_group_last;
    logic              frontend_prob_global_last;
    logic              frontend_adapter_protocol_error;

    assign pipeline_busy    = qk_busy || frontend_busy || score_fifo_busy;
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
    assign adapter_protocol_error = frontend_adapter_protocol_error ||
                                    score_fifo_protocol_error ||
                                    score_fifo_group_boundary_error;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            group_id_reg           <= '0;
            start_while_busy_error <= 1'b0;
            invalid_group_id_error <= 1'b0;
            score_fifo_group_boundary_error <= 1'b0;
        end else begin
            if (qk_start) begin
                group_id_reg           <= group_id;
                start_while_busy_error <= 1'b0;
                invalid_group_id_error <= 1'b0;
                score_fifo_group_boundary_error <= 1'b0;
            end else begin
                if (group_start && !group_start_ready)
                    start_while_busy_error <= 1'b1;
                if (group_start && group_start_ready && !group_id_valid)
                    invalid_group_id_error <= 1'b1;
            end

            // Softmax completes long after the final score tile has left this
            // FIFO. Any residue or counter mismatch is therefore a real group
            // boundary violation, not normal pipeline overlap.
            if (frontend_group_done &&
                (score_fifo_busy ||
                 (score_fifo_tiles_enqueued !=
                  score_fifo_tiles_dequeued)))
                score_fifo_group_boundary_error <= 1'b1;
        end
    end

    generate
        // This branch is the exact v2.5 QK path.  It remains available for
        // bit-for-bit fallback and isolated regression.
        if ((QK_LANES == 1) && !CAUSAL_QK_TILE_SKIP) begin : GEN_LEGACY_QK
            qk_systolic_gqa_top #(
                .TILE(TILE), .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
                .Q_HEADS(Q_HEADS), .SCALE_FP32(SCALE_FP32)
            ) u_qk (
                .clk(clk), .rst_n(rst_n), .start(qk_start),
                .busy(qk_busy), .done(qk_done),
                .vec_ready(vec_ready), .vec_valid(vec_valid),
                .q_vec_bf16(q_vec_bf16), .k_vec_bf16(k_vec_bf16),
                .req_head(req_head), .req_row_base(req_row_base),
                .req_col_base(req_col_base), .req_dim(req_dim),
                .score_valid(qk_score_valid), .score_ready(qk_score_ready),
                .score_bf16(qk_score_bf16),
                .score_fp32_debug(score_fp32_debug),
                .score_head(qk_score_head), .score_row(qk_score_row),
                .score_col(qk_score_col), .score_last(qk_score_last)
            );
            assign qk_tiles_computed = 32'd0;
            assign qk_tiles_skipped = 32'd0;
            assign masked_tiles_emitted = 32'd0;
            assign causal_skip_error = 1'b0;
        end else begin : GEN_PARALLEL_CAUSAL_QK
            qk_parallel_systolic_gqa_top #(
                .TILE(TILE),
                .QK_LANES(QK_LANES),
                .SEQ_LEN(SEQ_LEN),
                .HEAD_DIM(HEAD_DIM),
                .Q_HEADS(Q_HEADS),
                .CAUSAL_TILE_SKIP(CAUSAL_QK_TILE_SKIP),
                .SCALE_FP32(SCALE_FP32)
            ) u_qk (
                .clk(clk), .rst_n(rst_n), .start(qk_start),
                .causal_en(causal_en),
                .busy(qk_busy), .done(qk_done),
                .vec_ready(vec_ready), .vec_valid(vec_valid),
                .q_vec_bf16(q_vec_bf16), .k_vec_bf16(k_vec_bf16),
                .req_head(req_head), .req_row_base(req_row_base),
                .req_col_base(req_col_base), .req_dim(req_dim),
                .score_valid(qk_score_valid), .score_ready(qk_score_ready),
                .score_bf16(qk_score_bf16),
                .score_fp32_debug(score_fp32_debug),
                .score_head(qk_score_head), .score_row(qk_score_row),
                .score_col(qk_score_col), .score_last(qk_score_last),
                .qk_tiles_computed(qk_tiles_computed),
                .qk_tiles_skipped(qk_tiles_skipped),
                .masked_tiles_emitted(masked_tiles_emitted),
                .causal_skip_error(causal_skip_error)
            );
        end
    endgenerate

    flash_score_tile_fifo #(
        .TILE(TILE),
        .FIFO_DEPTH(SCORE_FIFO_DEPTH),
        .HEAD_W(HEAD_W),
        .POS_W(POS_W)
    ) u_score_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .status_clear(qk_start),
        .in_valid(qk_score_valid),
        .in_ready(qk_score_ready),
        .in_score_bf16(qk_score_bf16),
        .in_score_head(qk_score_head),
        .in_score_row(qk_score_row),
        .in_score_col(qk_score_col),
        .in_score_last(qk_score_last),
        .out_valid(score_valid),
        .out_ready(score_ready),
        .out_score_bf16(score_bf16),
        .out_score_head(score_head),
        .out_score_row(score_row),
        .out_score_col(score_col),
        .out_score_last(score_last),
        .busy(score_fifo_busy),
        .tiles_enqueued(score_fifo_tiles_enqueued),
        .tiles_dequeued(score_fifo_tiles_dequeued),
        .input_backpressure_cycles(score_fifo_backpressure_cycles),
        .occupancy(score_fifo_occupancy),
        .max_occupancy(score_fifo_max_occupancy),
        .protocol_error(score_fifo_protocol_error)
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
        .busy(frontend_busy),
        .adapter_busy(mask_adapter_busy), .softmax_busy(softmax_busy),
        .adapter_protocol_error(frontend_adapter_protocol_error),
        .adapter_global_last_error(adapter_global_last_error),
        .softmax_row_error(softmax_row_error),
        .softmax_metadata_error(softmax_metadata_error)
    );

    logic [31:0] unused_score_fp32_debug;
    assign unused_score_fp32_debug = score_fp32_debug;

    logic unused_score_fifo_metrics;
    assign unused_score_fifo_metrics = &{
        1'b0,
        score_fifo_backpressure_cycles,
        score_fifo_occupancy,
        score_fifo_max_occupancy
    };

    initial begin
        if (GQA_GROUPS < 1)
            $error("qk_softmax_pipeline_top: GQA_GROUPS must be at least 1");
        if (Q_HEADS < 1)
            $error("qk_softmax_pipeline_top: Q_HEADS must be at least 1");
        if ((QK_LANES < 1) || (QK_LANES > 2))
            $error("qk_softmax_pipeline_top: QK_LANES must be 1 or 2");
        if (TILE != 4)
            $error("qk_softmax_pipeline_top: Stage 1 FIFO requires TILE=4");
        if (SCORE_FIFO_DEPTH < 2 || SCORE_FIFO_DEPTH > 255)
            $error("qk_softmax_pipeline_top: SCORE_FIFO_DEPTH must be in [2,255]");
    end
endmodule
