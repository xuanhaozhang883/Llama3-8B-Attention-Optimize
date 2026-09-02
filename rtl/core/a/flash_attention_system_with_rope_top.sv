`timescale 1ns/1ps

// Full multi-group FlashAttention system integration.
//
// V is preloaded once into the eight-lane cache.  A command then executes the
// requested leading GQA groups in order.  Each group performs raw Q/K fetch,
// RoPE preparation, the unchanged scalar-order QK producer, Online Softmax and
// fused Context update.  There is no complete score/probability replay stage.
module flash_attention_system_with_rope_top #(
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
    parameter int RUN_GQA_GROUPS=GQA_GROUPS,
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
    input  logic start,
    output logic start_ready,
    output logic busy,
    output logic done,
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
    output logic context_group_last,
    output logic context_global_last,

    output logic [HEAD_W-1:0] req_head,
    output logic [GROUP_W-1:0] req_group_id,
    output logic [GLOBAL_Q_HEAD_W-1:0] req_global_q_head,
    output logic [GROUP_W-1:0] req_kv_head,
    output logic [POS_W-1:0] req_row_base,
    output logic [POS_W-1:0] req_col_base,
    output logic [DIM_W-1:0] req_dim,

    output logic group_complete,
    output logic [GROUP_W-1:0] completed_group_id,
    output logic [GROUP_W-1:0] active_group_id,
    output logic rope_busy,
    output logic qk_busy,
    output logic consumer_busy,
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
    output logic start_while_busy_error,
    output logic protocol_error
);
    typedef enum logic [1:0] {S_IDLE, S_LAUNCH, S_ACTIVE} state_t;
    state_t state;
    logic pipeline_clear;
    logic pipeline_group_start;
    logic pipeline_group_start_ready;
    logic pipeline_busy;
    logic pipeline_group_done;
    logic pipeline_protocol_error;
    logic pipeline_context_last;
    logic [31:0] group_qk_tiles_computed;
    logic [31:0] group_qk_tiles_skipped;
    logic [31:0] group_masked_tiles_emitted;
    logic unused_rope_done;
    logic unused_qk_done;

    assign start_ready = (state == S_IDLE);
    assign busy = (state != S_IDLE) || pipeline_busy;
    assign pipeline_group_start = (state == S_LAUNCH);
    assign context_group_last = pipeline_context_last;
    assign context_global_last = pipeline_context_last &&
        ($unsigned(context_group) == RUN_GQA_GROUPS-1);
    assign protocol_error = start_while_busy_error ||
                            pipeline_protocol_error;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            pipeline_clear <= 1'b0;
            done <= 1'b0;
            group_complete <= 1'b0;
            completed_group_id <= '0;
            active_group_id <= '0;
            start_while_busy_error <= 1'b0;
            qk_tiles_computed <= '0;
            qk_tiles_skipped <= '0;
            masked_tiles_emitted <= '0;
        end else begin
            pipeline_clear <= 1'b0;
            done <= 1'b0;
            group_complete <= 1'b0;
            if (start && !start_ready)
                start_while_busy_error <= 1'b1;

            case (state)
                S_IDLE: if (start && start_ready) begin
                    pipeline_clear <= 1'b1;
                    active_group_id <= '0;
                    completed_group_id <= '0;
                    start_while_busy_error <= 1'b0;
                    qk_tiles_computed <= '0;
                    qk_tiles_skipped <= '0;
                    masked_tiles_emitted <= '0;
                    state <= S_LAUNCH;
                end

                S_LAUNCH: if (pipeline_group_start_ready)
                    state <= S_ACTIVE;

                S_ACTIVE: if (pipeline_group_done) begin
                    group_complete <= 1'b1;
                    completed_group_id <= active_group_id;
                    qk_tiles_computed <= qk_tiles_computed +
                                         group_qk_tiles_computed;
                    qk_tiles_skipped <= qk_tiles_skipped +
                                        group_qk_tiles_skipped;
                    masked_tiles_emitted <= masked_tiles_emitted +
                                            group_masked_tiles_emitted;
                    if ($unsigned(active_group_id) == RUN_GQA_GROUPS-1) begin
                        done <= 1'b1;
                        state <= S_IDLE;
                    end else begin
                        active_group_id <= active_group_id + 1'b1;
                        state <= S_LAUNCH;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    rope_qk_flash_attention_pipeline_top #(
        .TILE(TILE), .QK_LANES(QK_LANES),
        .CAUSAL_QK_TILE_SKIP(CAUSAL_QK_TILE_SKIP),
        .CAUSAL_MODE(CAUSAL_MODE),
        .V_LANES(V_LANES), .FIFO_DEPTH_TILES(FIFO_DEPTH_TILES),
        .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM), .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS), .HEAD_W(HEAD_W), .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W), .POS_W(POS_W), .DIM_W(DIM_W),
        .PAIR_W(PAIR_W), .V_ADDR_W(V_ADDR_W), .ROM_DEPTH(ROM_DEPTH),
        .SCALE_FP32(SCALE_FP32), .EXP_LUT_FILE(EXP_LUT_FILE),
        .SIN_ROM_FILE(SIN_ROM_FILE), .COS_ROM_FILE(COS_ROM_FILE)
    ) u_group_pipeline (
        .clk, .rst_n, .clear(pipeline_clear),
        .group_start(pipeline_group_start), .group_id(active_group_id),
        .group_start_ready(pipeline_group_start_ready),
        .active_group_id(), .causal_en,
        .raw_req_valid, .raw_req_ready, .raw_req_is_k, .raw_req_head,
        .raw_req_token, .raw_req_pair, .raw_rsp_valid, .raw_rsp_ready,
        .raw_rsp_x0, .raw_rsp_x1,
        .v_load_valid, .v_load_ready, .v_load_addr, .v_load_data,
        .context_valid, .context_ready, .context_bf16,
        .context_fp32_debug, .context_group, .context_head,
        .context_global_head, .context_row, .context_col,
        .context_last(pipeline_context_last),
        .req_head, .req_group_id, .req_global_q_head, .req_kv_head,
        .req_row_base, .req_col_base, .req_dim,
        .rope_busy, .rope_done(unused_rope_done), .qk_busy,
        .qk_done(unused_qk_done), .consumer_busy,
        .busy(pipeline_busy), .group_done(pipeline_group_done),
        .qk_tiles_computed(group_qk_tiles_computed),
        .qk_tiles_skipped(group_qk_tiles_skipped),
        .masked_tiles_emitted(group_masked_tiles_emitted),
        .score_tiles_enqueued, .score_tiles_dequeued,
        .softmax_tiles_processed, .context_tiles_processed, .v_vectors_read,
        .causal_tiles_bypassed, .causal_bypass_error,
        .protocol_error(pipeline_protocol_error)
    );

    initial begin
        if ((RUN_GQA_GROUPS < 1) || (RUN_GQA_GROUPS > GQA_GROUPS))
            $error("flash_attention_system_with_rope_top: RUN_GQA_GROUPS must be in [1,GQA_GROUPS]");
        if (!((QK_LANES == 1) || (QK_LANES == 2) ||
              (QK_LANES == 4) || (QK_LANES == 8)))
            $error("flash_attention_system_with_rope_top: QK_LANES must be 1, 2, 4, or 8");
        if (V_LANES != 8)
            $error("flash_attention_system_with_rope_top: V_LANES must be 8");
    end
endmodule
