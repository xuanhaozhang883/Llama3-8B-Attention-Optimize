`timescale 1ns/1ps

// v3.0 fused Attention system.  Groups are executed in order with no
// probability capture/replay stage.  The V cache is shared by every group and
// the Online core emits final Context words directly.
module attention_online_system_with_rope_top #(
    parameter int QK_TILE       = 4,
    parameter int QK_LANES      = 2,
    parameter int V_LANES       = 4,
    parameter int SEQ_LEN       = 128,
    parameter int HEAD_DIM      = 128,
    parameter int Q_HEADS       = 4,
    parameter int GQA_GROUPS    = 8,
    parameter int RUN_GQA_GROUPS = GQA_GROUPS,
    parameter int HEAD_W = (Q_HEADS <= 1) ? 1 : $clog2(Q_HEADS),
    parameter int GROUP_W = (GQA_GROUPS <= 1) ? 1 : $clog2(GQA_GROUPS),
    parameter int GLOBAL_Q_HEAD_W = ((Q_HEADS*GQA_GROUPS) <= 1) ? 1 :
                                      $clog2(Q_HEADS*GQA_GROUPS),
    parameter int POS_W = (SEQ_LEN <= 1) ? 1 : $clog2(SEQ_LEN),
    parameter int DIM_W = (HEAD_DIM <= 1) ? 1 : $clog2(HEAD_DIM),
    parameter int PAIR_W = ((HEAD_DIM/2) <= 1) ? 1 : $clog2(HEAD_DIM/2),
    parameter int V_ADDR_W = ((GQA_GROUPS*SEQ_LEN*HEAD_DIM) <= 1) ? 1 :
                              $clog2(GQA_GROUPS*SEQ_LEN*HEAD_DIM),
    parameter int ROM_DEPTH = SEQ_LEN*(HEAD_DIM/2),
    parameter logic [31:0] SCALE_FP32 = 32'h3DB504F3,
    parameter EXP_LUT_FILE = "exp_lut_q15.mem",
    parameter SIN_ROM_FILE = "sin_bf16.hex",
    parameter COS_ROM_FILE = "cos_bf16.hex"
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         start,
    output logic                         start_ready,
    output logic                         busy,
    output logic                         done,
    input  logic                         causal_en,

    output logic                         raw_req_valid,
    input  logic                         raw_req_ready,
    output logic                         raw_req_is_k,
    output logic [GLOBAL_Q_HEAD_W-1:0]   raw_req_head,
    output logic [POS_W-1:0]             raw_req_token,
    output logic [PAIR_W-1:0]            raw_req_pair,
    input  logic                         raw_rsp_valid,
    output logic                         raw_rsp_ready,
    input  logic [15:0]                  raw_rsp_x0,
    input  logic [15:0]                  raw_rsp_x1,

    input  logic                         v_load_valid,
    output logic                         v_load_ready,
    input  logic [V_ADDR_W-1:0]          v_load_addr,
    input  logic [V_LANES*16-1:0]        v_load_data,

    output logic                         context_valid,
    input  logic                         context_ready,
    output logic [15:0]                  context_bf16,
    output logic [31:0]                  context_fp32_debug,
    output logic [GROUP_W-1:0]           context_group_id,
    output logic [HEAD_W-1:0]            context_head,
    output logic [GLOBAL_Q_HEAD_W-1:0]   context_global_q_head,
    output logic [POS_W-1:0]             context_row,
    output logic [DIM_W-1:0]             context_col,
    output logic                         context_group_last,
    output logic                         context_global_last,

    output logic                         group_complete,
    output logic [GROUP_W-1:0]           completed_group_id,
    output logic [GROUP_W-1:0]           active_group_id,

    output logic                         rope_busy,
    output logic                         qk_busy,
    output logic                         online_busy,
    output logic [31:0]                  qk_tiles_computed,
    output logic [31:0]                  qk_tiles_skipped,
    output logic [31:0]                  masked_tiles_emitted,
    output logic [31:0]                  online_tiles_processed,
    output logic [31:0]                  online_tiles_skipped,
    output logic [31:0]                  online_rescale_events,
    output logic [31:0]                  online_v_vectors_read,
    output logic [31:0]                  online_mac_terms,
    output logic                         start_while_busy_error,
    output logic                         qk_causal_skip_error,
    output logic                         v_cache_error,
    output logic                         online_order_error,
    output logic                         online_numeric_error,
    output logic                         protocol_error
);
    typedef enum logic [1:0] {S_IDLE, S_LAUNCH, S_RUN} state_t;
    state_t state;

    logic [GROUP_W-1:0] group_counter;
    logic bridge_group_start;
    logic bridge_group_start_ready;
    logic [GROUP_W-1:0] bridge_active_group;
    logic pipeline_group_start;
    logic pipeline_group_start_ready;
    logic [GROUP_W-1:0] pipeline_group_id;
    logic online_start;
    logic online_start_ready;
    logic online_done;

    logic qk_start;
    logic qk_done;
    logic qk_vec_valid;
    logic qk_vec_ready;
    logic [QK_TILE*16-1:0] q_vec_bf16;
    logic [QK_TILE*16-1:0] k_vec_bf16;
    logic [HEAD_W-1:0] req_head;
    logic [POS_W-1:0] req_row_base;
    logic [POS_W-1:0] req_col_base;
    logic [DIM_W-1:0] req_dim;

    logic score_valid;
    logic score_ready;
    logic [15:0] score_bf16;
    logic [31:0] score_fp32_debug;
    logic [HEAD_W-1:0] score_head;
    logic [POS_W-1:0] score_row;
    logic [POS_W-1:0] score_col;
    logic score_last;

    logic v_req_valid;
    logic v_req_ready;
    logic [V_ADDR_W-1:0] v_req_addr;
    logic v_rsp_valid;
    logic v_rsp_ready;
    logic [V_LANES*16-1:0] v_rsp_data;

    logic online_context_group_last;
    logic unused_rope_done;
    logic [31:0] group_qk_tiles_computed;
    logic [31:0] group_qk_tiles_skipped;
    logic [31:0] group_masked_tiles_emitted;
    logic [31:0] group_online_tiles_processed;
    logic [31:0] group_online_tiles_skipped;
    logic [31:0] group_online_rescale_events;
    logic [31:0] group_online_v_vectors_read;
    logic [31:0] group_online_mac_terms;

    assign start_ready = (state == S_IDLE);
    assign busy = (state != S_IDLE) || rope_busy || qk_busy || online_busy;
    assign active_group_id = group_counter;
    assign bridge_group_start = (state == S_LAUNCH) &&
                                bridge_group_start_ready;
    assign pipeline_group_start_ready = online_start_ready && !qk_busy;
    assign qk_start = pipeline_group_start && pipeline_group_start_ready;
    assign online_start = qk_start;

    assign context_global_q_head =
        ($unsigned(context_group_id)*Q_HEADS) + $unsigned(context_head);
    assign context_group_last = online_context_group_last;
    assign context_global_last = online_context_group_last &&
                                 (group_counter == RUN_GQA_GROUPS-1);
    assign protocol_error = start_while_busy_error |
                            qk_causal_skip_error |
                            v_cache_error |
                            online_order_error |
                            online_numeric_error;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= S_IDLE;
            group_counter <= '0;
            done <= 1'b0;
            completed_group_id <= '0;
            group_complete <= 1'b0;
            start_while_busy_error <= 1'b0;
            qk_tiles_computed <= '0;
            qk_tiles_skipped <= '0;
            masked_tiles_emitted <= '0;
            online_tiles_processed <= '0;
            online_tiles_skipped <= '0;
            online_rescale_events <= '0;
            online_v_vectors_read <= '0;
            online_mac_terms <= '0;
        end else begin
            done <= 1'b0;
            group_complete <= 1'b0;
            if (start && !start_ready)
                start_while_busy_error <= 1'b1;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        group_counter <= '0;
                        start_while_busy_error <= 1'b0;
                        qk_tiles_computed <= '0;
                        qk_tiles_skipped <= '0;
                        masked_tiles_emitted <= '0;
                        online_tiles_processed <= '0;
                        online_tiles_skipped <= '0;
                        online_rescale_events <= '0;
                        online_v_vectors_read <= '0;
                        online_mac_terms <= '0;
                        state <= S_LAUNCH;
                    end
                end
                S_LAUNCH: begin
                    if (bridge_group_start)
                        state <= S_RUN;
                end
                S_RUN: begin
                    if (online_done) begin
                        completed_group_id <= group_counter;
                        group_complete <= 1'b1;
                        qk_tiles_computed <= qk_tiles_computed +
                                             group_qk_tiles_computed;
                        qk_tiles_skipped <= qk_tiles_skipped +
                                            group_qk_tiles_skipped;
                        masked_tiles_emitted <= masked_tiles_emitted +
                                                group_masked_tiles_emitted;
                        online_tiles_processed <= online_tiles_processed +
                                                  group_online_tiles_processed;
                        online_tiles_skipped <= online_tiles_skipped +
                                                group_online_tiles_skipped;
                        online_rescale_events <= online_rescale_events +
                                                 group_online_rescale_events;
                        online_v_vectors_read <= online_v_vectors_read +
                                                 group_online_v_vectors_read;
                        online_mac_terms <= online_mac_terms +
                                            group_online_mac_terms;
                        if (group_counter == RUN_GQA_GROUPS-1) begin
                            done <= 1'b1;
                            state <= S_IDLE;
                        end else begin
                            group_counter <= group_counter + 1'b1;
                            state <= S_LAUNCH;
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    rope_group_bridge #(
        .QK_TILE(QK_TILE), .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS), .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W), .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W), .POS_W(POS_W),
        .DIM_W(DIM_W), .PAIR_W(PAIR_W), .ROM_DEPTH(ROM_DEPTH),
        .SIN_ROM_FILE(SIN_ROM_FILE), .COS_ROM_FILE(COS_ROM_FILE)
    ) u_rope_bridge (
        .clk(clk), .rst_n(rst_n),
        .group_start(bridge_group_start), .group_id(group_counter),
        .group_start_ready(bridge_group_start_ready),
        .active_group_id(bridge_active_group), .busy(rope_busy),
        .rope_done(unused_rope_done),
        .raw_req_valid, .raw_req_ready, .raw_req_is_k, .raw_req_head,
        .raw_req_token, .raw_req_pair, .raw_rsp_valid, .raw_rsp_ready,
        .raw_rsp_x0, .raw_rsp_x1,
        .pipeline_group_start, .pipeline_group_start_ready,
        .pipeline_group_id, .pipeline_done(online_done),
        .req_head, .req_row_base, .req_col_base, .req_dim,
        .qk_vec_ready, .qk_vec_valid, .q_vec_bf16, .k_vec_bf16
    );

    qk_parallel_systolic_gqa_top #(
        .TILE(QK_TILE), .QK_LANES(QK_LANES), .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM), .Q_HEADS(Q_HEADS),
        .CAUSAL_TILE_SKIP(1'b1), .SCALE_FP32(SCALE_FP32)
    ) u_qk (
        .clk(clk), .rst_n(rst_n), .start(qk_start), .causal_en(causal_en),
        .busy(qk_busy), .done(qk_done),
        .vec_ready(qk_vec_ready), .vec_valid(qk_vec_valid),
        .q_vec_bf16(q_vec_bf16), .k_vec_bf16(k_vec_bf16),
        .req_head, .req_row_base, .req_col_base, .req_dim,
        .score_valid, .score_ready, .score_bf16, .score_fp32_debug,
        .score_head, .score_row, .score_col, .score_last,
        .qk_tiles_computed(group_qk_tiles_computed),
        .qk_tiles_skipped(group_qk_tiles_skipped),
        .masked_tiles_emitted(group_masked_tiles_emitted),
        .causal_skip_error(qk_causal_skip_error)
    );

    bf16_v_cache #(
        .NUM_KV_HEADS(GQA_GROUPS), .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM), .LANES(V_LANES), .ADDR_W(V_ADDR_W)
    ) u_v_cache (
        .clk(clk), .rst_n(rst_n),
        .load_valid(v_load_valid), .load_ready(v_load_ready),
        .load_addr(v_load_addr), .load_data(v_load_data),
        .req_valid(v_req_valid), .req_ready(v_req_ready),
        .req_addr(v_req_addr), .rsp_valid(v_rsp_valid),
        .rsp_ready(v_rsp_ready), .rsp_data(v_rsp_data),
        .protocol_error(v_cache_error)
    );

    online_softmax_context_tile #(
        .TILE(QK_TILE), .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS), .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W), .GROUP_W(GROUP_W), .POS_W(POS_W),
        .DIM_W(DIM_W), .V_ADDR_W(V_ADDR_W),
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_online (
        .clk(clk), .rst_n(rst_n), .start(online_start),
        .group_id(pipeline_group_id), .causal_en,
        .start_ready(online_start_ready), .busy(online_busy), .done(online_done),
        .score_valid, .score_ready, .score_bf16,
        .score_head, .score_row, .score_col,
        .score_global_last(score_last),
        .v_req_valid, .v_req_ready, .v_req_addr,
        .v_rsp_valid, .v_rsp_ready, .v_rsp_data,
        .context_valid, .context_ready, .context_bf16,
        .context_fp32_debug, .context_group_id, .context_head,
        .context_row, .context_col,
        .context_group_last(online_context_group_last),
        .online_tiles_processed(group_online_tiles_processed),
        .online_tiles_skipped(group_online_tiles_skipped),
        .online_rescale_events(group_online_rescale_events),
        .online_v_vectors_read(group_online_v_vectors_read),
        .online_mac_terms(group_online_mac_terms),
        .order_error(online_order_error),
        .numeric_error(online_numeric_error)
    );

    wire unused_status = &{1'b0, bridge_active_group, qk_done,
                           score_fp32_debug};

    initial begin
        if (V_LANES != QK_TILE)
            $error("attention_online_system_with_rope_top: V_LANES must equal QK_TILE");
        if ((RUN_GQA_GROUPS < 1) || (RUN_GQA_GROUPS > GQA_GROUPS))
            $error("attention_online_system_with_rope_top: invalid RUN_GQA_GROUPS");
    end
endmodule
