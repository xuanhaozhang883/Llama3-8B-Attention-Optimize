`timescale 1ns/1ps

// RoPE-aware Attention top with inter-Group B+C/PV overlap.
//
// The numerical datapath is unchanged.  Two verified complete-Group
// TILE2-to-TILE4 adapters decouple the B+C producer from the real PV consumer.
module attention_system_with_rope_pv_overlap_top #(
    parameter int QK_TILE       = 4,
    parameter int BC_PV_TILE    = 2,
    parameter int REAL_PV_TILE  = 4,
    parameter int SEQ_LEN       = 128,
    parameter int HEAD_DIM      = 128,
    parameter int Q_HEADS       = 4,
    parameter int GQA_GROUPS    = 8,
    parameter bit ALLOW_REDUCED_GQA = 1'b0,
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
    input  logic [BC_PV_TILE*16-1:0] v_load_data,

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

    output logic mon_bc_pv_valid,
    output logic mon_bc_pv_ready,
    output logic [31:0] mon_bc_p_vec_bf16,
    output logic [31:0] mon_bc_v_vec_bf16,
    output logic [GROUP_W-1:0] mon_bc_pv_group_id,
    output logic [HEAD_W-1:0] mon_bc_pv_head,
    output logic [POS_W-1:0] mon_bc_pv_row_base,
    output logic [DIM_W-1:0] mon_bc_pv_feature_base,
    output logic [POS_W-1:0] mon_bc_pv_reduce_index,

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
    output logic protocol_error,

    output logic [63:0] perf_total_cycles,
    output logic [63:0] perf_bc_cycles,
    output logic [63:0] perf_pv_cycles,
    output logic [63:0] perf_overlap_cycles,
    output logic [63:0] perf_bank_full_wait_cycles,
    output logic [63:0] perf_bank_empty_wait_cycles,
    output logic [31:0] perf_context_count,
    output logic [31:0] perf_duplicate_count,
    output logic [31:0] perf_missing_count,
    output logic [31:0] perf_error_bitmap
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

    logic scheduler_busy;
    logic bc_group_start;
    logic bc_group_start_ready;
    logic [GROUP_W-1:0] bc_launch_group_id;
    logic fill_start;
    logic fill_bank;
    logic [GROUP_W-1:0] fill_group_id;
    logic fill_ready;
    logic fill_done;
    logic fill_done_bank;
    logic [GROUP_W-1:0] fill_done_group_id;
    logic pv_start;
    logic [GROUP_W-1:0] pv_launch_group_id;
    logic drain_start;
    logic drain_bank;
    logic [GROUP_W-1:0] drain_group_id;
    logic drain_ready;
    logic release_valid;
    logic release_bank;
    logic [GROUP_W-1:0] release_group_id;
    logic bc_active;
    logic pv_active;
    logic [GROUP_W-1:0] bc_active_group_id;
    logic [GROUP_W-1:0] pv_active_group_id;
    logic bc_wait_for_empty_bank;
    logic pv_wait_for_ready_bank;

    logic [1:0] bank0_state;
    logic [1:0] bank1_state;
    logic [GROUP_W-1:0] bank0_group_id;
    logic [GROUP_W-1:0] bank1_group_id;
    logic [31:0] invalid_fill_count;
    logic [31:0] invalid_drain_count;
    logic [31:0] bank_conflict_count;

    logic [GROUP_W-1:0] rope_bc_active_group_id;
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
    logic unused_rope_busy;
    logic unused_rope_done;

    assign busy = scheduler_busy || bc_busy || pv_busy;
    assign active_group_id =
        pv_active ? pv_active_group_id : bc_active_group_id;
    assign capture_complete =
        (bank0_state == 2'd2) || (bank0_state == 2'd3) ||
        (bank1_state == 2'd2) || (bank1_state == 2'd3);

    initial begin
        if ((RUN_GQA_GROUPS < 1) ||
            (RUN_GQA_GROUPS > GQA_GROUPS))
            $error("attention_system_with_rope_pv_overlap_top: RUN_GQA_GROUPS must be in [1,GQA_GROUPS]");
    end

    gqa_overlap_scheduler #(
        .NUM_GROUPS(RUN_GQA_GROUPS),
        .GROUP_W(GROUP_W)
    ) u_scheduler (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .start_ready(start_ready),
        .busy(scheduler_busy),
        .done(done),
        .bc_group_start(bc_group_start),
        .bc_group_id(bc_launch_group_id),
        .bc_group_start_ready(bc_group_start_ready),
        .bc_group_done(bc_group_done),
        .fill_start(fill_start),
        .fill_bank(fill_bank),
        .fill_group_id(fill_group_id),
        .fill_ready(fill_ready),
        .fill_done(fill_done),
        .fill_done_bank(fill_done_bank),
        .fill_done_group_id(fill_done_group_id),
        .pv_start(pv_start),
        .pv_group_id(pv_launch_group_id),
        .pv_start_ready(!pv_busy),
        .pv_done(pv_group_done),
        .drain_start(drain_start),
        .drain_bank(drain_bank),
        .drain_group_id(drain_group_id),
        .drain_ready(drain_ready),
        .release_valid(release_valid),
        .release_bank(release_bank),
        .release_group_id(release_group_id),
        .bank0_state(bank0_state),
        .bank1_state(bank1_state),
        .bank0_group_id(bank0_group_id),
        .bank1_group_id(bank1_group_id),
        .child_protocol_error(
            bc_protocol_error |
            v_cache_error |
            repack_error
        ),
        .bc_active(bc_active),
        .pv_active(pv_active),
        .bc_active_group_id(bc_active_group_id),
        .pv_active_group_id(pv_active_group_id),
        .bc_wait_for_empty_bank(bc_wait_for_empty_bank),
        .pv_wait_for_ready_bank(pv_wait_for_ready_bank),
        .group_complete(group_complete),
        .completed_group_id(completed_group_id),
        .start_while_busy_error(start_while_busy_error),
        .protocol_error(controller_error)
    );

    rope_qk_softmax_pv_pipeline_top #(
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
        .active_group_id(rope_bc_active_group_id),
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
        .rope_busy(unused_rope_busy),
        .rope_done(unused_rope_done),
        .qk_busy(),
        .qk_done(unused_qk_done),
        .b_frontend_busy(unused_b_frontend_busy),
        .c_backend_busy(unused_c_backend_busy),
        .busy(bc_busy),
        .prob_input_done(unused_prob_input_done),
        .done(bc_group_done),
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

    gqa_pingpong_buffer #(
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS),
        .HEAD_W(HEAD_W),
        .GROUP_W(GROUP_W),
        .GLOBAL_Q_HEAD_W(GLOBAL_Q_HEAD_W),
        .POS_W(POS_W),
        .DIM_W(DIM_W)
    ) u_pingpong (
        .clk(clk),
        .rst_n(rst_n),
        .fill_start(fill_start),
        .fill_bank(fill_bank),
        .fill_group_id(fill_group_id),
        .fill_ready(fill_ready),
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
        .fill_done(fill_done),
        .fill_done_bank(fill_done_bank),
        .fill_done_group_id(fill_done_group_id),
        .drain_start(drain_start),
        .drain_bank(drain_bank),
        .drain_group_id(drain_group_id),
        .drain_ready(drain_ready),
        .release_valid(release_valid),
        .release_bank(release_bank),
        .release_group_id(release_group_id),
        .req_head(real_pv_req_head),
        .req_row_base(real_pv_req_row_base),
        .req_col_base(real_pv_req_col_base),
        .req_reduce(real_pv_req_reduce),
        .out_p_vec_bf16(real_p_vec_bf16),
        .out_v_vec_bf16(real_v_vec_bf16),
        .out_valid(real_pv_vec_valid),
        .out_ready(real_pv_vec_ready),
        .bank0_state(bank0_state),
        .bank1_state(bank1_state),
        .bank0_group_id(bank0_group_id),
        .bank1_group_id(bank1_group_id),
        .protocol_error(repack_error),
        .invalid_fill_count(invalid_fill_count),
        .invalid_drain_count(invalid_drain_count),
        .bank_conflict_count(bank_conflict_count)
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

    assign context_group_id = pv_active_group_id;
    assign context_global_q_head =
        ($unsigned(pv_active_group_id) * Q_HEADS) +
        $unsigned(context_head);
    assign context_group_last = pv_context_last;
    assign context_global_last =
        pv_context_last &&
        ($unsigned(pv_active_group_id) == RUN_GQA_GROUPS-1);

    attention_overlap_perf_counters #(
        .NUM_GROUPS(RUN_GQA_GROUPS),
        .Q_HEADS(Q_HEADS),
        .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM),
        .GROUP_W(GROUP_W),
        .HEAD_W(HEAD_W),
        .POS_W(POS_W),
        .DIM_W(DIM_W)
    ) u_perf (
        .clk(clk),
        .rst_n(rst_n),
        .command_start(start && start_ready),
        .command_busy(scheduler_busy),
        .command_done(done),
        .bc_busy(bc_busy),
        .pv_busy(pv_busy),
        .bc_wait_for_empty_bank(bc_wait_for_empty_bank),
        .pv_wait_for_ready_bank(pv_wait_for_ready_bank),
        .context_valid(context_valid),
        .context_ready(context_ready),
        .context_group_id(context_group_id),
        .context_head(context_head),
        .context_row(context_row),
        .context_col(context_col),
        .child_protocol_error(
            controller_error |
            bc_protocol_error |
            v_cache_error |
            repack_error
        ),
        .total_cycles(perf_total_cycles),
        .bc_cycles(perf_bc_cycles),
        .pv_cycles(perf_pv_cycles),
        .overlap_cycles(perf_overlap_cycles),
        .bank_full_wait_cycles(perf_bank_full_wait_cycles),
        .bank_empty_wait_cycles(perf_bank_empty_wait_cycles),
        .context_count(perf_context_count),
        .duplicate_count(perf_duplicate_count),
        .missing_count(perf_missing_count),
        .error_bitmap(perf_error_bitmap)
    );

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
        repack_error |
        (invalid_fill_count != 0) |
        (invalid_drain_count != 0) |
        (bank_conflict_count != 0);

endmodule
