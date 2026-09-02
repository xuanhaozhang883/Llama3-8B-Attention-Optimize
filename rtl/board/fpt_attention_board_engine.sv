`timescale 1ns/1ps

// Correctness-first board engine for one to eight real Llama GQA groups.
// Flow:
//   PS DDR V preload -> full Attention core -> Context writes to PS DDR.
// Raw Q/K vectors are fetched from PS DDR one token-vector line at a time.
module fpt_attention_board_engine #(
    parameter int RUN_GROUPS = 1,
    parameter int QK_LANES = 4,
    parameter bit CAUSAL_MODE = 1'b0,
    parameter int V_LANES = 8,
    parameter int CAPTURE_TILE = 4,
    parameter int PV_LANES = 2,
    parameter logic [31:0] Q_BASE_ADDR       = 32'h1000_0000,
    parameter logic [31:0] K_BASE_ADDR       = 32'h1010_0000,
    parameter logic [31:0] V_BASE_ADDR       = 32'h1014_0000,
    parameter logic [31:0] CONTEXT_BASE_ADDR = 32'h1018_0000,
    parameter EXP_LUT_FILE = "exp_lut_q15.mem",
    parameter SIN_ROM_FILE = "sin_bf16.hex",
    parameter COS_ROM_FILE = "cos_bf16.hex"
) (
    input  logic clk,
    input  logic rst_n,
    input  logic command_start,
    input  logic causal_en,

    output logic busy,
    output logic done_latched,
    output logic error_latched,
    output logic [31:0] cycle_count,
    output logic [2:0] active_group_id,
    output logic v_loaded,
    output logic core_done_seen,
    output logic context_done_seen,

    // v2.3 hardware profiling counters. All counters are reset by a new
    // command_start and remain stable after done_latched. Stage counters may
    // overlap by design; they are observations, not an exclusive partition.
    output logic [31:0] prof_v_load_cycles,
    output logic [31:0] prof_core_run_cycles,
    output logic [31:0] prof_raw_wait_cycles,
    output logic [31:0] prof_raw_busy_cycles,
    output logic [31:0] prof_bc_busy_cycles,
    output logic [31:0] prof_pv_busy_cycles,
    output logic [31:0] prof_context_busy_cycles,
    output logic [31:0] prof_context_backpressure_cycles,
    output logic [31:0] prof_ddr_read_busy_cycles,
    output logic [31:0] prof_ddr_write_busy_cycles,
    output logic [31:0] prof_raw_req_count,
    output logic [31:0] prof_read_beat_count,
    output logic [31:0] prof_write_beat_count,
    output logic [31:0] prof_context_word_count,
    output logic [31:0] prof_read_command_count,
    output logic [31:0] prof_write_command_count,
    output logic [31:0] prof_error_detail,
    output logic [255:0] prof_group_cycles_flat,
    output logic [31:0] prof_rope_busy_cycles,
    output logic [31:0] prof_qk_busy_cycles,
    output logic [31:0] prof_mask_busy_cycles,
    output logic [31:0] prof_softmax_busy_cycles,
    output logic [31:0] prof_bc_backend_busy_cycles,
    output logic [31:0] prof_capture_busy_cycles,
    output logic [31:0] prof_context_transfer_cycles,
    output logic [31:0] prof_bc_pv_overlap_cycles,
    output logic [31:0] prof_core_idle_cycles,
    output logic [31:0] prof_repack_stall_cycles,
    output logic [31:0] prof_pv_feed_stall_cycles,
    output logic [31:0] prof_softmax_stall_cycles,
    output logic [31:0] prof_interstage_wait_cycles,
    output logic [31:0] prof_qk_tiles_computed,
    output logic [31:0] prof_qk_tiles_skipped,
    output logic [31:0] prof_masked_tiles_emitted,
    output logic [31:0] prof_pv_reductions_computed,
    output logic [31:0] prof_pv_reductions_skipped,
    output logic [31:0] prof_native_vectors_captured,
    output logic [31:0] prof_causal_error_flags,

    output logic rd_start,
    input  logic rd_ready,
    output logic [31:0] rd_addr,
    output logic [31:0] rd_len,
    input  logic rd_data_we,
    input  logic [63:0] rd_data,
    output logic rd_fifo_full,
    input  logic rd_done,
    input  logic rd_error,

    output logic wr_start,
    input  logic wr_ready,
    output logic [31:0] wr_addr,
    output logic [31:0] wr_len,
    input  logic wr_fifo_re,
    output logic wr_fifo_empty,
    output logic wr_fifo_aempty,
    output logic [63:0] wr_fifo_data,
    input  logic wr_done,
    input  logic wr_error
);
    localparam int SEQ_LEN = 128;
    localparam int HEAD_DIM = 128;
    localparam int Q_HEADS = 4;
    localparam int GQA_GROUPS = 8;
    localparam int GLOBAL_HEAD_W = 5;
    localparam int POS_W = 7;
    localparam int PAIR_W = 6;
    localparam int V_ADDR_W = 17;

    typedef enum logic [2:0] {
        S_IDLE,
        S_LOAD_V,
        S_LAUNCH_CORE,
        S_RUN_CORE,
        S_COMPLETE,
        S_FAILED
    } state_t;
    state_t state;

    logic v_start, v_busy, v_done, v_error;
    logic v_rd_start, v_rd_full;
    logic [31:0] v_rd_addr, v_rd_len;
    logic v_load_valid, v_load_ready;
    logic [V_ADDR_W-1:0] v_load_addr;
    logic [V_LANES*16-1:0] v_load_data;

    logic raw_req_valid, raw_req_ready, raw_req_is_k;
    logic [GLOBAL_HEAD_W-1:0] raw_req_head;
    logic [POS_W-1:0] raw_req_token;
    logic [PAIR_W-1:0] raw_req_pair;
    logic raw_rsp_valid, raw_rsp_ready;
    logic [15:0] raw_rsp_x0, raw_rsp_x1;
    logic raw_rd_start, raw_rd_full, raw_busy, raw_error;
    logic [31:0] raw_rd_addr, raw_rd_len;

    logic core_start, core_start_ready, core_busy, core_done;
    logic context_valid, context_ready;
    logic [15:0] context_bf16;
    logic [31:0] context_fp32_debug;
    logic [2:0] context_group_id;
    logic [1:0] context_head;
    logic [GLOBAL_HEAD_W-1:0] context_global_q_head;
    logic [POS_W-1:0] context_row;
    logic [6:0] context_col;
    logic context_group_last, context_global_last;

    logic ctx_start, ctx_busy, ctx_done, ctx_error;
    logic [31:0] ctx_words_accepted;

    logic core_start_while_busy_error;
    logic core_controller_error;
    logic core_bc_protocol_error;
    logic core_v_cache_error;
    logic core_repack_error;
    logic core_protocol_error;

    logic group_complete;
    logic [2:0] completed_group_id;
    logic core_bc_group_done, core_capture_complete, core_pv_group_done;
    logic core_bc_busy, core_pv_busy;
    logic core_rope_busy, core_qk_busy, core_mask_busy;
    logic core_softmax_busy, core_bc_backend_busy, core_capture_busy;
    logic core_repack_input_stall, core_pv_feed_stall;
    logic core_softmax_output_stall;
    logic [31:0] core_qk_tiles_computed;
    logic [31:0] core_qk_tiles_skipped;
    logic [31:0] core_masked_tiles_emitted;
    logic core_qk_causal_skip_error;
    logic [31:0] core_pv_reductions_computed;
    logic [31:0] core_pv_reductions_skipped;
    logic core_pv_zero_probability_violation;
    logic [31:0] core_native_vectors_captured;
    logic core_any_stage_busy;
    logic core_consumer_busy;
    logic [31:0] flash_score_tiles_enqueued;
    logic [31:0] flash_score_tiles_dequeued;
    logic [31:0] flash_softmax_tiles_processed;
    logic [31:0] flash_context_tiles_processed;
    logic [31:0] flash_v_vectors_read;
    logic [31:0] flash_causal_tiles_bypassed;
    logic flash_causal_bypass_error;

    logic read_owner_v;
    logic [31:0] prof_group_cycle_accum;

    assign busy = (state != S_IDLE) && (state != S_COMPLETE) && (state != S_FAILED);
    assign read_owner_v = (state == S_LOAD_V);
    assign core_any_stage_busy =
        raw_busy |
        core_rope_busy |
        core_qk_busy |
        core_mask_busy |
        core_softmax_busy |
        core_bc_backend_busy |
        core_capture_busy |
        core_pv_busy |
        ctx_busy;
    assign prof_qk_tiles_computed = core_qk_tiles_computed;
    assign prof_qk_tiles_skipped = core_qk_tiles_skipped;
    assign prof_masked_tiles_emitted = core_masked_tiles_emitted;
    assign prof_pv_reductions_computed = core_pv_reductions_computed;
    assign prof_pv_reductions_skipped = core_pv_reductions_skipped;
    assign prof_native_vectors_captured = core_native_vectors_captured;
    assign prof_causal_error_flags = {
        29'd0,
        flash_causal_bypass_error,
        core_pv_zero_probability_violation,
        core_qk_causal_skip_error
    };
    // Preserve the existing profiling ABI while the old probability replay/PV
    // stages are removed.  These aliases expose the closest FlashAttention
    // work counters in the legacy pages.
    assign core_bc_group_done = group_complete;
    assign core_capture_complete = group_complete;
    assign core_pv_group_done = group_complete;
    assign core_bc_busy = core_busy;
    assign core_pv_busy = 1'b0;
    assign core_mask_busy = 1'b0;
    assign core_softmax_busy = core_consumer_busy;
    assign core_bc_backend_busy = core_consumer_busy;
    assign core_capture_busy = 1'b0;
    assign core_repack_input_stall = 1'b0;
    assign core_pv_feed_stall = 1'b0;
    assign core_softmax_output_stall = 1'b0;
    assign core_qk_causal_skip_error = 1'b0;
    assign core_pv_reductions_computed = flash_context_tiles_processed;
    assign core_pv_reductions_skipped = flash_causal_tiles_bypassed;
    assign core_pv_zero_probability_violation = 1'b0;
    assign core_native_vectors_captured = flash_v_vectors_read;
    assign core_controller_error = 1'b0;
    assign core_bc_protocol_error = 1'b0;
    assign core_v_cache_error = 1'b0;
    assign core_repack_error = 1'b0;

    // The vendor AXI master has one read channel. V preload owns it first;
    // raw Q/K line fills own it after the core is launched.
    assign rd_start     = read_owner_v ? v_rd_start : raw_rd_start;
    assign rd_addr      = read_owner_v ? v_rd_addr  : raw_rd_addr;
    assign rd_len       = read_owner_v ? v_rd_len   : raw_rd_len;
    assign rd_fifo_full = read_owner_v ? v_rd_full  : raw_rd_full;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state              <= S_IDLE;
            v_start            <= 1'b0;
            core_start         <= 1'b0;
            ctx_start          <= 1'b0;
            done_latched       <= 1'b0;
            error_latched      <= 1'b0;
            cycle_count        <= '0;
            v_loaded           <= 1'b0;
            core_done_seen     <= 1'b0;
            context_done_seen  <= 1'b0;
            prof_v_load_cycles <= '0;
            prof_core_run_cycles <= '0;
            prof_raw_wait_cycles <= '0;
            prof_raw_busy_cycles <= '0;
            prof_bc_busy_cycles <= '0;
            prof_pv_busy_cycles <= '0;
            prof_context_busy_cycles <= '0;
            prof_context_backpressure_cycles <= '0;
            prof_ddr_read_busy_cycles <= '0;
            prof_ddr_write_busy_cycles <= '0;
            prof_raw_req_count <= '0;
            prof_read_beat_count <= '0;
            prof_write_beat_count <= '0;
            prof_context_word_count <= '0;
            prof_read_command_count <= '0;
            prof_write_command_count <= '0;
            prof_error_detail <= '0;
            prof_group_cycles_flat <= '0;
            prof_group_cycle_accum <= '0;
            prof_rope_busy_cycles <= '0;
            prof_qk_busy_cycles <= '0;
            prof_mask_busy_cycles <= '0;
            prof_softmax_busy_cycles <= '0;
            prof_bc_backend_busy_cycles <= '0;
            prof_capture_busy_cycles <= '0;
            prof_context_transfer_cycles <= '0;
            prof_bc_pv_overlap_cycles <= '0;
            prof_core_idle_cycles <= '0;
            prof_repack_stall_cycles <= '0;
            prof_pv_feed_stall_cycles <= '0;
            prof_softmax_stall_cycles <= '0;
            prof_interstage_wait_cycles <= '0;
        end else begin
            v_start    <= 1'b0;
            core_start <= 1'b0;
            ctx_start  <= 1'b0;

            if (busy) begin
                cycle_count <= cycle_count + 1'b1;
                if (!rd_ready) prof_ddr_read_busy_cycles <= prof_ddr_read_busy_cycles + 1'b1;
                if (!wr_ready) prof_ddr_write_busy_cycles <= prof_ddr_write_busy_cycles + 1'b1;
            end

            if (state == S_LOAD_V)
                prof_v_load_cycles <= prof_v_load_cycles + 1'b1;

            if (state == S_RUN_CORE) begin
                prof_core_run_cycles <= prof_core_run_cycles + 1'b1;
                prof_group_cycle_accum <= prof_group_cycle_accum + 1'b1;
                if (raw_req_valid && !raw_req_ready)
                    prof_raw_wait_cycles <= prof_raw_wait_cycles + 1'b1;
                if (raw_busy)
                    prof_raw_busy_cycles <= prof_raw_busy_cycles + 1'b1;
                if (core_bc_busy)
                    prof_bc_busy_cycles <= prof_bc_busy_cycles + 1'b1;
                if (core_pv_busy)
                    prof_pv_busy_cycles <= prof_pv_busy_cycles + 1'b1;
                if (ctx_busy)
                    prof_context_busy_cycles <= prof_context_busy_cycles + 1'b1;
                if (context_valid && !context_ready)
                    prof_context_backpressure_cycles <= prof_context_backpressure_cycles + 1'b1;
                if (core_rope_busy)
                    prof_rope_busy_cycles <= prof_rope_busy_cycles + 1'b1;
                if (core_qk_busy)
                    prof_qk_busy_cycles <= prof_qk_busy_cycles + 1'b1;
                if (core_mask_busy)
                    prof_mask_busy_cycles <= prof_mask_busy_cycles + 1'b1;
                if (core_softmax_busy)
                    prof_softmax_busy_cycles <= prof_softmax_busy_cycles + 1'b1;
                if (core_bc_backend_busy)
                    prof_bc_backend_busy_cycles <= prof_bc_backend_busy_cycles + 1'b1;
                if (core_capture_busy)
                    prof_capture_busy_cycles <= prof_capture_busy_cycles + 1'b1;
                if (context_valid && context_ready)
                    prof_context_transfer_cycles <= prof_context_transfer_cycles + 1'b1;
                if (core_bc_busy && core_pv_busy)
                    prof_bc_pv_overlap_cycles <= prof_bc_pv_overlap_cycles + 1'b1;
                if (!core_any_stage_busy)
                    prof_core_idle_cycles <= prof_core_idle_cycles + 1'b1;
                if (core_repack_input_stall)
                    prof_repack_stall_cycles <= prof_repack_stall_cycles + 1'b1;
                if (core_pv_feed_stall)
                    prof_pv_feed_stall_cycles <= prof_pv_feed_stall_cycles + 1'b1;
                if (core_softmax_output_stall)
                    prof_softmax_stall_cycles <= prof_softmax_stall_cycles + 1'b1;
                if (core_busy && !core_bc_busy && !core_pv_busy)
                    prof_interstage_wait_cycles <= prof_interstage_wait_cycles + 1'b1;

                if (group_complete) begin
                    case (completed_group_id)
                        3'd0: prof_group_cycles_flat[31:0]    <= prof_group_cycle_accum + 1'b1;
                        3'd1: prof_group_cycles_flat[63:32]   <= prof_group_cycle_accum + 1'b1;
                        3'd2: prof_group_cycles_flat[95:64]   <= prof_group_cycle_accum + 1'b1;
                        3'd3: prof_group_cycles_flat[127:96]  <= prof_group_cycle_accum + 1'b1;
                        3'd4: prof_group_cycles_flat[159:128] <= prof_group_cycle_accum + 1'b1;
                        3'd5: prof_group_cycles_flat[191:160] <= prof_group_cycle_accum + 1'b1;
                        3'd6: prof_group_cycles_flat[223:192] <= prof_group_cycle_accum + 1'b1;
                        3'd7: prof_group_cycles_flat[255:224] <= prof_group_cycle_accum + 1'b1;
                        default: ;
                    endcase
                    prof_group_cycle_accum <= '0;
                end
            end

            if (raw_req_valid && raw_req_ready)
                prof_raw_req_count <= prof_raw_req_count + 1'b1;
            if (rd_data_we)
                prof_read_beat_count <= prof_read_beat_count + 1'b1;
            if (wr_fifo_re)
                prof_write_beat_count <= prof_write_beat_count + 1'b1;
            if (context_valid && context_ready)
                prof_context_word_count <= prof_context_word_count + 1'b1;
            if (rd_start)
                prof_read_command_count <= prof_read_command_count + 1'b1;
            if (wr_start)
                prof_write_command_count <= prof_write_command_count + 1'b1;

            if (v_error) prof_error_detail[0] <= 1'b1;
            if (raw_error) prof_error_detail[1] <= 1'b1;
            if (ctx_error) prof_error_detail[2] <= 1'b1;
            if (rd_error) prof_error_detail[3] <= 1'b1;
            if (wr_error) prof_error_detail[4] <= 1'b1;
            if (core_start_while_busy_error) prof_error_detail[5] <= 1'b1;
            if (core_controller_error) prof_error_detail[6] <= 1'b1;
            if (core_bc_protocol_error) prof_error_detail[7] <= 1'b1;
            if (core_v_cache_error) prof_error_detail[8] <= 1'b1;
            if (core_repack_error) prof_error_detail[9] <= 1'b1;
            if (core_protocol_error) prof_error_detail[10] <= 1'b1;
            if (core_qk_causal_skip_error)
                prof_error_detail[11] <= 1'b1;
            if (core_pv_zero_probability_violation)
                prof_error_detail[12] <= 1'b1;

            if (v_error || raw_error || ctx_error || rd_error || wr_error ||
                core_protocol_error)
                error_latched <= 1'b1;

            if (core_done)
                core_done_seen <= 1'b1;
            if (ctx_done)
                context_done_seen <= 1'b1;

            case (state)
                S_IDLE: begin
                    if (command_start) begin
                        done_latched      <= 1'b0;
                        error_latched     <= 1'b0;
                        cycle_count       <= '0;
                        v_loaded          <= 1'b0;
                        core_done_seen    <= 1'b0;
                        context_done_seen <= 1'b0;
                        prof_v_load_cycles <= '0;
                        prof_core_run_cycles <= '0;
                        prof_raw_wait_cycles <= '0;
                        prof_raw_busy_cycles <= '0;
                        prof_bc_busy_cycles <= '0;
                        prof_pv_busy_cycles <= '0;
                        prof_context_busy_cycles <= '0;
                        prof_context_backpressure_cycles <= '0;
                        prof_ddr_read_busy_cycles <= '0;
                        prof_ddr_write_busy_cycles <= '0;
                        prof_raw_req_count <= '0;
                        prof_read_beat_count <= '0;
                        prof_write_beat_count <= '0;
                        prof_context_word_count <= '0;
                        prof_read_command_count <= '0;
                        prof_write_command_count <= '0;
                        prof_error_detail <= '0;
                        prof_group_cycles_flat <= '0;
                        prof_group_cycle_accum <= '0;
                        prof_rope_busy_cycles <= '0;
                        prof_qk_busy_cycles <= '0;
                        prof_mask_busy_cycles <= '0;
                        prof_softmax_busy_cycles <= '0;
                        prof_bc_backend_busy_cycles <= '0;
                        prof_capture_busy_cycles <= '0;
                        prof_context_transfer_cycles <= '0;
                        prof_bc_pv_overlap_cycles <= '0;
                        prof_core_idle_cycles <= '0;
                        prof_repack_stall_cycles <= '0;
                        prof_pv_feed_stall_cycles <= '0;
                        prof_softmax_stall_cycles <= '0;
                        prof_interstage_wait_cycles <= '0;
                        v_start           <= 1'b1;
                        state             <= S_LOAD_V;
                    end
                end

                S_LOAD_V: begin
                    if (v_done) begin
                        v_loaded <= 1'b1;
                        if (v_error || rd_error)
                            state <= S_FAILED;
                        else
                            state <= S_LAUNCH_CORE;
                    end
                end

                S_LAUNCH_CORE: begin
                    if (core_start_ready) begin
                        core_start <= 1'b1;
                        ctx_start  <= 1'b1;
                        state      <= S_RUN_CORE;
                    end
                end

                S_RUN_CORE: begin
                    if ((core_done_seen || core_done) &&
                        (context_done_seen || ctx_done)) begin
                        if (error_latched || core_protocol_error || ctx_error)
                            state <= S_FAILED;
                        else
                            state <= S_COMPLETE;
                    end
                end

                S_COMPLETE: begin
                    done_latched <= 1'b1;
                    if (command_start) begin
                        done_latched <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                S_FAILED: begin
                    done_latched  <= 1'b1;
                    error_latched <= 1'b1;
                    if (command_start) begin
                        done_latched <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_FAILED;
            endcase
        end
    end

    fpt_v_ddr_loader #(
        .RUN_GROUPS(RUN_GROUPS), .SEQ_LEN(SEQ_LEN),
        .HEAD_DIM(HEAD_DIM), .V_ADDR_W(V_ADDR_W),
        .LOAD_LANES(V_LANES)
    ) u_v_loader (
        .clk, .rst_n, .start(v_start), .v_base_addr(V_BASE_ADDR),
        .busy(v_busy), .done(v_done), .error(v_error),
        .rd_start(v_rd_start), .rd_ready(read_owner_v && rd_ready),
        .rd_addr(v_rd_addr), .rd_len(v_rd_len),
        .rd_data_we(read_owner_v && rd_data_we), .rd_data,
        .rd_fifo_full(v_rd_full), .rd_done(read_owner_v && rd_done),
        .rd_error(read_owner_v && rd_error),
        .v_load_valid, .v_load_ready, .v_load_addr, .v_load_data
    );

    fpt_raw_qk_ddr_reader #(
        .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM),
        .GLOBAL_HEAD_W(GLOBAL_HEAD_W), .POS_W(POS_W), .PAIR_W(PAIR_W)
    ) u_raw_reader (
        .clk, .rst_n, .enable(state == S_RUN_CORE),
        .q_base_addr(Q_BASE_ADDR), .k_base_addr(K_BASE_ADDR),
        .raw_req_valid, .raw_req_ready, .raw_req_is_k,
        .raw_req_head, .raw_req_token, .raw_req_pair,
        .raw_rsp_valid, .raw_rsp_ready, .raw_rsp_x0, .raw_rsp_x1,
        .rd_start(raw_rd_start), .rd_ready(!read_owner_v && rd_ready),
        .rd_addr(raw_rd_addr), .rd_len(raw_rd_len),
        .rd_data_we(!read_owner_v && rd_data_we), .rd_data,
        .rd_fifo_full(raw_rd_full), .rd_done(!read_owner_v && rd_done),
        .rd_error(!read_owner_v && rd_error),
        .busy(raw_busy), .error(raw_error)
    );

    fpt_context_ddr_writer #(
        .RUN_GROUPS(RUN_GROUPS), .Q_HEADS(Q_HEADS),
        .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM)
    ) u_context_writer (
        .clk, .rst_n, .start(ctx_start),
        .context_base_addr(CONTEXT_BASE_ADDR),
        .context_valid, .context_ready, .context_bf16,
        .context_group_id, .context_head, .context_global_q_head,
        .context_row, .context_col, .context_global_last,
        .wr_start, .wr_ready, .wr_addr, .wr_len,
        .wr_fifo_re, .wr_fifo_empty, .wr_fifo_aempty, .wr_fifo_data,
        .wr_done, .wr_error,
        .busy(ctx_busy), .done(ctx_done), .error(ctx_error),
        .words_accepted(ctx_words_accepted)
    );

    flash_attention_system_with_rope_top #(
        .QK_LANES(QK_LANES),
        .CAUSAL_MODE(CAUSAL_MODE),
        .V_LANES(V_LANES),
        .SEQ_LEN(SEQ_LEN), .HEAD_DIM(HEAD_DIM), .Q_HEADS(Q_HEADS),
        .GQA_GROUPS(GQA_GROUPS), .RUN_GQA_GROUPS(RUN_GROUPS),
        .EXP_LUT_FILE(EXP_LUT_FILE),
        .SIN_ROM_FILE(SIN_ROM_FILE), .COS_ROM_FILE(COS_ROM_FILE)
    ) u_attention_core (
        .clk, .rst_n,
        .start(core_start), .start_ready(core_start_ready),
        .busy(core_busy), .done(core_done), .causal_en,
        .raw_req_valid, .raw_req_ready, .raw_req_is_k,
        .raw_req_head, .raw_req_token, .raw_req_pair,
        .raw_rsp_valid, .raw_rsp_ready, .raw_rsp_x0, .raw_rsp_x1,
        .v_load_valid, .v_load_ready, .v_load_addr, .v_load_data,
        .context_valid, .context_ready, .context_bf16,
        .context_fp32_debug, .context_group(context_group_id), .context_head,
        .context_global_head(context_global_q_head),
        .context_row, .context_col,
        .context_group_last, .context_global_last,
        .req_head(), .req_group_id(), .req_global_q_head(), .req_kv_head(),
        .req_row_base(), .req_col_base(), .req_dim(),
        .group_complete, .completed_group_id,
        .active_group_id,
        .rope_busy(core_rope_busy), .qk_busy(core_qk_busy),
        .consumer_busy(core_consumer_busy),
        .qk_tiles_computed(core_qk_tiles_computed),
        .qk_tiles_skipped(core_qk_tiles_skipped),
        .masked_tiles_emitted(core_masked_tiles_emitted),
        .score_tiles_enqueued(flash_score_tiles_enqueued),
        .score_tiles_dequeued(flash_score_tiles_dequeued),
        .softmax_tiles_processed(flash_softmax_tiles_processed),
        .context_tiles_processed(flash_context_tiles_processed),
        .v_vectors_read(flash_v_vectors_read),
        .causal_tiles_bypassed(flash_causal_tiles_bypassed),
        .causal_bypass_error(flash_causal_bypass_error),
        .start_while_busy_error(core_start_while_busy_error),
        .protocol_error(core_protocol_error)
    );

    // Keep useful status signals visible to synthesis/debug without changing
    // the verified core interfaces.
    wire unused_status = &{1'b0, v_busy, raw_busy, core_busy, ctx_busy,
                           context_fp32_debug, context_group_last,
                           group_complete, completed_group_id,
                           core_bc_group_done, core_capture_complete,
                           core_pv_group_done, core_bc_busy, core_pv_busy,
                           core_start_while_busy_error,
                           core_controller_error, core_bc_protocol_error,
                           core_v_cache_error, core_repack_error,
                           ctx_words_accepted};
endmodule
