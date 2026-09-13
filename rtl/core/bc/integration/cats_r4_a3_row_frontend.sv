`timescale 1ns/1ps

// CATS-R4 A3 composition: raw QK formatting/row handoff plus the physical
// three-slot score store. Scheduler context tags are the physical slot IDs.
module cats_r4_a3_row_frontend #(
    parameter logic [31:0] SCALE_FP32 = 32'h3db5_04f3
) (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          clear,
    input  logic          counter_clear,

    input  logic          txn_start_valid,
    output logic          txn_start_ready,
    input  logic [15:0]   txn_epoch,
    input  logic [1:0]    txn_numeric_mode,

    input  logic          raw_score_valid,
    output logic          raw_score_ready,
    input  logic [15:0]   raw_score_epoch,
    input  logic [2:0]    raw_score_group,
    input  logic [4:0]    raw_score_global_q_head,
    input  logic [6:0]    raw_score_row,
    input  logic [1:0]    raw_score_key_block,
    input  logic [3:0]    raw_score_context_tag,
    input  logic [31:0]   raw_score_lane_valid,
    input  logic [1023:0] raw_score_fp32,

    output logic          b_row_valid,
    input  logic          b_row_ready,
    output logic [15:0]   b_row_epoch,
    output logic [2:0]    b_row_group,
    output logic [4:0]    b_row_global_q_head,
    output logic [6:0]    b_row_index,
    output logic [1:0]    b_row_slot_id,
    output logic [1:0]    b_row_numeric_mode,
    output logic [15:0]   b_row_max_bf16,

    output logic          b_score_valid,
    input  logic          b_score_ready,
    output logic [15:0]   b_score_epoch,
    output logic [2:0]    b_score_group,
    output logic [4:0]    b_score_global_q_head,
    output logic [6:0]    b_score_row,
    output logic [6:0]    b_score_key,
    output logic [1:0]    b_score_slot_id,
    output logic [1:0]    b_score_numeric_mode,
    output logic [15:0]   b_score_bf16,
    output logic          b_score_last,

    input  logic          final_release_valid,
    output logic          final_release_ready,
    input  logic [15:0]   final_release_epoch,
    input  logic [2:0]    final_release_group,
    input  logic [4:0]    final_release_global_q_head,
    input  logic [6:0]    final_release_row,
    input  logic [1:0]    final_release_slot_id,
    input  logic [1:0]    final_release_numeric_mode,

    output logic          row_abort_valid,
    input  logic          row_abort_ready,
    output logic [15:0]   row_abort_epoch,
    output logic [2:0]    row_abort_group,
    output logic [4:0]    row_abort_global_q_head,
    output logic [6:0]    row_abort_row,
    output logic [6:0]    row_abort_error_key,
    output logic [1:0]    row_abort_slot_id,
    output logic [1:0]    row_abort_numeric_mode,
    output logic [2:0]    row_abort_error_code,

    output logic [5:0]    slot_owner,
    output logic [63:0]   rows_completed,
    output logic [63:0]   scores_transferred,
    output logic [63:0]   rows_transferred,
    output logic [63:0]   aborts,
    output logic [63:0]   owner_errors,
    output logic [63:0]   scale_requests_accepted,
    output logic [63:0]   scale_products_completed,
    output logic [63:0]   score_format_transfers,
    output logic [63:0]   formatter_protocol_errors,
    output logic [63:0]   score_write_vectors,
    output logic [63:0]   score_write_scores,
    output logic [63:0]   score_read_requests,
    output logic [63:0]   score_read_responses,
    output logic [63:0]   score_read_stall_cycles,
    output logic [63:0]   score_memory_errors,
    output logic [63:0]   context_slot_errors,
    output logic          a2_protocol_error_sticky,
    output logic          score_memory_error_sticky,
    output logic          context_slot_error_sticky,
    output logic          protocol_error_sticky
);
    logic raw_score_to_a2_valid;
    logic raw_score_to_a2_ready;
    logic invalid_context_seen;

    logic store_wr_valid;
    logic store_wr_ready;
    logic [1:0] store_wr_slot_id;
    logic [6:0] store_wr_key_base;
    logic [31:0] store_wr_lane_valid;
    logic [511:0] store_wr_score_bf16;
    logic score_rd_req_valid;
    logic score_rd_req_ready;
    logic [15:0] score_rd_req_epoch;
    logic [2:0] score_rd_req_group;
    logic [4:0] score_rd_req_global_q_head;
    logic [6:0] score_rd_req_row;
    logic [6:0] score_rd_req_key;
    logic [1:0] score_rd_req_slot_id;
    logic [1:0] score_rd_req_numeric_mode;
    logic score_rd_rsp_valid;
    logic score_rd_rsp_ready;
    logic [15:0] score_rd_rsp_epoch;
    logic [2:0] score_rd_rsp_group;
    logic [4:0] score_rd_rsp_global_q_head;
    logic [6:0] score_rd_rsp_row;
    logic [6:0] score_rd_rsp_key;
    logic [1:0] score_rd_rsp_slot_id;
    logic [1:0] score_rd_rsp_numeric_mode;
    logic [15:0] score_rd_rsp_bf16;

    assign raw_score_to_a2_valid = raw_score_valid &&
                                   raw_score_context_tag < 4'd3;
    assign raw_score_ready = raw_score_context_tag < 4'd3 ?
                             raw_score_to_a2_ready : 1'b0;
    assign protocol_error_sticky = a2_protocol_error_sticky ||
                                   score_memory_error_sticky ||
                                   context_slot_error_sticky;

    // A continuously held invalid beat is one rejected scheduler episode.
    always_ff @(posedge clk) begin
        if (!rst_n || counter_clear) begin
            context_slot_errors <= 64'd0;
            context_slot_error_sticky <= 1'b0;
            invalid_context_seen <= 1'b0;
        end else if (clear) begin
            invalid_context_seen <= 1'b0;
        end else begin
            if (!raw_score_valid || raw_score_context_tag < 4'd3)
                invalid_context_seen <= 1'b0;
            else if (!invalid_context_seen) begin
                context_slot_errors <= context_slot_errors + 1'b1;
                context_slot_error_sticky <= 1'b1;
                invalid_context_seen <= 1'b1;
            end
        end
    end

    cats_r4_qk_a2_row_pipeline #(
        .SEQ_LEN(128),
        .LANES(32),
        .SLOTS(3),
        .SCALE_FP32(SCALE_FP32)
    ) u_a2 (
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear),
        .counter_clear(counter_clear),
        .txn_start_valid(txn_start_valid),
        .txn_start_ready(txn_start_ready),
        .txn_epoch(txn_epoch),
        .txn_numeric_mode(txn_numeric_mode),
        .raw_score_valid(raw_score_to_a2_valid),
        .raw_score_ready(raw_score_to_a2_ready),
        .raw_score_epoch(raw_score_epoch),
        .raw_score_group(raw_score_group),
        .raw_score_global_q_head(raw_score_global_q_head),
        .raw_score_row(raw_score_row),
        .raw_score_key_block(raw_score_key_block),
        .raw_score_context_tag(raw_score_context_tag),
        .raw_score_lane_valid(raw_score_lane_valid),
        .raw_score_fp32(raw_score_fp32),
        .store_wr_valid(store_wr_valid),
        .store_wr_ready(store_wr_ready),
        .store_wr_slot_id(store_wr_slot_id),
        .store_wr_key_base(store_wr_key_base),
        .store_wr_lane_valid(store_wr_lane_valid),
        .store_wr_score_bf16(store_wr_score_bf16),
        .score_rd_req_valid(score_rd_req_valid),
        .score_rd_req_ready(score_rd_req_ready),
        .score_rd_req_epoch(score_rd_req_epoch),
        .score_rd_req_group(score_rd_req_group),
        .score_rd_req_global_q_head(score_rd_req_global_q_head),
        .score_rd_req_row(score_rd_req_row),
        .score_rd_req_key(score_rd_req_key),
        .score_rd_req_slot_id(score_rd_req_slot_id),
        .score_rd_req_numeric_mode(score_rd_req_numeric_mode),
        .score_rd_rsp_valid(score_rd_rsp_valid),
        .score_rd_rsp_ready(score_rd_rsp_ready),
        .score_rd_rsp_epoch(score_rd_rsp_epoch),
        .score_rd_rsp_group(score_rd_rsp_group),
        .score_rd_rsp_global_q_head(score_rd_rsp_global_q_head),
        .score_rd_rsp_row(score_rd_rsp_row),
        .score_rd_rsp_key(score_rd_rsp_key),
        .score_rd_rsp_slot_id(score_rd_rsp_slot_id),
        .score_rd_rsp_numeric_mode(score_rd_rsp_numeric_mode),
        .score_rd_rsp_bf16(score_rd_rsp_bf16),
        .b_row_valid(b_row_valid),
        .b_row_ready(b_row_ready),
        .b_row_epoch(b_row_epoch),
        .b_row_group(b_row_group),
        .b_row_global_q_head(b_row_global_q_head),
        .b_row_index(b_row_index),
        .b_row_slot_id(b_row_slot_id),
        .b_row_numeric_mode(b_row_numeric_mode),
        .b_row_max_bf16(b_row_max_bf16),
        .b_score_valid(b_score_valid),
        .b_score_ready(b_score_ready),
        .b_score_epoch(b_score_epoch),
        .b_score_group(b_score_group),
        .b_score_global_q_head(b_score_global_q_head),
        .b_score_row(b_score_row),
        .b_score_key(b_score_key),
        .b_score_slot_id(b_score_slot_id),
        .b_score_numeric_mode(b_score_numeric_mode),
        .b_score_bf16(b_score_bf16),
        .b_score_last(b_score_last),
        .final_release_valid(final_release_valid),
        .final_release_ready(final_release_ready),
        .final_release_epoch(final_release_epoch),
        .final_release_group(final_release_group),
        .final_release_global_q_head(final_release_global_q_head),
        .final_release_row(final_release_row),
        .final_release_slot_id(final_release_slot_id),
        .final_release_numeric_mode(final_release_numeric_mode),
        .row_abort_valid(row_abort_valid),
        .row_abort_ready(row_abort_ready),
        .row_abort_epoch(row_abort_epoch),
        .row_abort_group(row_abort_group),
        .row_abort_global_q_head(row_abort_global_q_head),
        .row_abort_row(row_abort_row),
        .row_abort_error_key(row_abort_error_key),
        .row_abort_slot_id(row_abort_slot_id),
        .row_abort_numeric_mode(row_abort_numeric_mode),
        .row_abort_error_code(row_abort_error_code),
        .slot_owner(slot_owner),
        .rows_completed(rows_completed),
        .scores_transferred(scores_transferred),
        .rows_transferred(rows_transferred),
        .aborts(aborts),
        .owner_errors(owner_errors),
        .scale_requests_accepted(scale_requests_accepted),
        .scale_products_completed(scale_products_completed),
        .score_format_transfers(score_format_transfers),
        .formatter_protocol_errors(formatter_protocol_errors),
        .protocol_error_sticky(a2_protocol_error_sticky)
    );

    cats_r4_qk_score_slot_mem u_score_mem (
        .clk(clk),
        .rst_n(rst_n),
        .clear(clear),
        .counter_clear(counter_clear),
        .store_wr_valid(store_wr_valid),
        .store_wr_ready(store_wr_ready),
        .store_wr_slot_id(store_wr_slot_id),
        .store_wr_key_base(store_wr_key_base),
        .store_wr_lane_valid(store_wr_lane_valid),
        .store_wr_score_bf16(store_wr_score_bf16),
        .score_rd_req_valid(score_rd_req_valid),
        .score_rd_req_ready(score_rd_req_ready),
        .score_rd_req_epoch(score_rd_req_epoch),
        .score_rd_req_group(score_rd_req_group),
        .score_rd_req_global_q_head(score_rd_req_global_q_head),
        .score_rd_req_row(score_rd_req_row),
        .score_rd_req_key(score_rd_req_key),
        .score_rd_req_slot_id(score_rd_req_slot_id),
        .score_rd_req_numeric_mode(score_rd_req_numeric_mode),
        .score_rd_rsp_valid(score_rd_rsp_valid),
        .score_rd_rsp_ready(score_rd_rsp_ready),
        .score_rd_rsp_epoch(score_rd_rsp_epoch),
        .score_rd_rsp_group(score_rd_rsp_group),
        .score_rd_rsp_global_q_head(score_rd_rsp_global_q_head),
        .score_rd_rsp_row(score_rd_rsp_row),
        .score_rd_rsp_key(score_rd_rsp_key),
        .score_rd_rsp_slot_id(score_rd_rsp_slot_id),
        .score_rd_rsp_numeric_mode(score_rd_rsp_numeric_mode),
        .score_rd_rsp_bf16(score_rd_rsp_bf16),
        .write_vectors(score_write_vectors),
        .write_scores(score_write_scores),
        .read_requests(score_read_requests),
        .read_responses(score_read_responses),
        .read_stall_cycles(score_read_stall_cycles),
        .protocol_errors(score_memory_errors),
        .protocol_error_sticky(score_memory_error_sticky)
    );
endmodule
