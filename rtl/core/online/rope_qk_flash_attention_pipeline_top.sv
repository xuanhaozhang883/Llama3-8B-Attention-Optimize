`timescale 1ns/1ps

// One-group raw Q/K -> RoPE cache -> QK -> FlashAttention pipeline.
module rope_qk_flash_attention_pipeline_top #(
    parameter int TILE=4,
    parameter int QK_LANES=4,
    parameter bit CAUSAL_QK_TILE_SKIP=1'b1,
    parameter bit CAUSAL_MODE=1'b0,
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
    parameter int PAIR_W=((HEAD_DIM/2)<=1)?1:$clog2(HEAD_DIM/2),
    parameter int V_ADDR_W=((GQA_GROUPS*SEQ_LEN*HEAD_DIM)<=1)?1:
                           $clog2(GQA_GROUPS*SEQ_LEN*HEAD_DIM),
    parameter int ROM_DEPTH=SEQ_LEN*(HEAD_DIM/2),
    parameter logic [31:0] SCALE_FP32=32'h3DB504F3,
    parameter EXP_LUT_FILE="exp_lut_q15.mem",
    parameter SIN_ROM_FILE="sin_bf16.hex",
    parameter COS_ROM_FILE="cos_bf16.hex"
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,
    input  logic group_start,
    input  logic [GROUP_W-1:0] group_id,
    output logic group_start_ready,
    output logic [GROUP_W-1:0] active_group_id,
    input  logic causal_en,

    output logic raw_req_valid,
    input  logic raw_req_ready,
    output logic raw_req_is_k,
    output logic [GLOBAL_Q_HEAD_W-1:0] raw_req_head,
    output logic [POS_W-1:0] raw_req_token,
    output logic [PAIR_W-1:0] raw_req_pair,
    input  logic raw_rsp_valid,
    output logic raw_rsp_ready,
    input  logic [15:0] raw_rsp_x0,
    input  logic [15:0] raw_rsp_x1,

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

    output logic [HEAD_W-1:0] req_head,
    output logic [GROUP_W-1:0] req_group_id,
    output logic [GLOBAL_Q_HEAD_W-1:0] req_global_q_head,
    output logic [GROUP_W-1:0] req_kv_head,
    output logic [POS_W-1:0] req_row_base,
    output logic [POS_W-1:0] req_col_base,
    output logic [DIM_W-1:0] req_dim,

    output logic rope_busy,
    output logic rope_done,
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
    output logic [31:0] causal_tiles_bypassed,
    output logic causal_bypass_error,
    output logic protocol_error
);
    logic bridge_start_ready;
    logic pipeline_start;
    logic pipeline_start_ready;
    logic [GROUP_W-1:0] pipeline_group_id;
    logic pipeline_busy;
    logic pipeline_done;
    logic qk_vec_ready;
    logic qk_vec_valid;
    logic [TILE*16-1:0] q_vec_bf16;
    logic [TILE*16-1:0] k_vec_bf16;
    logic pipeline_error;
    logic wrapper_start_error;
    logic unused_start_busy;
    logic unused_invalid_group;
    logic unused_causal_skip;

    assign group_start_ready = bridge_start_ready;
    assign busy = rope_busy || pipeline_busy;
    assign group_done = pipeline_done;
    assign protocol_error = wrapper_start_error || pipeline_error;

    always_ff @(posedge clk) begin
        if (!rst_n || clear)
            wrapper_start_error <= 1'b0;
        else if (group_start && group_start_ready)
            wrapper_start_error <= 1'b0;
        else if (group_start && !group_start_ready)
            wrapper_start_error <= 1'b1;
    end

    rope_group_bridge #(
        .QK_TILE(TILE), .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
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

    qk_flash_attention_pipeline_top #(
        .TILE(TILE), .QK_LANES(QK_LANES),
        .CAUSAL_QK_TILE_SKIP(CAUSAL_QK_TILE_SKIP),
        .CAUSAL_MODE(CAUSAL_MODE),
        .V_LANES(V_LANES), .FIFO_DEPTH_TILES(FIFO_DEPTH_TILES),
        .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM), .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS), .HEAD_W(HEAD_W), .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W), .POS_W(POS_W), .DIM_W(DIM_W),
        .V_ADDR_W(V_ADDR_W), .SCALE_FP32(SCALE_FP32),
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_pipeline (
        .clk, .rst_n, .clear,
        .group_start(pipeline_start), .group_id(pipeline_group_id),
        .group_start_ready(pipeline_start_ready), .active_group_id(),
        .causal_en,
        .vec_ready(qk_vec_ready), .vec_valid(qk_vec_valid),
        .q_vec_bf16, .k_vec_bf16,
        .req_head, .req_group_id, .req_global_q_head, .req_kv_head,
        .req_row_base, .req_col_base, .req_dim,
        .v_load_valid, .v_load_ready, .v_load_addr, .v_load_data,
        .context_valid, .context_ready, .context_bf16,
        .context_fp32_debug, .context_group, .context_head,
        .context_global_head, .context_row, .context_col, .context_last,
        .qk_busy, .qk_done, .consumer_busy, .busy(pipeline_busy),
        .group_done(pipeline_done),
        .qk_tiles_computed, .qk_tiles_skipped, .masked_tiles_emitted,
        .score_tiles_enqueued, .score_tiles_dequeued,
        .softmax_tiles_processed, .context_tiles_processed, .v_vectors_read,
        .causal_tiles_bypassed, .causal_bypass_error,
        .causal_skip_error(unused_causal_skip),
        .start_while_busy_error(unused_start_busy),
        .invalid_group_id_error(unused_invalid_group),
        .consumer_protocol_error(), .protocol_error(pipeline_error)
    );
endmodule
