`timescale 1ns/1ps

// Accuracy-mode V3 A->B adapter plus scheme-A whole-row staging.
// This B-owned checkpoint accepts numeric_mode=1 only.  A later common
// transaction-start wrapper will select Compatibility versus Accuracy once per
// transaction; no input identity or row property selects the mode here.
module cats_r4_b2_accuracy_v3_wrapper (
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
    output logic [63:0] exp_stall_cycles,
    output logic [63:0] sum_stall_cycles,
    output logic [63:0] reciprocal_busy_stall_cycles,
    output logic [63:0] reciprocal_output_stall_cycles,
    output logic        error_sticky
);
    logic row_token_legal;
    logic core_row_valid;
    logic core_row_ready;
    logic core_score_ready;
    logic core_weight_valid;
    logic core_weight_ready;
    logic [15:0] core_weight_epoch;
    logic [2:0] core_weight_group;
    logic [4:0] core_weight_head;
    logic [6:0] core_weight_row;
    logic [1:0] core_weight_slot;
    logic [1:0] core_weight_mode;
    logic [6:0] core_weight_key;
    logic [31:0] core_weight_data;
    logic core_weight_last;
    logic core_done_valid;
    logic core_done_ready;
    logic [15:0] core_done_epoch;
    logic [2:0] core_done_group;
    logic [4:0] core_done_head;
    logic [6:0] core_done_row;
    logic [1:0] core_done_slot;
    logic [1:0] core_done_mode;
    logic [31:0] core_done_sum;
    logic [31:0] core_done_inv_sum;
    logic core_done_error;
    logic [3:0] core_done_error_code;
    logic [6:0] core_done_bad_key;
    logic [63:0] core_rows_commit;
    logic [63:0] core_protocol_errors;
    logic [63:0] core_numeric_errors;
    logic core_error_sticky;

    logic stage_begin_valid;
    logic stage_begin_ready;
    logic stage_weight_ready;
    logic stage_finalize_ready;
    logic [8:0] stager_slot_state;
    logic [63:0] stager_rows_begin;
    logic [63:0] stager_rows_validated;
    logic [63:0] stager_rows_error;
    logic [63:0] stager_protocol_errors;
    logic [63:0] stager_numeric_errors;
    logic [63:0] stager_last_errors;
    logic [63:0] stager_mode_errors;
    logic [63:0] stager_epoch_drops;
    logic stager_error_sticky;

    assign row_token_legal = row_group == row_global_q_head[4:2] &&
                             row_slot_id < 3 &&
                             row_numeric_mode == 2'd1;
    assign row_ready = row_token_legal && core_row_ready && stage_begin_ready;
    assign core_row_valid = row_valid && row_token_legal && stage_begin_ready;
    assign stage_begin_valid = row_valid && row_token_legal && core_row_ready;
    assign score_ready = core_score_ready;

    cats_r4_row_softmax_accuracy u_accuracy (
        .clk,
        .rst_n,
        .clear,
        .counter_clear,
        .row_valid(core_row_valid),
        .row_ready(core_row_ready),
        .row_epoch,
        .row_group,
        .row_global_q_head,
        .row_index,
        .row_slot_id,
        .row_numeric_mode,
        .row_max_bf16,
        .score_valid,
        .score_ready(core_score_ready),
        .score_epoch,
        .score_group,
        .score_global_q_head,
        .score_row,
        .score_slot_id,
        .score_numeric_mode,
        .score_key,
        .score_bf16,
        .score_last,
        .weight_valid(core_weight_valid),
        .weight_ready(core_weight_ready),
        .weight_epoch(core_weight_epoch),
        .weight_group(core_weight_group),
        .weight_global_q_head(core_weight_head),
        .weight_row(core_weight_row),
        .weight_slot_id(core_weight_slot),
        .weight_numeric_mode(core_weight_mode),
        .weight_key(core_weight_key),
        .weight_fp32(core_weight_data),
        .weight_last(core_weight_last),
        .done_valid(core_done_valid),
        .done_ready(core_done_ready),
        .done_epoch(core_done_epoch),
        .done_group(core_done_group),
        .done_global_q_head(core_done_head),
        .done_row(core_done_row),
        .done_slot_id(core_done_slot),
        .done_numeric_mode(core_done_mode),
        .done_sum_fp32(core_done_sum),
        .done_inv_sum_fp32(core_done_inv_sum),
        .done_error(core_done_error),
        .done_error_code(core_done_error_code),
        .done_bad_key(core_done_bad_key),
        .rows_issue,
        .rows_result,
        .rows_commit(core_rows_commit),
        .exp_issue,
        .exp_result,
        .exp_commit,
        .sum_issue,
        .sum_result,
        .sum_commit,
        .reciprocal_issue,
        .reciprocal_result,
        .reciprocal_commit,
        .protocol_error_count(core_protocol_errors),
        .numeric_error_count(core_numeric_errors),
        .exp_stall_cycles,
        .sum_stall_cycles,
        .reciprocal_busy_stall_cycles,
        .reciprocal_output_stall_cycles,
        .error_sticky(core_error_sticky)
    );

    assign core_weight_ready = stage_weight_ready;
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
        .stage_weight_valid(core_weight_valid),
        .stage_weight_ready(stage_weight_ready),
        .stage_weight_epoch(core_weight_epoch),
        .stage_weight_group(core_weight_group),
        .stage_weight_global_q_head(core_weight_head),
        .stage_weight_row(core_weight_row),
        .stage_weight_slot_id(core_weight_slot),
        .stage_weight_numeric_mode(core_weight_mode),
        .stage_weight_key(core_weight_key),
        .stage_weight_data(core_weight_data),
        .stage_weight_last(core_weight_last),
        .stage_finalize_valid(core_done_valid),
        .stage_finalize_ready(stage_finalize_ready),
        .stage_finalize_epoch(core_done_epoch),
        .stage_finalize_group(core_done_group),
        .stage_finalize_global_q_head(core_done_head),
        .stage_finalize_row(core_done_row),
        .stage_finalize_slot_id(core_done_slot),
        .stage_finalize_numeric_mode(core_done_mode),
        .stage_finalize_sum_fp32(core_done_sum),
        .stage_finalize_inv_sum_fp32(core_done_inv_sum),
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
        .numeric_error_count(stager_numeric_errors),
        .last_error_count(stager_last_errors),
        .mode_error_count(stager_mode_errors),
        .epoch_drop_count(stager_epoch_drops),
        .owner_error_count,
        .mask_error_count,
        .error_sticky(stager_error_sticky)
    );

    assign protocol_error_count = core_protocol_errors +
                                  stager_protocol_errors;
    assign numeric_error_count = core_numeric_errors +
                                 stager_numeric_errors;
    assign error_sticky = core_error_sticky || stager_error_sticky;

    logic unused_core_status;
    assign unused_core_status = |{core_rows_commit,core_done_error_code,
                                  core_done_bad_key,stager_slot_state,
                                  stager_rows_begin,stager_rows_validated,
                                  stager_rows_error,stager_last_errors,
                                  stager_mode_errors,stager_epoch_drops};

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && !clear) begin
            if (row_valid && row_ready && row_numeric_mode != 2'd1)
                $fatal(1, "Accuracy wrapper accepted non-Accuracy row");
            if (weight_wr_valid && weight_wr_ready &&
                weight_wr_numeric_mode != 2'd1)
                $fatal(1, "Accuracy wrapper published non-Accuracy weight");
            if (row_commit_valid && row_commit_ready &&
                row_commit_numeric_mode != 2'd1)
                $fatal(1, "Accuracy wrapper committed non-Accuracy row");
        end
    end
`endif
endmodule
