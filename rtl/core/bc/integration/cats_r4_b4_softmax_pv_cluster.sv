`timescale 1ns/1ps

// CATS-R4 member-B cluster datapath wrapper.
//
// This wrapper composes the B2 whole-row Softmax and B3 32-lane PV blocks
// without absorbing C-owned storage or V service logic.  All B<->C signals
// retain the frozen V3 shape.  A normal B3 release is first captured, then
// delivered independently to C and the B2 stager; the A score-slot release
// is published only after both owners have accepted it.  Error rows skip the
// C release because scheme-A guarantees that they wrote no weight data.
//
// The public cluster shell and board top intentionally do not instantiate
// this unit yet.  A/C must connect the exposed channels in their integration
// owner scope.
module cats_r4_b4_softmax_pv_cluster #(
    parameter EXP_LUT_FILE = "mem/exp_lut_q15.mem"
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         clear,
    input  logic         counter_clear,

    // Frozen A -> B whole-row channels.
    input  logic         row_valid,
    output logic         row_ready,
    input  logic [15:0]  row_epoch,
    input  logic [2:0]   row_group,
    input  logic [4:0]   row_global_q_head,
    input  logic [6:0]   row_index,
    input  logic [1:0]   row_slot_id,
    input  logic [1:0]   row_numeric_mode,
    input  logic [15:0]  row_max_bf16,
    input  logic         score_valid,
    output logic         score_ready,
    input  logic [15:0]  score_epoch,
    input  logic [2:0]   score_group,
    input  logic [4:0]   score_global_q_head,
    input  logic [6:0]   score_row,
    input  logic [1:0]   score_slot_id,
    input  logic [1:0]   score_numeric_mode,
    input  logic [6:0]   score_key,
    input  logic [15:0]  score_bf16,
    input  logic         score_last,

    // Frozen B2 -> C weight slab and row seal.
    output logic         weight_wr_valid,
    input  logic         weight_wr_ready,
    output logic [15:0]  weight_wr_epoch,
    output logic [2:0]   weight_wr_group,
    output logic [4:0]   weight_wr_global_q_head,
    output logic [6:0]   weight_wr_row,
    output logic [1:0]   weight_wr_slot_id,
    output logic [1:0]   weight_wr_numeric_mode,
    output logic [6:0]   weight_wr_key,
    output logic         weight_wr_mask,
    output logic [31:0]  weight_wr_data,
    output logic         weight_wr_last,
    output logic         row_commit_valid,
    input  logic         row_commit_ready,
    output logic [15:0]  row_commit_epoch,
    output logic [2:0]   row_commit_group,
    output logic [4:0]   row_commit_global_q_head,
    output logic [6:0]   row_commit_row,
    output logic [1:0]   row_commit_slot_id,
    output logic [1:0]   row_commit_numeric_mode,
    output logic [31:0]  row_commit_sum_fp32,
    output logic [31:0]  row_commit_inv_sum_fp32,

    // Pre-publish B2 error report.  Acceptance starts the error-release path.
    output logic         row_error_valid,
    input  logic         row_error_ready,
    output logic [15:0]  row_error_epoch,
    output logic [2:0]   row_error_group,
    output logic [4:0]   row_error_global_q_head,
    output logic [6:0]   row_error_row,
    output logic [1:0]   row_error_slot_id,
    output logic [1:0]   row_error_numeric_mode,
    output logic [3:0]   row_error_code,
    output logic [6:0]   row_error_bad_key,

    // Frozen C -> B sealed-row publication.
    input  logic         pv_row_valid,
    output logic         pv_row_ready,
    input  logic [15:0]  pv_row_epoch,
    input  logic [2:0]   pv_row_group,
    input  logic [4:0]   pv_row_global_q_head,
    input  logic [6:0]   pv_row_row,
    input  logic [1:0]   pv_row_slot_id,
    input  logic [1:0]   pv_row_numeric_mode,
    input  logic [31:0]  pv_row_sum_fp32,
    input  logic [31:0]  pv_row_inv_sum_fp32,

    // Frozen B3 <-> C scalar weight read service.
    output logic         weight_rd_req_valid,
    input  logic         weight_rd_req_ready,
    output logic [15:0]  weight_rd_req_epoch,
    output logic [2:0]   weight_rd_req_group,
    output logic [4:0]   weight_rd_req_global_q_head,
    output logic [6:0]   weight_rd_req_row,
    output logic [1:0]   weight_rd_req_slot_id,
    output logic [1:0]   weight_rd_req_numeric_mode,
    output logic [6:0]   weight_rd_req_key,
    input  logic         weight_rd_rsp_valid,
    input  logic [15:0]  weight_rd_rsp_epoch,
    input  logic [2:0]   weight_rd_rsp_group,
    input  logic [4:0]   weight_rd_rsp_global_q_head,
    input  logic [6:0]   weight_rd_rsp_row,
    input  logic [1:0]   weight_rd_rsp_slot_id,
    input  logic [1:0]   weight_rd_rsp_numeric_mode,
    input  logic [6:0]   weight_rd_rsp_key,
    input  logic         weight_rd_rsp_mask,
    input  logic [31:0]  weight_rd_rsp_data,

    // Frozen V service and cluster output.
    output logic         v_req_valid,
    input  logic         v_req_ready,
    output logic [3:0]   v_req_context_tag,
    output logic [6:0]   v_req_key,
    output logic [1:0]   v_req_feature_block,
    input  logic         v_rsp_valid,
    input  logic [3:0]   v_rsp_context_tag,
    input  logic [511:0] v_rsp_vec_bf16,
    output logic         out_valid,
    input  logic         out_ready,
    output logic [15:0]  out_epoch,
    output logic [11:0]  out_seq,
    output logic [4:0]   out_global_q_head,
    output logic [6:0]   out_row,
    output logic [1:0]   out_feature_block,
    output logic [511:0] out_data_bf16,
    output logic         out_row_last,
    output logic         out_tensor_last,

    // Normal release to C and final score-slot release to A.
    output logic         weight_release_valid,
    input  logic         weight_release_ready,
    output logic [15:0]  weight_release_epoch,
    output logic [2:0]   weight_release_group,
    output logic [4:0]   weight_release_global_q_head,
    output logic [6:0]   weight_release_row,
    output logic [1:0]   weight_release_slot_id,
    output logic [1:0]   weight_release_numeric_mode,
    output logic         final_release_valid,
    input  logic         final_release_ready,
    output logic [15:0]  final_release_epoch,
    output logic [2:0]   final_release_group,
    output logic [4:0]   final_release_global_q_head,
    output logic [6:0]   final_release_row,
    output logic [1:0]   final_release_slot_id,
    output logic [1:0]   final_release_numeric_mode,

    // B4 gate counters.  Arithmetic-internal counters remain in B2/B3.
    output logic [63:0]  b2_rows_issue,
    output logic [63:0]  b2_exp_issue,
    output logic [63:0]  b2_exp_commit,
    output logic [63:0]  b2_weight_writes,
    output logic [63:0]  b2_row_commits,
    output logic [63:0]  b2_slot_releases,
    output logic [63:0]  b2_protocol_errors,
    output logic [63:0]  b2_numeric_errors,
    output logic [63:0]  b2_owner_errors,
    output logic [63:0]  b3_pv_rows,
    output logic [63:0]  b3_weight_requests,
    output logic [63:0]  b3_weight_responses,
    output logic [63:0]  b3_weight_consumes,
    output logic [63:0]  b3_v_requests,
    output logic [63:0]  b3_v_responses,
    output logic [63:0]  b3_v_consumes,
    output logic [63:0]  b3_pv_issue,
    output logic [63:0]  b3_pv_result,
    output logic [63:0]  b3_pv_commit,
    output logic [63:0]  b3_context_words,
    output logic [63:0]  b3_rows_released,
    output logic [63:0]  b3_protocol_errors,
    output logic [63:0]  b3_numeric_errors,
    output logic [63:0]  b3_epoch_drops,
    output logic [63:0]  final_release_count,
    output logic [63:0]  release_join_errors,
    output logic         error_sticky
);
    logic b2_error_sticky;
    logic b3_error_sticky;
    logic b2_row_error_valid;
    logic b2_row_error_ready;
    logic [15:0] b2_row_error_epoch;
    logic [2:0] b2_row_error_group;
    logic [4:0] b2_row_error_head;
    logic [6:0] b2_row_error_row;
    logic [1:0] b2_row_error_slot;
    logic [1:0] b2_row_error_mode;
    logic [3:0] b2_row_error_code;
    logic [6:0] b2_row_error_key;

    logic b2_release_valid;
    logic b2_release_ready;
    logic b3_release_valid;
    logic b3_release_ready;
    logic [15:0] b3_release_epoch;
    logic [2:0] b3_release_group;
    logic [4:0] b3_release_head;
    logic [6:0] b3_release_row;
    logic [1:0] b3_release_slot;
    logic [1:0] b3_release_mode;

    logic release_pending;
    logic release_is_error;
    logic release_c_done;
    logic release_b2_done;
    logic release_wait_error_seen;
    logic [15:0] release_epoch;
    logic [2:0] release_group;
    logic [4:0] release_head;
    logic [6:0] release_row;
    logic [1:0] release_slot;
    logic [1:0] release_mode;
    logic normal_capture;
    logic error_capture;
    logic c_release_fire;
    logic b2_release_fire;
    logic final_release_fire;

    assign row_error_valid = b2_row_error_valid;
    assign row_error_epoch = b2_row_error_epoch;
    assign row_error_group = b2_row_error_group;
    assign row_error_global_q_head = b2_row_error_head;
    assign row_error_row = b2_row_error_row;
    assign row_error_slot_id = b2_row_error_slot;
    assign row_error_numeric_mode = b2_row_error_mode;
    assign row_error_code = b2_row_error_code;
    assign row_error_bad_key = b2_row_error_key;

    // Error reports have priority over a simultaneous normal release.  This
    // keeps one deterministic lifecycle transition at the wrapper boundary.
    assign b2_row_error_ready = row_error_ready && !release_pending;
    assign error_capture = b2_row_error_valid && b2_row_error_ready;
    assign b3_release_ready = !release_pending && !b2_row_error_valid;
    assign normal_capture = b3_release_valid && b3_release_ready;

    assign b2_release_valid = release_pending && !release_b2_done;
    assign b2_release_fire = b2_release_valid && b2_release_ready;

    assign weight_release_valid = release_pending && !release_is_error &&
                                  !release_c_done;
    assign weight_release_epoch = release_epoch;
    assign weight_release_group = release_group;
    assign weight_release_global_q_head = release_head;
    assign weight_release_row = release_row;
    assign weight_release_slot_id = release_slot;
    assign weight_release_numeric_mode = release_mode;
    assign c_release_fire = weight_release_valid && weight_release_ready;

    assign final_release_valid = release_pending && release_b2_done &&
                                 (release_is_error || release_c_done);
    assign final_release_epoch = release_epoch;
    assign final_release_group = release_group;
    assign final_release_global_q_head = release_head;
    assign final_release_row = release_row;
    assign final_release_slot_id = release_slot;
    assign final_release_numeric_mode = release_mode;
    assign final_release_fire = final_release_valid && final_release_ready;

    cats_r4_b2_shared_stager_v3_wrapper #(
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_softmax (
        .clk, .rst_n, .clear, .counter_clear,
        .row_valid, .row_ready, .row_epoch, .row_group,
        .row_global_q_head, .row_index, .row_slot_id,
        .row_numeric_mode, .row_max_bf16,
        .score_valid, .score_ready, .score_epoch, .score_group,
        .score_global_q_head, .score_row, .score_slot_id,
        .score_numeric_mode, .score_key, .score_bf16, .score_last,
        .weight_wr_valid, .weight_wr_ready, .weight_wr_epoch,
        .weight_wr_group, .weight_wr_global_q_head, .weight_wr_row,
        .weight_wr_slot_id, .weight_wr_numeric_mode, .weight_wr_key,
        .weight_wr_mask, .weight_wr_data, .weight_wr_last,
        .row_commit_valid, .row_commit_ready, .row_commit_epoch,
        .row_commit_group, .row_commit_global_q_head, .row_commit_row,
        .row_commit_slot_id, .row_commit_numeric_mode,
        .row_commit_sum_fp32, .row_commit_inv_sum_fp32,
        .row_error_valid(b2_row_error_valid),
        .row_error_ready(b2_row_error_ready),
        .row_error_epoch(b2_row_error_epoch),
        .row_error_group(b2_row_error_group),
        .row_error_global_q_head(b2_row_error_head),
        .row_error_row(b2_row_error_row),
        .row_error_slot_id(b2_row_error_slot),
        .row_error_numeric_mode(b2_row_error_mode),
        .row_error_code(b2_row_error_code),
        .row_error_bad_key(b2_row_error_key),
        .slot_release_valid(b2_release_valid),
        .slot_release_ready(b2_release_ready),
        .slot_release_epoch(release_epoch),
        .slot_release_group(release_group),
        .slot_release_global_q_head(release_head),
        .slot_release_row(release_row),
        .slot_release_slot_id(release_slot),
        .slot_release_numeric_mode(release_mode),
        .slot_owned_state(), .slot_mode_state(),
        .rows_issue(b2_rows_issue), .rows_result(),
        .exp_issue(b2_exp_issue), .exp_result(),
        .exp_commit(b2_exp_commit), .sum_issue(), .sum_result(),
        .sum_commit(), .reciprocal_issue(), .reciprocal_result(),
        .reciprocal_commit(), .staged_weight_accept(),
        .weight_wr_accept(b2_weight_writes),
        .row_commit_count(b2_row_commits),
        .slot_release_count(b2_slot_releases),
        .protocol_error_count(b2_protocol_errors),
        .numeric_error_count(b2_numeric_errors),
        .owner_error_count(b2_owner_errors), .mask_error_count(),
        .mode_error_count(), .weight_conflict_cycles(),
        .finalize_conflict_cycles(), .output_stall_cycles(),
        .exp_stall_cycles(), .sum_stall_cycles(),
        .reciprocal_busy_stall_cycles(),
        .reciprocal_output_stall_cycles(),
        .error_sticky(b2_error_sticky)
    );

    cats_r4_b3_pv_32lane u_pv (
        .clk, .rst_n, .clear, .counter_clear,
        .pv_row_valid, .pv_row_ready, .pv_row_epoch, .pv_row_group,
        .pv_row_global_q_head, .pv_row_row, .pv_row_slot_id,
        .pv_row_numeric_mode, .pv_row_sum_fp32,
        .pv_row_inv_sum_fp32,
        .weight_rd_req_valid, .weight_rd_req_ready,
        .weight_rd_req_epoch, .weight_rd_req_group,
        .weight_rd_req_global_q_head, .weight_rd_req_row,
        .weight_rd_req_slot_id, .weight_rd_req_numeric_mode,
        .weight_rd_req_key, .weight_rd_rsp_valid,
        .weight_rd_rsp_epoch, .weight_rd_rsp_group,
        .weight_rd_rsp_global_q_head, .weight_rd_rsp_row,
        .weight_rd_rsp_slot_id, .weight_rd_rsp_numeric_mode,
        .weight_rd_rsp_key, .weight_rd_rsp_mask,
        .weight_rd_rsp_data,
        .v_req_valid, .v_req_ready, .v_req_context_tag, .v_req_key,
        .v_req_feature_block, .v_rsp_valid, .v_rsp_context_tag,
        .v_rsp_vec_bf16,
        .out_valid, .out_ready, .out_epoch, .out_seq,
        .out_global_q_head, .out_row, .out_feature_block,
        .out_data_bf16, .out_row_last, .out_tensor_last,
        .weight_release_valid(b3_release_valid),
        .weight_release_ready(b3_release_ready),
        .weight_release_epoch(b3_release_epoch),
        .weight_release_group(b3_release_group),
        .weight_release_global_q_head(b3_release_head),
        .weight_release_row(b3_release_row),
        .weight_release_slot_id(b3_release_slot),
        .weight_release_numeric_mode(b3_release_mode),
        .pv_rows_accepted(b3_pv_rows),
        .weight_rd_requests(b3_weight_requests),
        .weight_rd_responses(b3_weight_responses),
        .weight_rd_consumes(b3_weight_consumes),
        .v_requests(b3_v_requests), .v_responses(b3_v_responses),
        .v_consumes(b3_v_consumes), .pv_mac_issue(b3_pv_issue),
        .pv_mac_result(b3_pv_result), .pv_mac_commit(b3_pv_commit),
        .context_words(b3_context_words),
        .rows_released(b3_rows_released),
        .raw_scoreboard_stalls(), .weight_stall_cycles(),
        .v_stall_cycles(), .mac_stall_cycles(), .output_stall_cycles(),
        .protocol_error_count(b3_protocol_errors),
        .numeric_error_count(b3_numeric_errors),
        .epoch_drop_count(b3_epoch_drops),
        .arithmetic_vector_issue(), .arithmetic_lane_products(),
        .arithmetic_lane_commits(), .normalize_issue_count(),
        .normalize_result_count(), .arithmetic_protocol_errors(),
        .arithmetic_numeric_errors(), .error_sticky(b3_error_sticky)
    );

    assign error_sticky = b2_error_sticky || b3_error_sticky ||
                          (release_join_errors != 0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            release_pending <= 1'b0;
            release_is_error <= 1'b0;
            release_c_done <= 1'b0;
            release_b2_done <= 1'b0;
            release_wait_error_seen <= 1'b0;
            release_epoch <= '0;
            release_group <= '0;
            release_head <= '0;
            release_row <= '0;
            release_slot <= '0;
            release_mode <= '0;
            final_release_count <= '0;
            release_join_errors <= '0;
        end else if (clear) begin
            release_pending <= 1'b0;
            release_is_error <= 1'b0;
            release_c_done <= 1'b0;
            release_b2_done <= 1'b0;
            release_wait_error_seen <= 1'b0;
        end else begin
            if (error_capture) begin
                release_pending <= 1'b1;
                release_is_error <= 1'b1;
                release_c_done <= 1'b1;
                release_b2_done <= 1'b0;
                release_wait_error_seen <= 1'b0;
                release_epoch <= b2_row_error_epoch;
                release_group <= b2_row_error_group;
                release_head <= b2_row_error_head;
                release_row <= b2_row_error_row;
                release_slot <= b2_row_error_slot;
                release_mode <= b2_row_error_mode;
            end else if (normal_capture) begin
                release_pending <= 1'b1;
                release_is_error <= 1'b0;
                release_c_done <= 1'b0;
                release_b2_done <= 1'b0;
                release_wait_error_seen <= 1'b0;
                release_epoch <= b3_release_epoch;
                release_group <= b3_release_group;
                release_head <= b3_release_head;
                release_row <= b3_release_row;
                release_slot <= b3_release_slot;
                release_mode <= b3_release_mode;
            end

            if (c_release_fire)
                release_c_done <= 1'b1;
            if (b2_release_fire)
                release_b2_done <= 1'b1;
            if (final_release_fire) begin
                release_pending <= 1'b0;
                final_release_count <= final_release_count + 1'b1;
            end

            if (release_pending && !release_b2_done &&
                b2_release_valid && !b2_release_ready &&
                !release_wait_error_seen) begin
                release_wait_error_seen <= 1'b1;
                release_join_errors <= release_join_errors + 1'b1;
            end

            if (counter_clear) begin
                final_release_count <= '0;
                release_join_errors <= '0;
            end
        end
    end

`ifndef SYNTHESIS
    logic [34:0] held_c_release;
    logic [34:0] held_final_release;
    logic c_release_was_stalled;
    logic final_release_was_stalled;
    wire [34:0] c_release_payload = {weight_release_epoch,
        weight_release_group, weight_release_global_q_head,
        weight_release_row, weight_release_slot_id,
        weight_release_numeric_mode};
    wire [34:0] final_release_payload = {final_release_epoch,
        final_release_group, final_release_global_q_head,
        final_release_row, final_release_slot_id,
        final_release_numeric_mode};
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            c_release_was_stalled <= 1'b0;
            final_release_was_stalled <= 1'b0;
        end else begin
            if (c_release_was_stalled &&
                (!weight_release_valid ||
                 c_release_payload != held_c_release))
                $fatal(1, "B4 C release changed while stalled");
            if (final_release_was_stalled &&
                (!final_release_valid ||
                 final_release_payload != held_final_release))
                $fatal(1, "B4 A final release changed while stalled");
            c_release_was_stalled <= weight_release_valid &&
                                     !weight_release_ready;
            final_release_was_stalled <= final_release_valid &&
                                         !final_release_ready;
            if (weight_release_valid && !weight_release_ready)
                held_c_release <= c_release_payload;
            if (final_release_valid && !final_release_ready)
                held_final_release <= final_release_payload;
            if (final_release_valid &&
                (!release_b2_done ||
                 (!release_is_error && !release_c_done)))
                $fatal(1, "B4 final release preceded owner drain");
        end
    end
`endif
endmodule
