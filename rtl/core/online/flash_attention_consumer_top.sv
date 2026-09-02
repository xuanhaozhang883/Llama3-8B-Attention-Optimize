`timescale 1ns/1ps

// Standalone FlashAttention consumer subsystem.  The QK producer boundary is
// intentionally scalar and order-compatible with v3.0; everything after it is
// fused and no complete score/probability matrix is replayed.
module flash_attention_consumer_top #(
    parameter int TILE=4,
    parameter bit CAUSAL_MODE=1'b0,
    parameter int V_LANES=8,
    parameter int FIFO_DEPTH_TILES=4,
    parameter int SEQ_LEN=128,
    parameter int HEAD_DIM=128,
    parameter int Q_HEADS=4,
    parameter int GQA_GROUPS=8,
    parameter int HEAD_W=(Q_HEADS<=1)?1:$clog2(Q_HEADS),
    parameter int GROUP_W=(GQA_GROUPS<=1)?1:$clog2(GQA_GROUPS),
    parameter int GLOBAL_HEAD_W=((Q_HEADS*GQA_GROUPS)<=1)?1:
                              $clog2(Q_HEADS*GQA_GROUPS),
    parameter int POS_W=(SEQ_LEN<=1)?1:$clog2(SEQ_LEN),
    parameter int DIM_W=(HEAD_DIM<=1)?1:$clog2(HEAD_DIM),
    parameter int L_W=16+$clog2(SEQ_LEN+1),
    parameter int V_ADDR_W=((GQA_GROUPS*SEQ_LEN*HEAD_DIM)<=1)?1:
                           $clog2(GQA_GROUPS*SEQ_LEN*HEAD_DIM),
    parameter EXP_LUT_FILE="exp_lut_q15.mem"
) (
    input logic clk,
    input logic rst_n,
    input logic clear,
    input logic causal_en,

    input logic score_valid,
    output logic score_ready,
    input logic [15:0] score_bf16,
    input logic score_mask,
    input logic [GROUP_W-1:0] score_group,
    input logic [HEAD_W-1:0] score_head,
    input logic [POS_W-1:0] score_row,
    input logic [POS_W-1:0] score_col,
    input logic score_last,

    input logic v_load_valid,
    output logic v_load_ready,
    input logic [V_ADDR_W-1:0] v_load_addr,
    input logic [V_LANES*16-1:0] v_load_data,

    output logic context_valid,
    input logic context_ready,
    output logic [15:0] context_bf16,
    output logic [31:0] context_fp32_debug,
    output logic [GROUP_W-1:0] context_group,
    output logic [HEAD_W-1:0] context_head,
    output logic [GLOBAL_HEAD_W-1:0] context_global_head,
    output logic [POS_W-1:0] context_row,
    output logic [DIM_W-1:0] context_col,
    output logic context_last,

    output logic busy,
    output logic protocol_error,
    output logic [31:0] score_tiles_enqueued,
    output logic [31:0] score_tiles_dequeued,
    output logic [31:0] softmax_tiles_processed,
    output logic [31:0] context_tiles_processed,
    output logic [31:0] v_vectors_read,
    output logic [31:0] causal_tiles_bypassed,
    output logic causal_protocol_error
);
    logic fifo_valid, fifo_ready;
    logic [TILE*TILE*16-1:0] fifo_scores;
    logic [TILE*TILE-1:0] fifo_masks;
    logic [GROUP_W-1:0] fifo_group;
    logic [HEAD_W-1:0] fifo_head;
    logic [POS_W-1:0] fifo_row, fifo_col;
    logic fifo_all_masked, fifo_group_last;
    logic fifo_busy, fifo_error;

    logic sm_valid, sm_ready;
    logic [TILE*TILE*16-1:0] sm_weights;
    logic [TILE*16-1:0] sm_alpha;
    logic [TILE*L_W-1:0] sm_l;
    logic [TILE-1:0] sm_row_active;
    logic [GROUP_W-1:0] sm_group;
    logic [HEAD_W-1:0] sm_head;
    logic [POS_W-1:0] sm_row, sm_col;
    logic sm_row_last, sm_group_last;
    logic sm_busy, sm_error;

    logic v_req_valid, v_req_ready, v_rsp_valid, v_rsp_ready;
    logic [V_ADDR_W-1:0] v_req_addr;
    logic [V_LANES*16-1:0] v_rsp_data;
    logic v_cache_error;
    logic backend_busy, backend_error, backend_tile_done;
    logic softmax_in_valid, softmax_in_ready;
    logic causal_bypass_tile, causal_bypass_fire;
    logic illegal_causal_all_masked;

    assign causal_bypass_tile = CAUSAL_MODE && causal_en && fifo_valid &&
                                fifo_all_masked &&
                                ($unsigned(fifo_col) > $unsigned(fifo_row));
    assign illegal_causal_all_masked = CAUSAL_MODE && causal_en && fifo_valid &&
                                       fifo_all_masked &&
                                       !($unsigned(fifo_col) > $unsigned(fifo_row));
    assign softmax_in_valid = fifo_valid && !causal_bypass_tile;
    assign fifo_ready = causal_bypass_tile ? 1'b1 : softmax_in_ready;
    assign causal_bypass_fire = causal_bypass_tile && fifo_ready;

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            causal_tiles_bypassed <= '0;
            causal_protocol_error <= 1'b0;
        end else begin
            if (causal_bypass_fire)
                causal_tiles_bypassed <= causal_tiles_bypassed + 1'b1;
            if (illegal_causal_all_masked)
                causal_protocol_error <= 1'b1;
        end
    end

    flash_score_tile_fifo #(
        .SCORE_W(16), .TILE(TILE), .DEPTH_TILES(FIFO_DEPTH_TILES),
        .SEQ_LEN(SEQ_LEN), .Q_HEADS(Q_HEADS), .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W), .GROUP_W(GROUP_W), .POS_W(POS_W)
    ) u_score_fifo (
        .clk, .rst_n, .clear,
        .in_valid(score_valid), .in_ready(score_ready),
        .in_score(score_bf16), .in_mask(score_mask),
        .in_group(score_group), .in_head(score_head),
        .in_row(score_row), .in_col(score_col), .in_last(score_last),
        .out_valid(fifo_valid), .out_ready(fifo_ready),
        .out_scores(fifo_scores), .out_masks(fifo_masks),
        .out_group(fifo_group), .out_head(fifo_head),
        .out_row_base(fifo_row), .out_col_base(fifo_col),
        .out_all_masked(fifo_all_masked), .out_group_last(fifo_group_last),
        .busy(fifo_busy), .order_error(fifo_error),
        .tiles_enqueued(score_tiles_enqueued),
        .tiles_dequeued(score_tiles_dequeued)
    );

    flash_online_softmax_frontend #(
        .TILE(TILE), .CAUSAL_MODE(CAUSAL_MODE), .SEQ_LEN(SEQ_LEN),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS), .HEAD_W(HEAD_W), .GROUP_W(GROUP_W),
        .POS_W(POS_W), .L_W(L_W), .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_online_softmax (
        .clk, .rst_n, .clear, .causal_en,
        .in_valid(softmax_in_valid), .in_ready(softmax_in_ready),
        .in_scores_bf16(fifo_scores), .in_masks(fifo_masks),
        .in_group(fifo_group), .in_head(fifo_head),
        .in_row_base(fifo_row), .in_col_base(fifo_col),
        .in_group_last(fifo_group_last),
        .out_valid(sm_valid), .out_ready(sm_ready),
        .out_weights_q15(sm_weights), .out_alpha_q15(sm_alpha),
        .out_l_q15(sm_l), .out_row_active(sm_row_active),
        .out_group(sm_group), .out_head(sm_head),
        .out_row_base(sm_row), .out_col_base(sm_col),
        .out_row_tile_last(sm_row_last), .out_group_last(sm_group_last),
        .busy(sm_busy), .protocol_error(sm_error),
        .tiles_processed(softmax_tiles_processed)
    );

    bf16_v_cache #(
        .NUM_KV_HEADS(GQA_GROUPS), .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM), .LANES(V_LANES), .ADDR_W(V_ADDR_W)
    ) u_v_cache (
        .clk, .rst_n,
        .load_valid(v_load_valid), .load_ready(v_load_ready),
        .load_addr(v_load_addr), .load_data(v_load_data),
        .req_valid(v_req_valid), .req_ready(v_req_ready),
        .req_addr(v_req_addr), .rsp_valid(v_rsp_valid),
        .rsp_ready(v_rsp_ready), .rsp_data(v_rsp_data),
        .protocol_error(v_cache_error)
    );

    flash_context_fusion_backend #(
        .TILE(TILE), .V_LANES(V_LANES), .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM), .Q_HEADS(Q_HEADS), .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W), .GROUP_W(GROUP_W),
        .GLOBAL_HEAD_W(GLOBAL_HEAD_W), .POS_W(POS_W), .DIM_W(DIM_W),
        .L_W(L_W), .V_ADDR_W(V_ADDR_W)
    ) u_context_fusion (
        .clk, .rst_n, .clear,
        .in_valid(sm_valid), .in_ready(sm_ready),
        .in_weights_q15(sm_weights), .in_alpha_q15(sm_alpha),
        .in_l_q15(sm_l), .in_row_active(sm_row_active),
        .in_group(sm_group), .in_head(sm_head),
        .in_row_base(sm_row), .in_col_base(sm_col),
        .in_row_tile_last(sm_row_last), .in_group_last(sm_group_last),
        .v_req_valid, .v_req_ready, .v_req_addr,
        .v_rsp_valid, .v_rsp_ready, .v_rsp_data,
        .context_valid, .context_ready, .context_bf16,
        .context_fp32_debug, .context_group, .context_head,
        .context_global_head, .context_row, .context_col, .context_last,
        .busy(backend_busy), .tile_done(backend_tile_done),
        .protocol_error(backend_error),
        .tiles_processed(context_tiles_processed), .v_vectors_read
    );

    assign busy = fifo_busy || sm_busy || backend_busy;
    assign protocol_error = fifo_error || sm_error || backend_error ||
                            v_cache_error || causal_protocol_error;
    logic unused_backend_tile_done;
    assign unused_backend_tile_done = backend_tile_done;
endmodule
