`timescale 1ns/1ps

// Common V3 B2 wrapper selected by the mode copied from A's transaction
// latch.  Compatibility and Accuracy arithmetic remain independent, while a
// per-slot mode/token owner routes scores and both cores arbitrate into one
// shared 3x128x32-bit scheme-A stager.
module cats_r4_b2_shared_stager_v3_wrapper #(
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

    output logic [2:0]  slot_owned_state,
    output logic [5:0]  slot_mode_state,
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
    output logic [63:0] mode_error_count,
    output logic [63:0] weight_conflict_cycles,
    output logic [63:0] finalize_conflict_cycles,
    output logic [63:0] output_stall_cycles,
    output logic [63:0] exp_stall_cycles,
    output logic [63:0] sum_stall_cycles,
    output logic [63:0] reciprocal_busy_stall_cycles,
    output logic [63:0] reciprocal_output_stall_cycles,
    output logic        error_sticky
);
    logic [2:0] slot_owned;
    logic [1:0] slot_mode [0:2];
    logic [15:0] slot_epoch [0:2];
    logic [2:0] slot_group [0:2];
    logic [4:0] slot_head [0:2];
    logic [6:0] slot_row [0:2];
    logic [2:0] slot_route_error;
    logic [1:0] row_slot_safe;
    logic [1:0] score_slot_safe;
    logic [1:0] release_slot_safe;
    logic row_shape_legal;
    logic row_selected_ready;
    logic row_fire;
    logic score_slot_owned;
    logic score_owner_mode;
    logic score_fire;
    logic score_metadata_legal;
    logic release_fire;

    logic comp_row_valid;
    logic comp_row_ready;
    logic comp_score_valid;
    logic comp_score_ready;
    logic comp_weight_valid;
    logic comp_weight_ready;
    logic [15:0] comp_weight_epoch;
    logic [2:0] comp_weight_group;
    logic [4:0] comp_weight_head;
    logic [6:0] comp_weight_row;
    logic [1:0] comp_weight_slot;
    logic [1:0] comp_weight_mode;
    logic [6:0] comp_weight_key;
    logic [31:0] comp_weight_data;
    logic comp_weight_last;
    logic comp_done_valid;
    logic comp_done_ready;
    logic [15:0] comp_done_epoch;
    logic [2:0] comp_done_group;
    logic [4:0] comp_done_head;
    logic [6:0] comp_done_row;
    logic [1:0] comp_done_slot;
    logic [1:0] comp_done_mode;
    logic [31:0] comp_done_sum;
    logic [31:0] comp_done_inv_sum;
    logic comp_done_error;
    logic [63:0] comp_rows_issue;
    logic [63:0] comp_rows_result;
    logic [63:0] comp_rows_commit;
    logic [63:0] comp_exp_issue;
    logic [63:0] comp_exp_result;
    logic [63:0] comp_exp_commit;
    logic [63:0] comp_sum_issue;
    logic [63:0] comp_sum_result;
    logic [63:0] comp_sum_commit;
    logic [63:0] comp_reciprocal_issue;
    logic [63:0] comp_reciprocal_result;
    logic [63:0] comp_reciprocal_commit;
    logic [63:0] comp_output_stalls;
    logic [63:0] comp_reciprocal_stalls;
    logic [63:0] comp_protocol_errors;
    logic [63:0] comp_numeric_specials;
    logic comp_error_sticky;

    logic acc_row_valid;
    logic acc_row_ready;
    logic acc_score_valid;
    logic acc_score_ready;
    logic acc_weight_valid;
    logic acc_weight_ready;
    logic [15:0] acc_weight_epoch;
    logic [2:0] acc_weight_group;
    logic [4:0] acc_weight_head;
    logic [6:0] acc_weight_row;
    logic [1:0] acc_weight_slot;
    logic [1:0] acc_weight_mode;
    logic [6:0] acc_weight_key;
    logic [31:0] acc_weight_data;
    logic acc_weight_last;
    logic acc_done_valid;
    logic acc_done_ready;
    logic [15:0] acc_done_epoch;
    logic [2:0] acc_done_group;
    logic [4:0] acc_done_head;
    logic [6:0] acc_done_row;
    logic [1:0] acc_done_slot;
    logic [1:0] acc_done_mode;
    logic [31:0] acc_done_sum;
    logic [31:0] acc_done_inv_sum;
    logic acc_done_error;
    logic [3:0] acc_done_error_code;
    logic [6:0] acc_done_bad_key;
    logic [63:0] acc_rows_issue;
    logic [63:0] acc_rows_result;
    logic [63:0] acc_rows_commit;
    logic [63:0] acc_exp_issue;
    logic [63:0] acc_exp_result;
    logic [63:0] acc_exp_commit;
    logic [63:0] acc_sum_issue;
    logic [63:0] acc_sum_result;
    logic [63:0] acc_sum_commit;
    logic [63:0] acc_reciprocal_issue;
    logic [63:0] acc_reciprocal_result;
    logic [63:0] acc_reciprocal_commit;
    logic [63:0] acc_protocol_errors;
    logic [63:0] acc_numeric_errors;
    logic [63:0] acc_exp_stalls;
    logic [63:0] acc_sum_stalls;
    logic [63:0] acc_reciprocal_busy_stalls;
    logic [63:0] acc_reciprocal_output_stalls;
    logic acc_error_sticky;

    logic stage_begin_valid;
    logic stage_begin_ready;
    logic stage_weight_valid;
    logic stage_weight_ready;
    logic stage_finalize_valid;
    logic stage_finalize_ready;
    logic selected_weight_mode;
    logic selected_finalize_mode;
    logic weight_conflict;
    logic finalize_conflict;
    logic stage_weight_fire;
    logic stage_finalize_fire;
    logic selected_finalize_route_error;
    logic [1:0] selected_weight_slot;
    logic [1:0] selected_finalize_slot;
    logic [1:0] selected_weight_slot_safe;
    logic [1:0] selected_finalize_slot_safe;
    logic [8:0] stager_slot_state;
    logic [63:0] stager_rows_begin;
    logic [63:0] stager_rows_validated;
    logic [63:0] stager_rows_error;
    logic [63:0] stager_protocol_errors;
    logic [63:0] stager_numeric_errors;
    logic [63:0] stager_last_errors;
    logic [63:0] stager_mode_errors;
    logic [63:0] stager_epoch_drops;
    logic [63:0] stager_owner_errors;
    logic stager_error_sticky;
    logic wrapper_error_sticky;
    // clear is a synchronous V3 control.  Register once at the B boundary so
    // it is not a high-fanout data/control path into every arithmetic counter.
    // Upstream must hold clear through a clock edge; the local flush occurs on
    // the following edge and no new public row/score is accepted meanwhile.
    logic clear_local;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            clear_local <= 1'b0;
        else
            clear_local <= clear;
    end

    assign row_slot_safe = row_slot_id < 3 ? row_slot_id : 0;
    assign score_slot_safe = score_slot_id < 3 ? score_slot_id : 0;
    assign release_slot_safe = slot_release_slot_id < 3 ?
                               slot_release_slot_id : 0;
    assign row_shape_legal = row_group == row_global_q_head[4:2] &&
                             row_slot_id < 3 && row_numeric_mode < 2 &&
                             !slot_owned[row_slot_safe];
    assign row_selected_ready = row_numeric_mode == 0 ?
                                comp_row_ready : acc_row_ready;
    // Do not acknowledge a new public transaction while a clear is being
    // sampled.  The registered fanout then flushes all B-owned state on the
    // next edge without admitting a row into the intervening cycle.
    assign row_ready = !clear && row_shape_legal && row_selected_ready &&
                       stage_begin_ready;
    assign row_fire = row_valid && row_ready;
    assign comp_row_valid = row_valid && !clear && row_shape_legal &&
                            row_numeric_mode == 0 && stage_begin_ready;
    assign acc_row_valid = row_valid && !clear && row_shape_legal &&
                           row_numeric_mode == 1 && stage_begin_ready;
    assign stage_begin_valid = row_valid && !clear && row_shape_legal &&
                               row_selected_ready;

    assign score_slot_owned = score_slot_id < 3 &&
                              slot_owned[score_slot_safe];
    assign score_owner_mode = slot_mode[score_slot_safe][0];
    assign score_ready = !clear && score_slot_owned ?
                         (score_owner_mode ? acc_score_ready :
                                             comp_score_ready) : 1'b0;
    assign score_fire = score_valid && score_ready;
    assign score_metadata_legal =
        score_epoch == slot_epoch[score_slot_safe] &&
        score_group == slot_group[score_slot_safe] &&
        score_global_q_head == slot_head[score_slot_safe] &&
        score_row == slot_row[score_slot_safe] &&
        score_numeric_mode == slot_mode[score_slot_safe];
    assign comp_score_valid = score_valid && !clear && score_slot_owned &&
                              !score_owner_mode;
    assign acc_score_valid = score_valid && !clear && score_slot_owned &&
                             score_owner_mode;
    assign release_fire = slot_release_valid && slot_release_ready;

    cats_r4_b2_compatibility_core_adapter #(
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_compatibility (
        .clk, .rst_n, .clear(clear_local), .counter_clear,
        .row_valid(comp_row_valid), .row_ready(comp_row_ready),
        .row_epoch, .row_group, .row_global_q_head, .row_index,
        .row_slot_id, .row_numeric_mode, .row_max_bf16,
        .score_valid(comp_score_valid), .score_ready(comp_score_ready),
        .score_epoch, .score_group, .score_global_q_head, .score_row,
        .score_slot_id, .score_numeric_mode, .score_key, .score_bf16,
        .score_last,
        .weight_valid(comp_weight_valid),
        .weight_ready(comp_weight_ready),
        .weight_epoch(comp_weight_epoch),
        .weight_group(comp_weight_group),
        .weight_global_q_head(comp_weight_head),
        .weight_row(comp_weight_row), .weight_slot_id(comp_weight_slot),
        .weight_numeric_mode(comp_weight_mode),
        .weight_key(comp_weight_key), .weight_data(comp_weight_data),
        .weight_last(comp_weight_last),
        .done_valid(comp_done_valid), .done_ready(comp_done_ready),
        .done_epoch(comp_done_epoch), .done_group(comp_done_group),
        .done_global_q_head(comp_done_head), .done_row(comp_done_row),
        .done_slot_id(comp_done_slot),
        .done_numeric_mode(comp_done_mode), .done_sum_fp32(comp_done_sum),
        .done_inv_sum_fp32(comp_done_inv_sum),
        .done_error(comp_done_error),
        .rows_issue(comp_rows_issue), .rows_result(comp_rows_result),
        .rows_commit(comp_rows_commit), .exp_issue(comp_exp_issue),
        .exp_result(comp_exp_result), .exp_commit(comp_exp_commit),
        .sum_issue(comp_sum_issue), .sum_result(comp_sum_result),
        .sum_commit(comp_sum_commit),
        .reciprocal_issue(comp_reciprocal_issue),
        .reciprocal_result(comp_reciprocal_result),
        .reciprocal_commit(comp_reciprocal_commit),
        .output_stall_cycles(comp_output_stalls),
        .reciprocal_busy_stall_cycles(comp_reciprocal_stalls),
        .protocol_error_count(comp_protocol_errors),
        .numeric_special_count(comp_numeric_specials),
        .error_sticky(comp_error_sticky)
    );

    cats_r4_row_softmax_accuracy u_accuracy (
        .clk, .rst_n, .clear(clear_local), .counter_clear,
        .row_valid(acc_row_valid), .row_ready(acc_row_ready),
        .row_epoch, .row_group, .row_global_q_head, .row_index,
        .row_slot_id, .row_numeric_mode, .row_max_bf16,
        .score_valid(acc_score_valid), .score_ready(acc_score_ready),
        .score_epoch, .score_group, .score_global_q_head, .score_row,
        .score_slot_id, .score_numeric_mode, .score_key, .score_bf16,
        .score_last,
        .weight_valid(acc_weight_valid), .weight_ready(acc_weight_ready),
        .weight_epoch(acc_weight_epoch), .weight_group(acc_weight_group),
        .weight_global_q_head(acc_weight_head),
        .weight_row(acc_weight_row), .weight_slot_id(acc_weight_slot),
        .weight_numeric_mode(acc_weight_mode),
        .weight_key(acc_weight_key), .weight_fp32(acc_weight_data),
        .weight_last(acc_weight_last),
        .done_valid(acc_done_valid), .done_ready(acc_done_ready),
        .done_epoch(acc_done_epoch), .done_group(acc_done_group),
        .done_global_q_head(acc_done_head), .done_row(acc_done_row),
        .done_slot_id(acc_done_slot), .done_numeric_mode(acc_done_mode),
        .done_sum_fp32(acc_done_sum),
        .done_inv_sum_fp32(acc_done_inv_sum),
        .done_error(acc_done_error),
        .done_error_code(acc_done_error_code),
        .done_bad_key(acc_done_bad_key),
        .rows_issue(acc_rows_issue), .rows_result(acc_rows_result),
        .rows_commit(acc_rows_commit), .exp_issue(acc_exp_issue),
        .exp_result(acc_exp_result), .exp_commit(acc_exp_commit),
        .sum_issue(acc_sum_issue), .sum_result(acc_sum_result),
        .sum_commit(acc_sum_commit),
        .reciprocal_issue(acc_reciprocal_issue),
        .reciprocal_result(acc_reciprocal_result),
        .reciprocal_commit(acc_reciprocal_commit),
        .protocol_error_count(acc_protocol_errors),
        .numeric_error_count(acc_numeric_errors),
        .exp_stall_cycles(acc_exp_stalls),
        .sum_stall_cycles(acc_sum_stalls),
        .reciprocal_busy_stall_cycles(acc_reciprocal_busy_stalls),
        .reciprocal_output_stall_cycles(acc_reciprocal_output_stalls),
        .error_sticky(acc_error_sticky)
    );

    cats_r4_b2_locking_arbiter u_weight_arbiter (
        .clk, .rst_n, .clear(clear_local),
        .source0_valid(comp_weight_valid),
        .source0_ready(comp_weight_ready),
        .source1_valid(acc_weight_valid),
        .source1_ready(acc_weight_ready),
        .output_valid(stage_weight_valid),
        .output_ready(stage_weight_ready),
        .selected_source(selected_weight_mode),
        .conflict(weight_conflict)
    );

    cats_r4_b2_locking_arbiter u_finalize_arbiter (
        .clk, .rst_n, .clear(clear_local),
        .source0_valid(comp_done_valid),
        .source0_ready(comp_done_ready),
        .source1_valid(acc_done_valid),
        .source1_ready(acc_done_ready),
        .output_valid(stage_finalize_valid),
        .output_ready(stage_finalize_ready),
        .selected_source(selected_finalize_mode),
        .conflict(finalize_conflict)
    );

    assign selected_weight_slot = selected_weight_mode ? acc_weight_slot :
                                                        comp_weight_slot;
    assign selected_finalize_slot = selected_finalize_mode ? acc_done_slot :
                                                            comp_done_slot;
    assign selected_weight_slot_safe = selected_weight_slot < 3 ?
                                       selected_weight_slot : 0;
    assign selected_finalize_slot_safe = selected_finalize_slot < 3 ?
                                         selected_finalize_slot : 0;
    assign selected_finalize_route_error =
        slot_route_error[selected_finalize_slot_safe] ||
        (score_fire && !score_metadata_legal &&
         score_slot_safe == selected_finalize_slot_safe);
    assign stage_weight_fire = stage_weight_valid && stage_weight_ready;
    assign stage_finalize_fire = stage_finalize_valid &&
                                 stage_finalize_ready;

    cats_r4_b2_weight_stager u_stager (
        .clk, .rst_n, .clear(clear_local), .counter_clear,
        .stage_begin_valid, .stage_begin_ready,
        .stage_begin_epoch(row_epoch), .stage_begin_group(row_group),
        .stage_begin_global_q_head(row_global_q_head),
        .stage_begin_row(row_index), .stage_begin_slot_id(row_slot_id),
        .stage_begin_numeric_mode(row_numeric_mode),
        .stage_weight_valid, .stage_weight_ready,
        .stage_weight_epoch(selected_weight_mode ? acc_weight_epoch :
                                                   comp_weight_epoch),
        .stage_weight_group(selected_weight_mode ? acc_weight_group :
                                                   comp_weight_group),
        .stage_weight_global_q_head(selected_weight_mode ? acc_weight_head :
                                                           comp_weight_head),
        .stage_weight_row(selected_weight_mode ? acc_weight_row :
                                                 comp_weight_row),
        .stage_weight_slot_id(selected_weight_slot),
        .stage_weight_numeric_mode(selected_weight_mode ? acc_weight_mode :
                                                          comp_weight_mode),
        .stage_weight_key(selected_weight_mode ? acc_weight_key :
                                                 comp_weight_key),
        .stage_weight_data(selected_weight_mode ? acc_weight_data :
                                                  comp_weight_data),
        .stage_weight_last(selected_weight_mode ? acc_weight_last :
                                                  comp_weight_last),
        .stage_finalize_valid, .stage_finalize_ready,
        .stage_finalize_epoch(selected_finalize_mode ? acc_done_epoch :
                                                       comp_done_epoch),
        .stage_finalize_group(selected_finalize_mode ? acc_done_group :
                                                       comp_done_group),
        .stage_finalize_global_q_head(selected_finalize_mode ?
            acc_done_head : comp_done_head),
        .stage_finalize_row(selected_finalize_mode ? acc_done_row :
                                                     comp_done_row),
        .stage_finalize_slot_id(selected_finalize_slot),
        .stage_finalize_numeric_mode(selected_finalize_mode ?
            acc_done_mode : comp_done_mode),
        .stage_finalize_sum_fp32(selected_finalize_mode ? acc_done_sum :
                                                          comp_done_sum),
        .stage_finalize_inv_sum_fp32(selected_finalize_mode ?
            acc_done_inv_sum : comp_done_inv_sum),
        .stage_finalize_numeric_error(
            (selected_finalize_mode ? acc_done_error : comp_done_error) ||
            selected_finalize_route_error),
        .weight_wr_valid, .weight_wr_ready, .weight_wr_epoch,
        .weight_wr_group, .weight_wr_global_q_head, .weight_wr_row,
        .weight_wr_slot_id, .weight_wr_numeric_mode, .weight_wr_key,
        .weight_wr_mask, .weight_wr_data, .weight_wr_last,
        .row_commit_valid, .row_commit_ready, .row_commit_epoch,
        .row_commit_group, .row_commit_global_q_head, .row_commit_row,
        .row_commit_slot_id, .row_commit_numeric_mode,
        .row_commit_sum_fp32, .row_commit_inv_sum_fp32,
        .row_error_valid, .row_error_ready, .row_error_epoch,
        .row_error_group, .row_error_global_q_head, .row_error_row,
        .row_error_slot_id, .row_error_numeric_mode, .row_error_code,
        .row_error_bad_key,
        .slot_release_valid, .slot_release_ready, .slot_release_epoch,
        .slot_release_group, .slot_release_global_q_head,
        .slot_release_row, .slot_release_slot_id,
        .slot_release_numeric_mode,
        .slot_state(stager_slot_state), .rows_begin(stager_rows_begin),
        .stage_weight_accept(staged_weight_accept),
        .rows_validated(stager_rows_validated),
        .rows_error(stager_rows_error), .weight_wr_accept,
        .row_commit_count, .slot_release_count, .output_stall_cycles,
        .protocol_error_count(stager_protocol_errors),
        .numeric_error_count(stager_numeric_errors),
        .last_error_count(stager_last_errors),
        .mode_error_count(stager_mode_errors),
        .epoch_drop_count(stager_epoch_drops),
        .owner_error_count(stager_owner_errors), .mask_error_count,
        .error_sticky(stager_error_sticky)
    );

    assign slot_owned_state = slot_owned;
    assign slot_mode_state = {slot_mode[2], slot_mode[1], slot_mode[0]};
    assign rows_issue = comp_rows_issue + acc_rows_issue;
    assign rows_result = comp_rows_result + acc_rows_result;
    assign exp_issue = comp_exp_issue + acc_exp_issue;
    assign exp_result = comp_exp_result + acc_exp_result;
    assign exp_commit = comp_exp_commit + acc_exp_commit;
    assign sum_issue = comp_sum_issue + acc_sum_issue;
    assign sum_result = comp_sum_result + acc_sum_result;
    assign sum_commit = comp_sum_commit + acc_sum_commit;
    assign reciprocal_issue = comp_reciprocal_issue + acc_reciprocal_issue;
    assign reciprocal_result = comp_reciprocal_result +
                               acc_reciprocal_result;
    assign reciprocal_commit = comp_reciprocal_commit +
                               acc_reciprocal_commit;
    assign protocol_error_count = comp_protocol_errors +
                                  acc_protocol_errors +
                                  stager_protocol_errors + mode_error_count;
    assign numeric_error_count = acc_numeric_errors +
                                 stager_numeric_errors;
    assign owner_error_count = stager_owner_errors;
    assign exp_stall_cycles = comp_output_stalls + acc_exp_stalls;
    assign sum_stall_cycles = acc_sum_stalls;
    assign reciprocal_busy_stall_cycles = comp_reciprocal_stalls +
                                          acc_reciprocal_busy_stalls;
    assign reciprocal_output_stall_cycles =
        acc_reciprocal_output_stalls;
    assign error_sticky = comp_error_sticky || acc_error_sticky ||
                          stager_error_sticky || wrapper_error_sticky;

    always_ff @(posedge clk or negedge rst_n) begin : p_owner_and_arbiter
        integer slot;
        if (!rst_n) begin
            slot_owned <= 0;
            slot_route_error <= 0;
            mode_error_count <= 0;
            weight_conflict_cycles <= 0;
            finalize_conflict_cycles <= 0;
            wrapper_error_sticky <= 0;
            for (slot = 0; slot < 3; slot = slot+1) begin
                slot_mode[slot] <= 0;
                slot_epoch[slot] <= 0;
                slot_group[slot] <= 0;
                slot_head[slot] <= 0;
                slot_row[slot] <= 0;
            end
        end else if (clear_local) begin
            slot_owned <= 0;
            slot_route_error <= 0;
            wrapper_error_sticky <= 0;
        end else begin
            if (row_fire) begin
                slot_owned[row_slot_safe] <= 1;
                slot_mode[row_slot_safe] <= row_numeric_mode;
                slot_epoch[row_slot_safe] <= row_epoch;
                slot_group[row_slot_safe] <= row_group;
                slot_head[row_slot_safe] <= row_global_q_head;
                slot_row[row_slot_safe] <= row_index;
                slot_route_error[row_slot_safe] <= 0;
            end
            if (score_fire && !score_metadata_legal) begin
                slot_route_error[score_slot_safe] <= 1;
                wrapper_error_sticky <= 1;
            end
            if (release_fire) begin
                slot_owned[release_slot_safe] <= 0;
                slot_route_error[release_slot_safe] <= 0;
            end

            if (counter_clear) begin
                mode_error_count <= 0;
                weight_conflict_cycles <= 0;
                finalize_conflict_cycles <= 0;
                wrapper_error_sticky <= 0;
            end else begin
                if (score_fire && !score_metadata_legal)
                    mode_error_count <= mode_error_count + 1'b1;
                if (weight_conflict)
                    weight_conflict_cycles <= weight_conflict_cycles + 1'b1;
                if (finalize_conflict)
                    finalize_conflict_cycles <=
                        finalize_conflict_cycles + 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    logic [50:0] stalled_row_payload;
    logic [58:0] stalled_score_payload;
    logic row_was_stalled;
    logic score_was_stalled;
    wire [50:0] row_payload = {row_epoch, row_group,
        row_global_q_head, row_index, row_slot_id,
        row_numeric_mode, row_max_bf16};
    wire [58:0] score_payload = {score_epoch, score_group,
        score_global_q_head, score_row, score_slot_id,
        score_numeric_mode, score_key, score_bf16, score_last};
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            row_was_stalled <= 0;
            score_was_stalled <= 0;
        end else begin
            if (row_was_stalled &&
                (!row_valid || row_payload != stalled_row_payload))
                $fatal(1, "shared wrapper row payload changed while stalled");
            if (score_was_stalled &&
                (!score_valid || score_payload != stalled_score_payload))
                $fatal(1, "shared wrapper score payload changed while stalled");
            row_was_stalled <= row_valid && !row_ready;
            score_was_stalled <= score_valid && !score_ready;
            if (row_valid && !row_ready)
                stalled_row_payload <= row_payload;
            if (score_valid && !score_ready)
                stalled_score_payload <= score_payload;
            if (counter_clear && slot_owned != 0)
                $fatal(1, "counter_clear requires a quiescent shared wrapper");
            if (stage_weight_fire &&
                (!slot_owned[selected_weight_slot_safe] ||
                 slot_mode[selected_weight_slot_safe][0] !=
                 selected_weight_mode))
                $fatal(1, "shared stager weight owner/mode mismatch");
            if (stage_finalize_fire &&
                (!slot_owned[selected_finalize_slot_safe] ||
                 slot_mode[selected_finalize_slot_safe][0] !=
                 selected_finalize_mode))
                $fatal(1, "shared stager finalize owner/mode mismatch");
        end
    end
`endif

    logic unused_status;
    assign unused_status = |{comp_rows_commit, acc_rows_commit,
        comp_numeric_specials, acc_done_error_code, acc_done_bad_key,
        stager_slot_state, stager_rows_begin, stager_rows_validated,
        stager_rows_error, stager_last_errors, stager_mode_errors,
        stager_epoch_drops};
endmodule
