`timescale 1ns/1ps

module cats_r4_qk_row_assembler #(
    parameter int SEQ_LEN = 128,
    parameter int LANES   = 32,
    parameter int SLOTS   = 3
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  clear,
    input  logic                  counter_clear,

    input  logic                  txn_start_valid,
    output logic                  txn_start_ready,
    input  logic [15:0]           txn_epoch,
    input  logic [1:0]            txn_numeric_mode,

    input  logic                  row_open_valid,
    output logic                  row_open_ready,
    input  logic [15:0]           row_open_epoch,
    input  logic [2:0]            row_open_group,
    input  logic [4:0]            row_open_global_q_head,
    input  logic [6:0]            row_open_row,
    input  logic [1:0]            row_open_slot_id,
    input  logic [1:0]            row_open_numeric_mode,

    input  logic                  block_valid,
    output logic                  block_ready,
    input  logic [15:0]           block_epoch,
    input  logic [2:0]            block_group,
    input  logic [4:0]            block_global_q_head,
    input  logic [6:0]            block_row,
    input  logic [1:0]            block_slot_id,
    input  logic [1:0]            block_numeric_mode,
    input  logic [1:0]            block_key_block,
    input  logic [LANES-1:0]      block_lane_valid,
    input  logic [LANES*16-1:0]   block_score_bf16,

    output logic                  store_wr_valid,
    input  logic                  store_wr_ready,
    output logic [1:0]            store_wr_slot_id,
    output logic [6:0]            store_wr_key_base,
    output logic [LANES-1:0]      store_wr_lane_valid,
    output logic [LANES*16-1:0]   store_wr_score_bf16,

    output logic                  row_valid,
    input  logic                  row_ready,
    output logic [15:0]           row_epoch,
    output logic [2:0]            row_group,
    output logic [4:0]            row_global_q_head,
    output logic [6:0]            row_index,
    output logic [1:0]            row_slot_id,
    output logic [1:0]            row_numeric_mode,
    output logic [15:0]           row_max_bf16,

    output logic                  abort_valid,
    input  logic                  abort_ready,
    output logic [15:0]           abort_epoch,
    output logic [2:0]            abort_group,
    output logic [4:0]            abort_global_q_head,
    output logic [6:0]            abort_row,
    output logic [1:0]            abort_slot_id,
    output logic [1:0]            abort_numeric_mode,
    output logic [2:0]            abort_error_code,
    output logic [6:0]            abort_error_key,

    output logic [63:0]           rows_opened,
    output logic [63:0]           blocks_accepted,
    output logic [63:0]           scores_accepted,
    output logic [63:0]           rows_completed,
    output logic [63:0]           protocol_errors,
    output logic [63:0]           numeric_errors,
    output logic [63:0]           mode_errors,
    output logic                  protocol_error_sticky
);
    localparam int SLOT_W = (SLOTS <= 1) ? 1 : $clog2(SLOTS);

    logic txn_active;
    logic [15:0] active_epoch;
    logic [1:0] active_numeric_mode;

    logic slot_active [0:SLOTS-1];
    logic [15:0] slot_epoch [0:SLOTS-1];
    logic [2:0] slot_group [0:SLOTS-1];
    logic [4:0] slot_head [0:SLOTS-1];
    logic [6:0] slot_row [0:SLOTS-1];
    logic [1:0] slot_mode [0:SLOTS-1];
    logic [1:0] slot_next_block [0:SLOTS-1];
    logic slot_max_valid [0:SLOTS-1];
    logic [15:0] slot_max [0:SLOTS-1];

    logic selected_slot_valid;
    logic selected_token_match;
    logic selected_block_match;
    logic [LANES-1:0] expected_lane_valid;
    logic selected_lane_match;
    logic selected_is_last;
    logic selected_legal;
    logic block_has_finite;
    logic block_has_nonfinite;
    logic [15:0] block_max;
    logic [15:0] completed_max;
    logic [7:0] lane_count;

    integer i;
    integer lane;

    function automatic logic bf16_is_finite(input logic [15:0] value);
        bf16_is_finite = value[14:7] != 8'hff;
    endfunction

    function automatic logic bf16_gt(
        input logic [15:0] lhs,
        input logic [15:0] rhs
    );
        logic lhs_zero;
        logic rhs_zero;
        begin
            lhs_zero = lhs[14:0] == 15'b0;
            rhs_zero = rhs[14:0] == 15'b0;
            if (lhs_zero && rhs_zero)
                bf16_gt = 1'b0;
            else if (lhs[15] != rhs[15])
                bf16_gt = rhs[15];
            else if (!lhs[15])
                bf16_gt = lhs[14:0] > rhs[14:0];
            else
                bf16_gt = lhs[14:0] < rhs[14:0];
        end
    endfunction

    always_comb begin
        selected_slot_valid = (block_slot_id < SLOTS) &&
                              slot_active[block_slot_id[SLOT_W-1:0]];
        selected_token_match = 1'b0;
        selected_block_match = 1'b0;
        expected_lane_valid = '0;
        selected_lane_match = 1'b0;
        selected_is_last = 1'b0;

        if (selected_slot_valid) begin
            selected_token_match =
                block_epoch == slot_epoch[block_slot_id[SLOT_W-1:0]] &&
                block_group == slot_group[block_slot_id[SLOT_W-1:0]] &&
                block_global_q_head == slot_head[block_slot_id[SLOT_W-1:0]] &&
                block_row == slot_row[block_slot_id[SLOT_W-1:0]] &&
                block_numeric_mode == slot_mode[block_slot_id[SLOT_W-1:0]];
            selected_block_match =
                block_key_block == slot_next_block[block_slot_id[SLOT_W-1:0]];
            selected_is_last =
                block_key_block == (block_row / LANES);
        end

        for (lane = 0; lane < LANES; lane = lane + 1) begin
            if ((block_key_block * LANES + lane) <= block_row &&
                (block_key_block * LANES + lane) < SEQ_LEN)
                expected_lane_valid[lane] = 1'b1;
        end
        selected_lane_match = block_lane_valid == expected_lane_valid;

        block_has_finite = 1'b0;
        block_has_nonfinite = 1'b0;
        block_max = 16'b0;
        lane_count = 8'b0;
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            if (block_lane_valid[lane]) begin
                lane_count = lane_count + 1'b1;
                if (!bf16_is_finite(block_score_bf16[lane*16 +: 16])) begin
                    block_has_nonfinite = 1'b1;
                end else if (!block_has_finite ||
                             bf16_gt(block_score_bf16[lane*16 +: 16], block_max)) begin
                    block_has_finite = 1'b1;
                    block_max = block_score_bf16[lane*16 +: 16];
                end
            end
        end

        completed_max = block_max;
        if (selected_slot_valid &&
            slot_max_valid[block_slot_id[SLOT_W-1:0]] &&
            (!block_has_finite ||
             bf16_gt(slot_max[block_slot_id[SLOT_W-1:0]], block_max)))
            completed_max = slot_max[block_slot_id[SLOT_W-1:0]];

        selected_legal = txn_active && selected_slot_valid &&
                         selected_token_match && selected_block_match &&
                         selected_lane_match && block_has_finite &&
                         !block_has_nonfinite;

        store_wr_valid = block_valid && selected_legal &&
                         (!selected_is_last || !row_valid || row_ready);
        store_wr_slot_id = block_slot_id;
        store_wr_key_base = block_key_block * LANES;
        store_wr_lane_valid = block_lane_valid;
        store_wr_score_bf16 = block_score_bf16;
        block_ready = selected_legal && store_wr_ready &&
                      (!selected_is_last || !row_valid || row_ready);

        txn_start_ready = !txn_active;
        row_open_ready = txn_active && (row_open_slot_id < SLOTS) &&
                         !slot_active[row_open_slot_id[SLOT_W-1:0]] &&
                         row_open_epoch == active_epoch &&
                         row_open_numeric_mode == active_numeric_mode &&
                         row_open_row < SEQ_LEN;
    end

    always_ff @(posedge clk) begin
        if (!rst_n || clear) begin
            txn_active <= 1'b0;
            active_epoch <= '0;
            active_numeric_mode <= '0;
            row_valid <= 1'b0;
            abort_valid <= 1'b0;
            row_epoch <= '0;
            row_group <= '0;
            row_global_q_head <= '0;
            row_index <= '0;
            row_slot_id <= '0;
            row_numeric_mode <= '0;
            row_max_bf16 <= '0;
            abort_epoch <= '0;
            abort_group <= '0;
            abort_global_q_head <= '0;
            abort_row <= '0;
            abort_slot_id <= '0;
            abort_numeric_mode <= '0;
            abort_error_code <= '0;
            abort_error_key <= '0;
            protocol_error_sticky <= 1'b0;
            for (i = 0; i < SLOTS; i = i + 1) begin
                slot_active[i] <= 1'b0;
                slot_epoch[i] <= '0;
                slot_group[i] <= '0;
                slot_head[i] <= '0;
                slot_row[i] <= '0;
                slot_mode[i] <= '0;
                slot_next_block[i] <= '0;
                slot_max_valid[i] <= 1'b0;
                slot_max[i] <= '0;
            end
        end else begin
            if (txn_start_valid && txn_start_ready) begin
                txn_active <= 1'b1;
                active_epoch <= txn_epoch;
                active_numeric_mode <= txn_numeric_mode;
            end

            if (row_valid && row_ready)
                row_valid <= 1'b0;
            if (abort_valid && abort_ready)
                abort_valid <= 1'b0;

            if (row_open_valid && row_open_ready) begin
                slot_active[row_open_slot_id[SLOT_W-1:0]] <= 1'b1;
                slot_epoch[row_open_slot_id[SLOT_W-1:0]] <= row_open_epoch;
                slot_group[row_open_slot_id[SLOT_W-1:0]] <= row_open_group;
                slot_head[row_open_slot_id[SLOT_W-1:0]] <= row_open_global_q_head;
                slot_row[row_open_slot_id[SLOT_W-1:0]] <= row_open_row;
                slot_mode[row_open_slot_id[SLOT_W-1:0]] <= row_open_numeric_mode;
                slot_next_block[row_open_slot_id[SLOT_W-1:0]] <= '0;
                slot_max_valid[row_open_slot_id[SLOT_W-1:0]] <= 1'b0;
                slot_max[row_open_slot_id[SLOT_W-1:0]] <= '0;
            end

            if (block_valid && block_ready) begin
                slot_max_valid[block_slot_id[SLOT_W-1:0]] <= 1'b1;
                slot_max[block_slot_id[SLOT_W-1:0]] <= completed_max;
                if (selected_is_last) begin
                    slot_active[block_slot_id[SLOT_W-1:0]] <= 1'b0;
                    row_valid <= 1'b1;
                    row_epoch <= slot_epoch[block_slot_id[SLOT_W-1:0]];
                    row_group <= slot_group[block_slot_id[SLOT_W-1:0]];
                    row_global_q_head <= slot_head[block_slot_id[SLOT_W-1:0]];
                    row_index <= slot_row[block_slot_id[SLOT_W-1:0]];
                    row_slot_id <= block_slot_id;
                    row_numeric_mode <= slot_mode[block_slot_id[SLOT_W-1:0]];
                    row_max_bf16 <= completed_max;
                end else begin
                    slot_next_block[block_slot_id[SLOT_W-1:0]] <=
                        slot_next_block[block_slot_id[SLOT_W-1:0]] + 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || counter_clear) begin
            rows_opened <= 0;
            blocks_accepted <= 0;
            scores_accepted <= 0;
            rows_completed <= 0;
            protocol_errors <= 0;
            numeric_errors <= 0;
            mode_errors <= 0;
        end else if (!clear) begin
            if (row_open_valid && row_open_ready)
                rows_opened <= rows_opened + 1'b1;
            if (block_valid && block_ready) begin
                blocks_accepted <= blocks_accepted + 1'b1;
                scores_accepted <= scores_accepted + lane_count;
                if (selected_is_last)
                    rows_completed <= rows_completed + 1'b1;
            end
        end
    end
endmodule
