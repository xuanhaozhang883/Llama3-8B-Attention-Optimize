`timescale 1ns/1ps

// ============================================================================
// attention_system_with_rope_pv_top
// ----------------------------------------------------------------------------
// RoPE-aware A-owned integration based on the already-verified A/B+C/PV
// boundary.
//
// v2.6 default path:
//   dual TILE4 QK + causal whole-tile skip
//   native TILE4 Softmax/PV capture
//   dual TILE4 real PV + causal row-effective reduction
//   existing cross-Group Ping-Pong scheduling
//
// QK_LANES=1, PV_LANES=1, CAPTURE_TILE=2 selects the exact v2.5 structural
// fallback path.
// The external Q/K interface is a one-outstanding-request raw-memory contract.
// ============================================================================
module attention_system_with_rope_pv_top #(
    parameter int QK_TILE       = 4,
    parameter int QK_LANES      = 2,
    parameter int CAPTURE_TILE  = 4,
    parameter int BC_PV_TILE    = CAPTURE_TILE,
    parameter int REAL_PV_TILE  = 4,
    parameter int PV_LANES      = 2,
    parameter bit CAUSAL_QK_TILE_SKIP = 1'b1,
    parameter bit CAUSAL_PV_ROW_EFFECTIVE = 1'b1,
    parameter int SEQ_LEN       = 128,
    parameter int HEAD_DIM      = 128,
    parameter int Q_HEADS       = 4,
    parameter int GQA_GROUPS    = 8,
    // Number of leading Groups executed by one command. Physical widths and
    // cache capacity still use GQA_GROUPS. Keep the default for a full run;
    // set this to 1 for golden_model_outputs/fpga_slice.
    parameter int RUN_GQA_GROUPS = GQA_GROUPS,
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
    parameter int PAIR_W        =
        ((HEAD_DIM/2) <= 1) ? 1 : $clog2(HEAD_DIM/2),
    parameter int V_ADDR_W      =
        ((GQA_GROUPS*SEQ_LEN*HEAD_DIM) <= 1) ? 1 :
        $clog2(GQA_GROUPS*SEQ_LEN*HEAD_DIM),
    parameter int ROM_DEPTH     = SEQ_LEN*(HEAD_DIM/2),
    parameter logic [31:0] SCALE_FP32 = 32'h3DB504F3,
    parameter EXP_LUT_FILE = "exp_lut_q15.mem",
    parameter SIN_ROM_FILE = "sin_bf16.hex",
    parameter COS_ROM_FILE = "cos_bf16.hex"
) (
    input  logic clk,
    input  logic rst_n,

    input  logic start,
    output logic start_ready,
    output logic busy,
    output logic done,
    input  logic causal_en,

    // Raw pre-RoPE Q/K memory boundary. A request is accepted on
    // raw_req_valid && raw_req_ready. Exactly one matching response is then
    // returned on raw_rsp_valid && raw_rsp_ready.
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

    // QK request monitor after the Group's Q/K values have been rotated and
    // cached by the RoPE bridge.
    output logic [HEAD_W-1:0] req_head,
    output logic [GROUP_W-1:0] req_group_id,
    output logic [GLOBAL_Q_HEAD_W-1:0] req_global_q_head,
    output logic [GROUP_W-1:0] req_kv_head,
    output logic [POS_W-1:0] req_row_base,
    output logic [POS_W-1:0] req_col_base,
    output logic [DIM_W-1:0] req_dim,

    // V preload width follows the B+C/native-capture tile width.
    input  logic v_load_valid,
    output logic v_load_ready,
    input  logic [V_ADDR_W-1:0] v_load_addr,
    input  logic [CAPTURE_TILE*16-1:0] v_load_data,

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

    // B+C native capture stream monitor.
    output logic mon_bc_pv_valid,
    output logic mon_bc_pv_ready,
    output logic [CAPTURE_TILE*16-1:0] mon_bc_p_vec_bf16,
    output logic [CAPTURE_TILE*16-1:0] mon_bc_v_vec_bf16,
    output logic [GROUP_W-1:0] mon_bc_pv_group_id,
    output logic [HEAD_W-1:0] mon_bc_pv_head,
    output logic [POS_W-1:0] mon_bc_pv_row_base,
    output logic [DIM_W-1:0] mon_bc_pv_feature_base,
    output logic [POS_W-1:0] mon_bc_pv_reduce_index,

    // Real TILE4 PV feed monitor.
    output logic mon_real_pv_valid,
    output logic mon_real_pv_ready,
    output logic [63:0] mon_real_p_vec_bf16,
    output logic [PV_LANES*64-1:0] mon_real_v_vec_bf16,
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
    output logic rope_busy,
    output logic qk_busy,
    output logic mask_busy,
    output logic softmax_busy,
    output logic bc_backend_busy,
    output logic capture_busy,
    output logic repack_input_stall,
    output logic pv_feed_stall,
    output logic softmax_output_stall,

    output logic [31:0] qk_tiles_computed,
    output logic [31:0] qk_tiles_skipped,
    output logic [31:0] masked_tiles_emitted,
    output logic qk_causal_skip_error,
    output logic [31:0] pv_reductions_computed,
    output logic [31:0] pv_reductions_skipped,
    output logic pv_zero_probability_violation,
    output logic [31:0] native_vectors_captured,

    output logic start_while_busy_error,
    output logic controller_error,
    output logic bc_protocol_error,
    output logic v_cache_error,
    output logic repack_error,
    output logic protocol_error
);

    localparam bit V25_STRUCTURAL_FALLBACK =
        (QK_LANES == 1) && (CAPTURE_TILE == 2) && (PV_LANES == 1);
    localparam bit EFFECTIVE_QK_CAUSAL_SKIP =
        CAUSAL_QK_TILE_SKIP && !V25_STRUCTURAL_FALLBACK;

    attention_with_pv_config_guard #(
        .QK_TILE(QK_TILE),
        .QK_LANES(QK_LANES),
        .CAPTURE_TILE(CAPTURE_TILE),
        .BC_PV_TILE(BC_PV_TILE),
        .REAL_PV_TILE(REAL_PV_TILE),
        .PV_LANES(PV_LANES),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS)
    ) u_config_guard ();

    logic controller_busy;
    logic buffer_start;
    logic bc_group_start;
    logic bc_group_start_ready;
    logic [GROUP_W-1:0] bc_launch_group_id;
    logic fill_start_valid;
    logic fill_start_ready;
    logic [GROUP_W-1:0] fill_start_group_id;
    logic capture_done;
    logic drain_valid;
    logic drain_ready;
    logic [GROUP_W-1:0] drain_group_id;
    logic drain_release;
    logic pv_start;
    logic pv_feed_enable;
    logic [GROUP_W-1:0] pv_active_group_id;
    logic [1:0] repack_bank0_state;
    logic [1:0] repack_bank1_state;
    logic repack_drain_active;
    logic repack_buffer_busy;

    logic [GROUP_W-1:0] bc_active_group_id;

    logic v_req_valid;
    logic v_req_ready;
    logic [GROUP_W-1:0] v_req_kv_head;
    logic [POS_W-1:0] v_req_reduce_index;
    logic [DIM_W-1:0] v_req_feature_base;
    logic [V_ADDR_W-1:0] v_req_addr;
    logic v_rsp_valid;
    logic v_rsp_ready;
    logic [CAPTURE_TILE*16-1:0] v_rsp_data;

    logic [CAPTURE_TILE*16-1:0] bc_p_vec_bf16;
    logic [CAPTURE_TILE*16-1:0] bc_v_vec_bf16;
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
    logic [PV_LANES*REAL_PV_TILE*16-1:0] real_v_vec_bf16;
    logic real_pv_vec_valid;
    logic real_pv_vec_ready;

    logic [HEAD_W-1:0] real_pv_req_head;
    logic [POS_W-1:0] real_pv_req_row_base;
    logic [DIM_W-1:0] real_pv_req_col_base;
    logic [POS_W-1:0] real_pv_req_reduce;

    logic pv_context_last;

    logic unused_qk_done;
    logic unused_b_frontend_busy;
    logic unused_prob_input_done;
    logic unused_rope_done;

    assign busy = controller_busy || bc_busy || pv_busy;

    initial begin
        if ((RUN_GQA_GROUPS < 1) || (RUN_GQA_GROUPS > GQA_GROUPS))
            $error("attention_system_with_rope_pv_top: RUN_GQA_GROUPS must be in [1,GQA_GROUPS]");
    end

    attention_group_pingpong_controller #(
        .NUM_GROUPS(RUN_GQA_GROUPS),
        .GROUP_W(GROUP_W)
    ) u_group_controller (
        .clk(clk),
        .rst_n(rst_n),

        .start(start),
        .start_ready(start_ready),
        .busy(controller_busy),
        .done(done),

        .buffer_start(buffer_start),

        .fill_start_valid(fill_start_valid),
        .fill_start_ready(fill_start_ready),
        .fill_start_group_id(fill_start_group_id),

        .bc_group_start(bc_group_start),
        .bc_group_start_ready(bc_group_start_ready),
        .bc_group_id(bc_launch_group_id),
        .bc_group_done(bc_group_done),
        .bc_busy(bc_busy),

        .capture_done(capture_done),

        .drain_valid(drain_valid),
        .drain_ready(drain_ready),
        .drain_group_id(drain_group_id),

        .pv_start(pv_start),
        .pv_feed_enable(pv_feed_enable),
        .pv_group_id(pv_active_group_id),
        .pv_done(pv_group_done),
        .pv_busy(pv_busy),

        .drain_release(drain_release),

        .child_protocol_error(
            bc_protocol_error |
            v_cache_error |
            repack_error
        ),

        .group_complete(group_complete),
        .completed_group_id(completed_group_id),
        .active_group_id(active_group_id),
        .start_while_busy_error(start_while_busy_error),
        .protocol_error(controller_error)
    );

    // The B+C engine still processes one Group at a time.  The Ping-Pong
    // scheduler may launch the next Group while real PV drains the previous
    // Group from the other repack bank.
    // raw Q/K -> RoPE -> rotated Q/K cache -> QK -> Mask -> Softmax
    //          -> B+C TILE2 P/V input stream.
    //
    // The A-owned controller above deliberately uses the one-Group wrapper,
    // rather than rope_qk_softmax_pv_system_top, because it must wait for the
    // real TILE4 PV Context output before advancing to the next Group.
    rope_qk_softmax_pv_pipeline_top #(
        .QK_TILE(QK_TILE),
        .QK_LANES(QK_LANES),
        .CAUSAL_QK_TILE_SKIP(EFFECTIVE_QK_CAUSAL_SKIP),
        .PV_TILE(CAPTURE_TILE),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W),
        .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W),
        .POS_W(POS_W),
        .DIM_W(DIM_W),
        .PAIR_W(PAIR_W),
        .V_ADDR_W(V_ADDR_W),
        .ROM_DEPTH(ROM_DEPTH),
        .SCALE_FP32(SCALE_FP32),
        .EXP_LUT_FILE(EXP_LUT_FILE),
        .SIN_ROM_FILE(SIN_ROM_FILE),
        .COS_ROM_FILE(COS_ROM_FILE)
    ) u_rope_bc_group (
        .clk(clk),
        .rst_n(rst_n),

        .group_start(bc_group_start),
        .group_id(bc_launch_group_id),
        .group_start_ready(bc_group_start_ready),
        .active_group_id(bc_active_group_id),
        .causal_en(causal_en),

        .raw_req_valid(raw_req_valid),
        .raw_req_ready(raw_req_ready),
        .raw_req_is_k(raw_req_is_k),
        .raw_req_head(raw_req_head),
        .raw_req_token(raw_req_token),
        .raw_req_pair(raw_req_pair),
        .raw_rsp_valid(raw_rsp_valid),
        .raw_rsp_ready(raw_rsp_ready),
        .raw_rsp_x0(raw_rsp_x0),
        .raw_rsp_x1(raw_rsp_x1),

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

        .rope_busy(rope_busy),
        .rope_done(unused_rope_done),
        .qk_busy(qk_busy),
        .qk_done(unused_qk_done),
        .qk_tiles_computed(qk_tiles_computed),
        .qk_tiles_skipped(qk_tiles_skipped),
        .masked_tiles_emitted(masked_tiles_emitted),
        .causal_skip_error(qk_causal_skip_error),
        .b_frontend_busy(unused_b_frontend_busy),
        .mask_adapter_busy(mask_busy),
        .softmax_busy(softmax_busy),
        .c_backend_busy(bc_backend_busy),
        .busy(bc_busy),
        .prob_input_done(unused_prob_input_done),
        .done(bc_group_done),

        .protocol_error(bc_protocol_error)
    );

    bf16_v_cache #(
        .NUM_KV_HEADS(GQA_GROUPS),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .LANES(CAPTURE_TILE),
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

    generate
        // Exact v2.5 structural fallback.
        if (CAPTURE_TILE == 2) begin : GEN_V25_CAPTURE_FALLBACK
            pv_tile2_to_tile4_pingpong_adapter #(
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
                .clk(clk), .rst_n(rst_n), .start(buffer_start),
                .fill_start_valid(fill_start_valid),
                .fill_start_ready(fill_start_ready),
                .fill_start_group_id(fill_start_group_id),
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
                .capture_busy(capture_busy),
                .drain_valid(drain_valid),
                .drain_ready(drain_ready),
                .drain_group_id(drain_group_id),
                .drain_release(drain_release),
                .feed_enable(pv_feed_enable),
                .req_head(real_pv_req_head),
                .req_row_base(real_pv_req_row_base),
                .req_col_base(real_pv_req_col_base),
                .req_reduce(real_pv_req_reduce),
                .out_p_vec_bf16(real_p_vec_bf16),
                .out_v_vec_bf16(real_v_vec_bf16),
                .out_valid(real_pv_vec_valid),
                .out_ready(real_pv_vec_ready),
                .bank0_state(repack_bank0_state),
                .bank1_state(repack_bank1_state),
                .drain_active(repack_drain_active),
                .buffer_busy(repack_buffer_busy),
                .protocol_error(repack_error)
            );

            pv_systolic_gqa_top #(
                .TILE(REAL_PV_TILE),
                .QUERY_LEN(SEQ_LEN),
                .REDUCE_LEN(SEQ_LEN),
                .HEAD_DIM(HEAD_DIM),
                .Q_HEADS(Q_HEADS)
            ) u_real_pv (
                .clk(clk), .rst_n(rst_n),
                .start(pv_start), .busy(pv_busy), .done(pv_group_done),
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
            assign native_vectors_captured = 32'd0;
            assign pv_reductions_computed = 32'd0;
            assign pv_reductions_skipped = 32'd0;
            assign pv_zero_probability_violation = 1'b0;
        end else begin : GEN_NATIVE_TILE4_PARALLEL_PV
            pv_tile4_pingpong_buffer #(
                .TILE(REAL_PV_TILE),
                .PV_LANES(PV_LANES),
                .SEQ_LEN(SEQ_LEN),
                .HEAD_DIM(HEAD_DIM),
                .Q_HEADS(Q_HEADS),
                .GQA_GROUPS(GQA_GROUPS),
                .HEAD_W(HEAD_W),
                .GROUP_W(GROUP_W),
                .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W),
                .POS_W(POS_W),
                .DIM_W(DIM_W)
            ) u_native_capture (
                .clk(clk), .rst_n(rst_n), .start(buffer_start),
                .causal_en(causal_en),
                .fill_start_valid(fill_start_valid),
                .fill_start_ready(fill_start_ready),
                .fill_start_group_id(fill_start_group_id),
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
                .capture_busy(capture_busy),
                .native_vectors_captured(native_vectors_captured),
                .drain_valid(drain_valid),
                .drain_ready(drain_ready),
                .drain_group_id(drain_group_id),
                .drain_release(drain_release),
                .feed_enable(pv_feed_enable),
                .req_head(real_pv_req_head),
                .req_row_base(real_pv_req_row_base),
                .req_col_base(real_pv_req_col_base),
                .req_reduce(real_pv_req_reduce),
                .out_p_vec_bf16(real_p_vec_bf16),
                .out_v_vec_bf16(real_v_vec_bf16),
                .out_valid(real_pv_vec_valid),
                .out_ready(real_pv_vec_ready),
                .bank0_state(repack_bank0_state),
                .bank1_state(repack_bank1_state),
                .drain_active(repack_drain_active),
                .buffer_busy(repack_buffer_busy),
                .protocol_error(repack_error)
            );

            pv_parallel_systolic_gqa_top #(
                .TILE(REAL_PV_TILE),
                .PV_LANES(PV_LANES),
                .QUERY_LEN(SEQ_LEN),
                .REDUCE_LEN(SEQ_LEN),
                .HEAD_DIM(HEAD_DIM),
                .Q_HEADS(Q_HEADS),
                .CAUSAL_ROW_EFFECTIVE(CAUSAL_PV_ROW_EFFECTIVE)
            ) u_parallel_pv (
                .clk(clk), .rst_n(rst_n),
                .start(pv_start), .causal_en(causal_en),
                .busy(pv_busy), .done(pv_group_done),
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
                .context_last(pv_context_last),
                .pv_reductions_computed(pv_reductions_computed),
                .pv_reductions_skipped(pv_reductions_skipped),
                .pv_zero_probability_violation(
                    pv_zero_probability_violation
                )
            );
        end
    endgenerate

    assign context_group_id = pv_active_group_id;
    assign context_global_q_head =
        ($unsigned(pv_active_group_id) * Q_HEADS) +
        $unsigned(context_head);
    assign context_group_last = pv_context_last;
    assign context_global_last =
        pv_context_last &&
        ($unsigned(pv_active_group_id) == RUN_GQA_GROUPS-1);

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

    assign repack_input_stall =
        bc_pv_vec_valid && !bc_pv_vec_ready;
    assign pv_feed_stall =
        real_pv_vec_valid && !real_pv_vec_ready;
    assign softmax_output_stall =
        mon_prob_valid && !mon_prob_ready;

    assign protocol_error =
        start_while_busy_error |
        controller_error |
        bc_protocol_error |
        v_cache_error |
        repack_error |
        qk_causal_skip_error |
        pv_zero_probability_violation;

    // Preserve bank state and buffer activity in the synthesized debug cone.
    wire unused_pingpong_status = &{
        1'b0,
        repack_bank0_state,
        repack_bank1_state,
        repack_drain_active,
        repack_buffer_busy,
        bc_active_group_id
    };

endmodule
