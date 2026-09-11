`timescale 1ns/1ps

// Compatibility-mode A->B adapter plus scheme-A whole-row staging.
//
// This checkpoint consumes the actual A row/score token shape and emits the
// frozen V3 B->C weight_wr/row_commit shape.  It is intentionally
// Compatibility-only: transaction-level integration must select this wrapper
// only for numeric_mode=0.  Accuracy mode has a separate arithmetic gate and
// remains NOT READY.
module cats_r4_b2_compatibility_v3_wrapper #(
    parameter EXP_LUT_FILE = "mem/exp_lut_q15.mem"
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear,
    input  logic        counter_clear,

    input  logic        row_valid,
    output logic        row_ready,
    input  logic [15:0] row_epoch,
    input  logic [2:0]  row_group,
    input  logic [4:0]  row_global_q_head,
    input  logic [6:0]  row_index,
    input  logic [1:0]  row_slot_id,
    input  logic [1:0]  row_numeric_mode,
    input  logic [15:0] row_max_bf16,

    input  logic        score_valid,
    output logic        score_ready,
    input  logic [15:0] score_epoch,
    input  logic [2:0]  score_group,
    input  logic [4:0]  score_global_q_head,
    input  logic [6:0]  score_row,
    input  logic [1:0]  score_slot_id,
    input  logic [1:0]  score_numeric_mode,
    input  logic [6:0]  score_key,
    input  logic [15:0] score_bf16,
    input  logic        score_last,

    output logic        weight_wr_valid,
    input  logic        weight_wr_ready,
    output logic [15:0] weight_wr_epoch,
    output logic [2:0]  weight_wr_group,
    output logic [4:0]  weight_wr_global_q_head,
    output logic [6:0]  weight_wr_row,
    output logic [1:0]  weight_wr_slot_id,
    output logic [1:0]  weight_wr_numeric_mode,
    output logic [6:0]  weight_wr_key,
    output logic        weight_wr_mask,
    output logic [31:0] weight_wr_data,
    output logic        weight_wr_last,

    output logic        row_commit_valid,
    input  logic        row_commit_ready,
    output logic [15:0] row_commit_epoch,
    output logic [2:0]  row_commit_group,
    output logic [4:0]  row_commit_global_q_head,
    output logic [6:0]  row_commit_row,
    output logic [1:0]  row_commit_slot_id,
    output logic [1:0]  row_commit_numeric_mode,
    output logic [31:0] row_commit_sum_fp32,
    output logic [31:0] row_commit_inv_sum_fp32,

    output logic        row_error_valid,
    input  logic        row_error_ready,
    output logic [15:0] row_error_epoch,
    output logic [2:0]  row_error_group,
    output logic [4:0]  row_error_global_q_head,
    output logic [6:0]  row_error_row,
    output logic [1:0]  row_error_slot_id,
    output logic [1:0]  row_error_numeric_mode,
    output logic [3:0]  row_error_code,
    output logic [6:0]  row_error_bad_key,

    input  logic        slot_release_valid,
    output logic        slot_release_ready,
    input  logic [15:0] slot_release_epoch,
    input  logic [2:0]  slot_release_group,
    input  logic [4:0]  slot_release_global_q_head,
    input  logic [6:0]  slot_release_row,
    input  logic [1:0]  slot_release_slot_id,
    input  logic [1:0]  slot_release_numeric_mode,

    output logic [63:0] rows_issue,
    output logic [63:0] rows_result,
    output logic [63:0] exp_issue,
    output logic [63:0] exp_result,
    output logic [63:0] exp_commit,
    output logic [63:0] sum_issue,
    output logic [63:0] sum_result,
    output logic [63:0] sum_commit,
    output logic [63:0] reciprocal_issue,
    output logic [63:0] reciprocal_result,
    output logic [63:0] reciprocal_commit,
    output logic [63:0] staged_weight_accept,
    output logic [63:0] weight_wr_accept,
    output logic [63:0] row_commit_count,
    output logic [63:0] slot_release_count,
    output logic [63:0] protocol_error_count,
    output logic [63:0] numeric_error_count,
    output logic [63:0] owner_error_count,
    output logic [63:0] mask_error_count,
    output logic [63:0] output_stall_cycles,
    output logic        error_sticky
);
    logic compatibility_row_valid;
    logic compatibility_row_ready;
    logic compatibility_score_valid;
    logic compatibility_score_ready;
    logic row_token_legal;
    logic score_shape_legal;

    logic core_weight_valid;
    logic core_weight_ready;
    logic [15:0] core_weight_epoch;
    logic [3:0] core_weight_context_tag;
    logic [4:0] core_weight_head;
    logic [6:0] core_weight_row;
    logic [6:0] core_weight_key;
    logic [15:0] core_weight_bf16;
    logic core_weight_last;
    logic core_done_valid;
    logic core_done_ready;
    logic [15:0] core_done_epoch;
    logic [3:0] core_done_context_tag;
    logic [4:0] core_done_head;
    logic [6:0] core_done_row;
    logic [22:0] core_done_sum_q15;
    logic [30:0] core_done_reciprocal_q30;
    logic [31:0] core_done_reciprocal_fp32;
    logic core_done_error;
    logic [63:0] core_rows_commit;
    logic [63:0] core_weight_issue;
    logic [63:0] core_weight_result;
    logic [63:0] core_weight_commit;
    logic [63:0] compatibility_stall_cycles;
    logic [63:0] reciprocal_stall_cycles;
    logic [63:0] compatibility_protocol_errors;
    logic [63:0] compatibility_specials;
    logic compatibility_error_sticky;

    logic stage_begin_valid;
    logic stage_begin_ready;
    logic stage_weight_valid;
    logic stage_weight_ready;
    logic stage_finalize_valid;
    logic stage_finalize_ready;
    logic [8:0] stager_slot_state;
    logic [63:0] stager_rows_begin;
    logic [63:0] stager_rows_validated;
    logic [63:0] stager_rows_error;
    logic [63:0] stager_protocol_errors;
    logic [63:0] stager_last_errors;
    logic [63:0] stager_mode_errors;
    logic [63:0] stager_epoch_drops;
    logic stager_error_sticky;

    function automatic logic [31:0] q15_sum_to_fp32(
        input logic [22:0] sum_q15
    );
        integer msb_index;
        integer bit_index;
        logic [46:0] normalized;
        logic [7:0] exponent;
        begin
            if (sum_q15 == 0) begin
                q15_sum_to_fp32 = 32'd0;
            end else begin
                msb_index = 0;
                for (bit_index = 0; bit_index < 23;
                     bit_index = bit_index + 1)
                    if (sum_q15[bit_index])
                        msb_index = bit_index;
                exponent = msb_index + 112;
                normalized = {24'd0,sum_q15} << (23-msb_index);
                q15_sum_to_fp32 = {1'b0,exponent,normalized[22:0]};
            end
        end
    endfunction

    assign row_token_legal = row_group == row_global_q_head[4:2] &&
                             row_slot_id < 3 &&
                             row_numeric_mode == 0;
    assign score_shape_legal = score_group == score_global_q_head[4:2] &&
                               score_slot_id < 3 &&
                               score_numeric_mode == 0;

    // The row descriptor reserves the arithmetic context and staging slot in
    // one transfer.  Unsupported mode is backpressured by this explicitly
    // Compatibility-only checkpoint and must be rejected at transaction start
    // by the later common wrapper.
    assign row_ready = row_token_legal &&
                       compatibility_row_ready && stage_begin_ready;
    assign compatibility_row_valid = row_valid && row_token_legal &&
                                     stage_begin_ready;
    assign stage_begin_valid = row_valid && row_token_legal &&
                               compatibility_row_ready;

    assign score_ready = score_shape_legal && compatibility_score_ready;
    assign compatibility_score_valid = score_valid && score_shape_legal;

    cats_r4_row_softmax_compatibility #(
        .CONTEXTS(16),
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_compatibility (
        .clk,
        .rst_n,
        .clear,
        .row_valid(compatibility_row_valid),
        .row_ready(compatibility_row_ready),
        .row_epoch,
        .row_context_tag({2'd0,row_slot_id}),
        .row_global_q_head,
        .row_index,
        .row_key_count({1'b0,row_index} + 1'b1),
        .row_max_bf16,
        .score_valid(compatibility_score_valid),
        .score_ready(compatibility_score_ready),
        .score_epoch,
        .score_context_tag({2'd0,score_slot_id}),
        .score_global_q_head,
        .score_row,
        .score_key,
        .score_bf16,
        .score_mask(1'b0),
        .score_last,
        .weight_valid(core_weight_valid),
        .weight_ready(core_weight_ready),
        .weight_epoch(core_weight_epoch),
        .weight_context_tag(core_weight_context_tag),
        .weight_global_q_head(core_weight_head),
        .weight_row(core_weight_row),
        .weight_key(core_weight_key),
        .weight_bf16(core_weight_bf16),
        .weight_last(core_weight_last),
        .done_valid(core_done_valid),
        .done_ready(core_done_ready),
        .done_epoch(core_done_epoch),
        .done_context_tag(core_done_context_tag),
        .done_global_q_head(core_done_head),
        .done_row(core_done_row),
        .done_sum_q15(core_done_sum_q15),
        .done_reciprocal_q30(core_done_reciprocal_q30),
        .done_reciprocal_fp32(core_done_reciprocal_fp32),
        .done_error(core_done_error),
        .rows_issue,
        .rows_result,
        .rows_commit(core_rows_commit),
        .exp_issue,
        .exp_result,
        .exp_commit,
        .weight_issue(core_weight_issue),
        .weight_result(core_weight_result),
        .weight_commit(core_weight_commit),
        .sum_issue,
        .sum_result,
        .sum_commit,
        .reciprocal_issue,
        .reciprocal_result,
        .reciprocal_commit,
        .output_stall_cycles(compatibility_stall_cycles),
        .reciprocal_busy_stall_cycles(reciprocal_stall_cycles),
        .protocol_error_count(compatibility_protocol_errors),
        .numeric_special_count(compatibility_specials),
        .protocol_error_sticky(compatibility_error_sticky)
    );

    assign stage_weight_valid = core_weight_valid;
    assign core_weight_ready = stage_weight_ready;
    assign stage_finalize_valid = core_done_valid;
    assign core_done_ready = stage_finalize_ready;

    cats_r4_b2_weight_stager u_stager (
        .clk,
        .rst_n,
        .clear,
        .counter_clear,
        .stage_begin_valid,
        .stage_begin_ready,
        .stage_begin_epoch(row_epoch),
        .stage_begin_group(row_group),
        .stage_begin_global_q_head(row_global_q_head),
        .stage_begin_row(row_index),
        .stage_begin_slot_id(row_slot_id),
        .stage_begin_numeric_mode(row_numeric_mode),
        .stage_weight_valid,
        .stage_weight_ready,
        .stage_weight_epoch(core_weight_epoch),
        .stage_weight_group(core_weight_head[4:2]),
        .stage_weight_global_q_head(core_weight_head),
        .stage_weight_row(core_weight_row),
        .stage_weight_slot_id(core_weight_context_tag[1:0]),
        .stage_weight_numeric_mode(2'd0),
        .stage_weight_key(core_weight_key),
        .stage_weight_data({16'd0,core_weight_bf16}),
        .stage_weight_last(core_weight_last),
        .stage_finalize_valid,
        .stage_finalize_ready,
        .stage_finalize_epoch(core_done_epoch),
        .stage_finalize_group(core_done_head[4:2]),
        .stage_finalize_global_q_head(core_done_head),
        .stage_finalize_row(core_done_row),
        .stage_finalize_slot_id(core_done_context_tag[1:0]),
        .stage_finalize_numeric_mode(2'd0),
        .stage_finalize_sum_fp32(q15_sum_to_fp32(core_done_sum_q15)),
        .stage_finalize_inv_sum_fp32(core_done_reciprocal_fp32),
        .stage_finalize_numeric_error(core_done_error),
        .weight_wr_valid,
        .weight_wr_ready,
        .weight_wr_epoch,
        .weight_wr_group,
        .weight_wr_global_q_head,
        .weight_wr_row,
        .weight_wr_slot_id,
        .weight_wr_numeric_mode,
        .weight_wr_key,
        .weight_wr_mask,
        .weight_wr_data,
        .weight_wr_last,
        .row_commit_valid,
        .row_commit_ready,
        .row_commit_epoch,
        .row_commit_group,
        .row_commit_global_q_head,
        .row_commit_row,
        .row_commit_slot_id,
        .row_commit_numeric_mode,
        .row_commit_sum_fp32,
        .row_commit_inv_sum_fp32,
        .row_error_valid,
        .row_error_ready,
        .row_error_epoch,
        .row_error_group,
        .row_error_global_q_head,
        .row_error_row,
        .row_error_slot_id,
        .row_error_numeric_mode,
        .row_error_code,
        .row_error_bad_key,
        .slot_release_valid,
        .slot_release_ready,
        .slot_release_epoch,
        .slot_release_group,
        .slot_release_global_q_head,
        .slot_release_row,
        .slot_release_slot_id,
        .slot_release_numeric_mode,
        .slot_state(stager_slot_state),
        .rows_begin(stager_rows_begin),
        .stage_weight_accept(staged_weight_accept),
        .rows_validated(stager_rows_validated),
        .rows_error(stager_rows_error),
        .weight_wr_accept,
        .row_commit_count,
        .slot_release_count,
        .output_stall_cycles,
        .protocol_error_count(stager_protocol_errors),
        .numeric_error_count,
        .last_error_count(stager_last_errors),
        .mode_error_count(stager_mode_errors),
        .epoch_drop_count(stager_epoch_drops),
        .owner_error_count,
        .mask_error_count,
        .error_sticky(stager_error_sticky)
    );

    assign protocol_error_count = compatibility_protocol_errors +
                                  stager_protocol_errors;
    assign error_sticky = compatibility_error_sticky ||
                          stager_error_sticky;

    logic unused_status;
    assign unused_status = |{core_rows_commit,core_weight_issue,
                             core_weight_result,core_weight_commit,
                             compatibility_stall_cycles,
                             reciprocal_stall_cycles,
                             compatibility_specials,stager_slot_state,
                             stager_rows_begin,stager_rows_validated,
                             stager_rows_error,stager_last_errors,
                             stager_mode_errors,stager_epoch_drops,
                             core_done_reciprocal_q30};

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && !clear) begin
            if (row_valid && row_ready && row_numeric_mode != 0)
                $fatal(1, "Compatibility wrapper accepted nonzero mode");
            if (score_valid && score_ready && score_numeric_mode != 0)
                $fatal(1, "Compatibility wrapper accepted nonzero score mode");
        end
    end
`endif
endmodule
