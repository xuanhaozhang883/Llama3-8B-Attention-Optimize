`timescale 1ns/1ps

// One-GQA-group QK producer -> FlashAttention consumer integration.
//
// The QK implementation is intentionally instantiated without modification.
// Its scalar score order is the frozen producer/consumer contract; causal
// masks are derived from the accompanying row/column metadata.  Completion is
// the acceptance of the final Context item, not the earlier QK-done pulse.
module qk_flash_attention_pipeline_top #(
    parameter int TILE=4,
    parameter int QK_LANES=4,
    parameter bit CAUSAL_QK_TILE_SKIP=1'b1,
    parameter int V_LANES=8,
    parameter int FIFO_DEPTH_TILES=4,
    parameter int SEQ_LEN=128,
    parameter int HEAD_DIM=128,
    parameter int Q_HEADS=4,
    parameter int GQA_GROUPS=8,
    parameter int HEAD_W=(Q_HEADS<=1)?1:$clog2(Q_HEADS),
    parameter int GROUP_W=(GQA_GROUPS<=1)?1:$clog2(GQA_GROUPS),
    parameter int GLOBAL_Q_HEAD_W=((Q_HEADS*GQA_GROUPS)<=1)?1:
                                $clog2(Q_HEADS*GQA_GROUPS),
    parameter int POS_W=(SEQ_LEN<=1)?1:$clog2(SEQ_LEN),
    parameter int DIM_W=(HEAD_DIM<=1)?1:$clog2(HEAD_DIM),
    parameter int V_ADDR_W=((GQA_GROUPS*SEQ_LEN*HEAD_DIM)<=1)?1:
                           $clog2(GQA_GROUPS*SEQ_LEN*HEAD_DIM),
    parameter logic [31:0] SCALE_FP32=32'h3DB504F3,
    parameter EXP_LUT_FILE="exp_lut_q15.mem"
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,

    input  logic group_start,
    input  logic [GROUP_W-1:0] group_id,
    output logic group_start_ready,
    output logic [GROUP_W-1:0] active_group_id,
    input  logic causal_en,

    output logic vec_ready,
    input  logic vec_valid,
    input  logic [TILE*16-1:0] q_vec_bf16,
    input  logic [TILE*16-1:0] k_vec_bf16,
    output logic [HEAD_W-1:0] req_head,
    output logic [GROUP_W-1:0] req_group_id,
    output logic [GLOBAL_Q_HEAD_W-1:0] req_global_q_head,
    output logic [GROUP_W-1:0] req_kv_head,
    output logic [POS_W-1:0] req_row_base,
    output logic [POS_W-1:0] req_col_base,
    output logic [DIM_W-1:0] req_dim,

    input  logic v_load_valid,
    output logic v_load_ready,
    input  logic [V_ADDR_W-1:0] v_load_addr,
    input  logic [V_LANES*16-1:0] v_load_data,

    output logic context_valid,
    input  logic context_ready,
    output logic [15:0] context_bf16,
    output logic [31:0] context_fp32_debug,
    output logic [GROUP_W-1:0] context_group,
    output logic [HEAD_W-1:0] context_head,
    output logic [GLOBAL_Q_HEAD_W-1:0] context_global_head,
    output logic [POS_W-1:0] context_row,
    output logic [DIM_W-1:0] context_col,
    output logic context_last,

    output logic qk_busy,
    output logic qk_done,
    output logic consumer_busy,
    output logic busy,
    output logic group_done,
    output logic [31:0] qk_tiles_computed,
    output logic [31:0] qk_tiles_skipped,
    output logic [31:0] masked_tiles_emitted,
    output logic [31:0] score_tiles_enqueued,
    output logic [31:0] score_tiles_dequeued,
    output logic [31:0] softmax_tiles_processed,
    output logic [31:0] context_tiles_processed,
    output logic [31:0] v_vectors_read,
    output logic causal_skip_error,
    output logic start_while_busy_error,
    output logic invalid_group_id_error,
    output logic consumer_protocol_error,
    output logic protocol_error
);
    logic qk_start;
    logic [GROUP_W-1:0] group_id_reg;
    logic group_id_valid;
    logic score_valid;
    logic score_ready;
    logic [15:0] score_bf16;
    logic [31:0] score_fp32_debug;
    logic [HEAD_W-1:0] score_head;
    logic [POS_W-1:0] score_row;
    logic [POS_W-1:0] score_col;
    logic score_last;
    logic score_mask;

    assign busy = qk_busy || consumer_busy;
    assign group_start_ready = !busy;
    assign group_id_valid = ($unsigned(group_id) < GQA_GROUPS);
    assign qk_start = group_start && group_start_ready && group_id_valid;
    assign active_group_id = group_id_reg;
    assign req_group_id = group_id_reg;
    assign req_kv_head = group_id_reg;
    assign req_global_q_head =
        ($unsigned(group_id_reg)*Q_HEADS) + $unsigned(req_head);
    assign score_mask = causal_en &&
                        ($unsigned(score_col) > $unsigned(score_row));
    assign group_done = context_valid && context_ready && context_last;
    assign protocol_error = start_while_busy_error ||
                            invalid_group_id_error ||
                            causal_skip_error || consumer_protocol_error;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            group_id_reg <= '0;
            start_while_busy_error <= 1'b0;
            invalid_group_id_error <= 1'b0;
        end else begin
            if (qk_start) begin
                group_id_reg <= group_id;
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

    generate
        if ((QK_LANES == 1) && !CAUSAL_QK_TILE_SKIP) begin : g_legacy_qk
            qk_systolic_gqa_top #(
                .TILE(TILE), .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
                .Q_HEADS(Q_HEADS), .SCALE_FP32(SCALE_FP32)
            ) u_qk (
                .clk, .rst_n, .start(qk_start), .busy(qk_busy), .done(qk_done),
                .vec_ready, .vec_valid, .q_vec_bf16, .k_vec_bf16,
                .req_head, .req_row_base, .req_col_base, .req_dim,
                .score_valid, .score_ready, .score_bf16,
                .score_fp32_debug, .score_head, .score_row, .score_col,
                .score_last
            );
            assign qk_tiles_computed = 32'd0;
            assign qk_tiles_skipped = 32'd0;
            assign masked_tiles_emitted = 32'd0;
            assign causal_skip_error = 1'b0;
        end else begin : g_parallel_qk
            qk_parallel_systolic_gqa_top #(
                .TILE(TILE), .QK_LANES(QK_LANES), .SEQ_LEN(SEQ_LEN),
                .HEAD_DIM(HEAD_DIM), .Q_HEADS(Q_HEADS),
                .CAUSAL_TILE_SKIP(CAUSAL_QK_TILE_SKIP),
                .SCALE_FP32(SCALE_FP32)
            ) u_qk (
                .clk, .rst_n, .start(qk_start), .causal_en,
                .busy(qk_busy), .done(qk_done),
                .vec_ready, .vec_valid, .q_vec_bf16, .k_vec_bf16,
                .req_head, .req_row_base, .req_col_base, .req_dim,
                .score_valid, .score_ready, .score_bf16,
                .score_fp32_debug, .score_head, .score_row, .score_col,
                .score_last, .qk_tiles_computed, .qk_tiles_skipped,
                .masked_tiles_emitted, .causal_skip_error
            );
        end
    endgenerate

    flash_attention_consumer_top #(
        .TILE(TILE), .V_LANES(V_LANES),
        .FIFO_DEPTH_TILES(FIFO_DEPTH_TILES), .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM), .Q_HEADS(Q_HEADS), .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W), .GROUP_W(GROUP_W),
        .GLOBAL_HEAD_W(GLOBAL_Q_HEAD_W), .POS_W(POS_W), .DIM_W(DIM_W),
        .V_ADDR_W(V_ADDR_W), .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_consumer (
        .clk, .rst_n, .clear,
        .score_valid, .score_ready, .score_bf16, .score_mask,
        .score_group(group_id_reg), .score_head, .score_row, .score_col,
        .score_last,
        .v_load_valid, .v_load_ready, .v_load_addr, .v_load_data,
        .context_valid, .context_ready, .context_bf16,
        .context_fp32_debug, .context_group, .context_head,
        .context_global_head, .context_row, .context_col, .context_last,
        .busy(consumer_busy), .protocol_error(consumer_protocol_error),
        .score_tiles_enqueued, .score_tiles_dequeued,
        .softmax_tiles_processed, .context_tiles_processed, .v_vectors_read
    );

    logic [31:0] unused_score_fp32_debug;
    assign unused_score_fp32_debug = score_fp32_debug;

    initial begin
        if (!((QK_LANES == 1) || (QK_LANES == 2) ||
              (QK_LANES == 4) || (QK_LANES == 8)))
            $error("qk_flash_attention_pipeline_top: QK_LANES must be 1, 2, 4, or 8");
        if (V_LANES != 8)
            $error("qk_flash_attention_pipeline_top: V_LANES must be 8");
    end
endmodule
