`timescale 1ns/1ps

// Test-only C weight-slab service for B4.  It implements the frozen V3
// ownership sequence (128 writes -> commit -> pv_row -> scalar reads ->
// release) and the mandatory two-cycle, non-backpressured read response.
module tb_cats_r4_b4_c_weight_model #(
    parameter integer CLUSTERS = 1,
    parameter integer CLUSTER_ID = 0,
    parameter integer ROWS_PER_HEAD = 128,
    parameter logic [31:0] SEED = 32'hb4c0_0001
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         clear,
    input  logic         counter_clear,
    input  logic         weight_wr_valid,
    output logic         weight_wr_ready,
    input  logic [15:0]  weight_wr_epoch,
    input  logic [2:0]   weight_wr_group,
    input  logic [4:0]   weight_wr_global_q_head,
    input  logic [6:0]   weight_wr_row,
    input  logic [1:0]   weight_wr_slot_id,
    input  logic [1:0]   weight_wr_numeric_mode,
    input  logic [6:0]   weight_wr_key,
    input  logic         weight_wr_mask,
    input  logic [31:0]  weight_wr_data,
    input  logic         weight_wr_last,
    input  logic         row_commit_valid,
    output logic         row_commit_ready,
    input  logic [15:0]  row_commit_epoch,
    input  logic [2:0]   row_commit_group,
    input  logic [4:0]   row_commit_global_q_head,
    input  logic [6:0]   row_commit_row,
    input  logic [1:0]   row_commit_slot_id,
    input  logic [1:0]   row_commit_numeric_mode,
    input  logic [31:0]  row_commit_sum_fp32,
    input  logic [31:0]  row_commit_inv_sum_fp32,
    output logic         pv_row_valid,
    input  logic         pv_row_ready,
    output logic [15:0]  pv_row_epoch,
    output logic [2:0]   pv_row_group,
    output logic [4:0]   pv_row_global_q_head,
    output logic [6:0]   pv_row_row,
    output logic [1:0]   pv_row_slot_id,
    output logic [1:0]   pv_row_numeric_mode,
    output logic [31:0]  pv_row_sum_fp32,
    output logic [31:0]  pv_row_inv_sum_fp32,
    input  logic         weight_rd_req_valid,
    output logic         weight_rd_req_ready,
    input  logic [15:0]  weight_rd_req_epoch,
    input  logic [2:0]   weight_rd_req_group,
    input  logic [4:0]   weight_rd_req_global_q_head,
    input  logic [6:0]   weight_rd_req_row,
    input  logic [1:0]   weight_rd_req_slot_id,
    input  logic [1:0]   weight_rd_req_numeric_mode,
    input  logic [6:0]   weight_rd_req_key,
    output logic         weight_rd_rsp_valid,
    output logic [15:0]  weight_rd_rsp_epoch,
    output logic [2:0]   weight_rd_rsp_group,
    output logic [4:0]   weight_rd_rsp_global_q_head,
    output logic [6:0]   weight_rd_rsp_row,
    output logic [1:0]   weight_rd_rsp_slot_id,
    output logic [1:0]   weight_rd_rsp_numeric_mode,
    output logic [6:0]   weight_rd_rsp_key,
    output logic         weight_rd_rsp_mask,
    output logic [31:0]  weight_rd_rsp_data,
    input  logic         weight_release_valid,
    output logic         weight_release_ready,
    input  logic [15:0]  weight_release_epoch,
    input  logic [2:0]   weight_release_group,
    input  logic [4:0]   weight_release_global_q_head,
    input  logic [6:0]   weight_release_row,
    input  logic [1:0]   weight_release_slot_id,
    input  logic [1:0]   weight_release_numeric_mode,
    output logic [63:0]  c_weight_writes,
    output logic [63:0]  c_row_commits,
    output logic [63:0]  c_pv_rows,
    output logic [63:0]  c_weight_requests,
    output logic [63:0]  c_weight_responses,
    output logic [63:0]  c_weight_releases,
    output logic         c_error_sticky
);
    localparam logic [1:0] S_FREE = 2'd0;
    localparam logic [1:0] S_WRITING = 2'd1;
    localparam logic [1:0] S_SEALED = 2'd2;
    localparam logic [1:0] S_PUBLISHED = 2'd3;

    logic [1:0] slot_state [0:2];
    logic [7:0] slot_write_count [0:2];
    logic [15:0] slot_epoch [0:2];
    logic [2:0] slot_group [0:2];
    logic [4:0] slot_head [0:2];
    logic [6:0] slot_row [0:2];
    logic [1:0] slot_mode [0:2];
    logic [31:0] slot_sum [0:2];
    logic [31:0] slot_inv [0:2];
    logic slot_mask [0:2][0:127];
    logic [31:0] slot_data [0:2][0:127];
    logic [31:0] lfsr;
    logic [1:0] pv_hold_slot;
    logic pv_select_valid;
    logic row_commit_fire, pv_row_fire;
    integer publish_sequence;
    integer expected_publish_head;
    integer expected_publish_row;

    logic rd0_valid, rd1_valid;
    logic [15:0] rd0_epoch, rd1_epoch;
    logic [2:0] rd0_group, rd1_group;
    logic [4:0] rd0_head, rd1_head;
    logic [6:0] rd0_row, rd1_row;
    logic [1:0] rd0_slot, rd1_slot;
    logic [1:0] rd0_mode, rd1_mode;
    logic [6:0] rd0_key, rd1_key;
    logic rd0_mask, rd1_mask;
    logic [31:0] rd0_data, rd1_data;
    integer idx;
    integer scan;

    function automatic logic token_matches(
        input logic [1:0] slot,
        input logic [15:0] epoch,
        input logic [2:0] group_id,
        input logic [4:0] head,
        input logic [6:0] row_id,
        input logic [1:0] mode
    );
        begin
            token_matches = slot < 3 && slot_epoch[slot] == epoch &&
                slot_group[slot] == group_id && slot_head[slot] == head &&
                slot_row[slot] == row_id && slot_mode[slot] == mode;
        end
    endfunction

    function automatic logic [1:0] inc3(input logic [1:0] value);
        begin
            inc3 = value == 2 ? 0 : value + 1'b1;
        end
    endfunction

    assign weight_wr_ready = lfsr[0] || lfsr[3];
    assign row_commit_ready = lfsr[1] || lfsr[5];
    assign weight_rd_req_ready = lfsr[2] || lfsr[7];
    assign weight_release_ready = lfsr[4] || lfsr[9];
    assign row_commit_fire = row_commit_valid && row_commit_ready;
    assign pv_row_fire = pv_row_valid && pv_row_ready;
    assign pv_row_valid = pv_select_valid;
    assign pv_row_epoch = slot_epoch[pv_hold_slot];
    assign pv_row_group = slot_group[pv_hold_slot];
    assign pv_row_global_q_head = slot_head[pv_hold_slot];
    assign pv_row_row = slot_row[pv_hold_slot];
    assign pv_row_slot_id = pv_hold_slot;
    assign pv_row_numeric_mode = slot_mode[pv_hold_slot];
    assign pv_row_sum_fp32 = slot_sum[pv_hold_slot];
    assign pv_row_inv_sum_fp32 = slot_inv[pv_hold_slot];

    always_comb begin
        expected_publish_head = CLUSTER_ID +
                                (publish_sequence / ROWS_PER_HEAD) *
                                CLUSTERS;
        expected_publish_row = publish_sequence % ROWS_PER_HEAD;
        pv_select_valid = 1'b0;
        pv_hold_slot = 2'd0;
        for (scan = 0; scan < 3; scan = scan + 1) begin
            if (!pv_select_valid && slot_state[scan] == S_SEALED &&
                slot_head[scan] == expected_publish_head &&
                slot_row[scan] == expected_publish_row) begin
                pv_select_valid = 1'b1;
                pv_hold_slot = scan[1:0];
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        integer slot;
        if (!rst_n) begin
            lfsr <= SEED ^ CLUSTER_ID;
            publish_sequence <= 0;
            rd0_valid <= 1'b0;
            rd1_valid <= 1'b0;
            weight_rd_rsp_valid <= 1'b0;
            weight_rd_rsp_epoch <= '0;
            weight_rd_rsp_group <= '0;
            weight_rd_rsp_global_q_head <= '0;
            weight_rd_rsp_row <= '0;
            weight_rd_rsp_slot_id <= '0;
            weight_rd_rsp_numeric_mode <= '0;
            weight_rd_rsp_key <= '0;
            weight_rd_rsp_mask <= 1'b0;
            weight_rd_rsp_data <= '0;
            c_weight_writes <= '0;
            c_row_commits <= '0;
            c_pv_rows <= '0;
            c_weight_requests <= '0;
            c_weight_responses <= '0;
            c_weight_releases <= '0;
            c_error_sticky <= 1'b0;
            for (idx = 0; idx < 3; idx = idx + 1) begin
                slot_state[idx] <= S_FREE;
                slot_write_count[idx] <= '0;
                slot_epoch[idx] <= '0;
                slot_group[idx] <= '0;
                slot_head[idx] <= '0;
                slot_row[idx] <= '0;
                slot_mode[idx] <= '0;
                slot_sum[idx] <= '0;
                slot_inv[idx] <= '0;
            end
        end else if (clear) begin
            publish_sequence <= 0;
            rd0_valid <= 1'b0;
            rd1_valid <= 1'b0;
            weight_rd_rsp_valid <= 1'b0;
            c_error_sticky <= 1'b0;
            for (idx = 0; idx < 3; idx = idx + 1) begin
                slot_state[idx] <= S_FREE;
                slot_write_count[idx] <= '0;
            end
        end else begin
            lfsr <= {lfsr[30:0],
                lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};

            if (weight_wr_valid && weight_wr_ready) begin
                slot = weight_wr_slot_id;
                if (slot >= 3 || weight_wr_group !=
                    weight_wr_global_q_head[4:2] ||
                    weight_wr_numeric_mode >= 2 ||
                    weight_wr_key != slot_write_count[slot] ||
                    weight_wr_last != (weight_wr_key == 127) ||
                    weight_wr_mask != (weight_wr_key > weight_wr_row) ||
                    (weight_wr_mask && weight_wr_data != 0) ||
                    (!weight_wr_mask && weight_wr_numeric_mode == 0 &&
                     weight_wr_data != 32'h00003f80) ||
                    (!weight_wr_mask && weight_wr_numeric_mode == 1 &&
                     weight_wr_data != 32'h3f800000))
                    $fatal(1, "B4 C model invalid weight write");
                if (slot_state[slot] == S_FREE) begin
                    if (weight_wr_key != 0)
                        $fatal(1, "B4 C model slot did not start at key zero");
                    slot_state[slot] <= S_WRITING;
                    slot_epoch[slot] <= weight_wr_epoch;
                    slot_group[slot] <= weight_wr_group;
                    slot_head[slot] <= weight_wr_global_q_head;
                    slot_row[slot] <= weight_wr_row;
                    slot_mode[slot] <= weight_wr_numeric_mode;
                end else if (slot_state[slot] != S_WRITING ||
                    !token_matches(slot, weight_wr_epoch, weight_wr_group,
                        weight_wr_global_q_head, weight_wr_row,
                        weight_wr_numeric_mode)) begin
                    $fatal(1, "B4 C model weight owner mismatch");
                end
                slot_mask[slot][weight_wr_key] <= weight_wr_mask;
                slot_data[slot][weight_wr_key] <= weight_wr_data;
                slot_write_count[slot] <= slot_write_count[slot] + 1'b1;
                c_weight_writes <= c_weight_writes + 1'b1;
            end

            if (row_commit_fire) begin
                slot = row_commit_slot_id;
                if (slot >= 3 || slot_state[slot] != S_WRITING ||
                    slot_write_count[slot] != 128 ||
                    !token_matches(slot, row_commit_epoch, row_commit_group,
                        row_commit_global_q_head, row_commit_row,
                        row_commit_numeric_mode) ||
                    row_commit_sum_fp32[30:23] == 8'hff ||
                    row_commit_inv_sum_fp32[30:23] == 8'hff ||
                    row_commit_sum_fp32[30:0] == 0 ||
                    row_commit_inv_sum_fp32[30:0] == 0)
                    $fatal(1, "B4 C model invalid row commit");
                slot_state[slot] <= S_SEALED;
                slot_sum[slot] <= row_commit_sum_fp32;
                slot_inv[slot] <= row_commit_inv_sum_fp32;
                c_row_commits <= c_row_commits + 1'b1;
            end

            if (pv_row_fire) begin
                if (slot_state[pv_hold_slot] != S_SEALED)
                    $fatal(1, "B4 C model published unsealed slot");
                slot_state[pv_hold_slot] <= S_PUBLISHED;
                publish_sequence <= publish_sequence + 1;
                c_pv_rows <= c_pv_rows + 1'b1;
            end

            rd0_valid <= weight_rd_req_valid && weight_rd_req_ready;
            if (weight_rd_req_valid && weight_rd_req_ready) begin
                slot = weight_rd_req_slot_id;
                if (slot >= 3 || slot_state[slot] != S_PUBLISHED ||
                    !token_matches(slot, weight_rd_req_epoch,
                        weight_rd_req_group, weight_rd_req_global_q_head,
                        weight_rd_req_row, weight_rd_req_numeric_mode) ||
                    weight_rd_req_key > slot_row[slot] ||
                    slot_mask[slot][weight_rd_req_key])
                    $fatal(1, "B4 C model invalid weight read");
                rd0_epoch <= weight_rd_req_epoch;
                rd0_group <= weight_rd_req_group;
                rd0_head <= weight_rd_req_global_q_head;
                rd0_row <= weight_rd_req_row;
                rd0_slot <= weight_rd_req_slot_id;
                rd0_mode <= weight_rd_req_numeric_mode;
                rd0_key <= weight_rd_req_key;
                rd0_mask <= slot_mask[slot][weight_rd_req_key];
                rd0_data <= slot_data[slot][weight_rd_req_key];
                c_weight_requests <= c_weight_requests + 1'b1;
            end
            rd1_valid <= rd0_valid;
            if (rd0_valid) begin
                rd1_epoch <= rd0_epoch;
                rd1_group <= rd0_group;
                rd1_head <= rd0_head;
                rd1_row <= rd0_row;
                rd1_slot <= rd0_slot;
                rd1_mode <= rd0_mode;
                rd1_key <= rd0_key;
                rd1_mask <= rd0_mask;
                rd1_data <= rd0_data;
            end
            weight_rd_rsp_valid <= rd1_valid;
            if (rd1_valid) begin
                weight_rd_rsp_epoch <= rd1_epoch;
                weight_rd_rsp_group <= rd1_group;
                weight_rd_rsp_global_q_head <= rd1_head;
                weight_rd_rsp_row <= rd1_row;
                weight_rd_rsp_slot_id <= rd1_slot;
                weight_rd_rsp_numeric_mode <= rd1_mode;
                weight_rd_rsp_key <= rd1_key;
                weight_rd_rsp_mask <= rd1_mask;
                weight_rd_rsp_data <= rd1_data;
                c_weight_responses <= c_weight_responses + 1'b1;
            end

            if (weight_release_valid && weight_release_ready) begin
                slot = weight_release_slot_id;
                if (slot >= 3 || slot_state[slot] != S_PUBLISHED ||
                    !token_matches(slot, weight_release_epoch,
                        weight_release_group,
                        weight_release_global_q_head,
                        weight_release_row,
                        weight_release_numeric_mode) ||
                    (rd0_valid && rd0_slot == slot) ||
                    (rd1_valid && rd1_slot == slot) ||
                    (weight_rd_rsp_valid &&
                     weight_rd_rsp_slot_id == slot))
                    $fatal(1, "B4 C model invalid weight release");
                slot_state[slot] <= S_FREE;
                slot_write_count[slot] <= '0;
                c_weight_releases <= c_weight_releases + 1'b1;
            end

            if (counter_clear) begin
                c_weight_writes <= '0;
                c_row_commits <= '0;
                c_pv_rows <= '0;
                c_weight_requests <= '0;
                c_weight_responses <= '0;
                c_weight_releases <= '0;
            end
        end
    end
endmodule
