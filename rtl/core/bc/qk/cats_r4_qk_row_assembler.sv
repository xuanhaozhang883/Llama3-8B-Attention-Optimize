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

    localparam logic [1:0] MAX_PREP_IDLE  = 2'd0;
    localparam logic [1:0] MAX_PREP_L2    = 2'd1;
    localparam logic [1:0] MAX_PREP_READY = 2'd2;
    logic [1:0] max_prep_state;
    logic [15:0] prep_epoch;
    logic [2:0] prep_group;
    logic [4:0] prep_global_q_head;
    logic [6:0] prep_row;
    logic [1:0] prep_slot_id;
    logic [1:0] prep_numeric_mode;
    logic [1:0] prep_key_block;
    logic [LANES-1:0] prep_lane_valid;
    logic [LANES*16-1:0] prep_score_bf16;
    logic prep_has_nonfinite;
    logic [7:0] prep_lane_count;
    logic [7:0] input_lane_count;
    logic [16:0] prep_max_l2 [0:7];
    logic [16:0] prep_max_l4 [0:1];
    logic [16:0] prep_max_l3_comb [0:3];
    logic [16:0] prep_max_l4_comb [0:1];
    logic [16:0] prep_max_l5;

    // Bit 16 is the valid flag and bits 15:0 carry the BF16 value.  The
    // fixed-width tree keeps the production 32-lane critical path at five
    // comparisons while the inactive leaves preserve smaller LANES builds.
    logic [16:0] max_tree_l0 [0:31];
    logic [16:0] max_tree_l1 [0:15];
    logic [16:0] max_tree_l2 [0:7];
    logic [16:0] max_tree_l3 [0:3];
    logic [16:0] max_tree_l4 [0:1];
    logic [16:0] max_tree_l5;
    logic [31:0] nonfinite_leaves;

    integer i;
    integer lane;
    integer count_lane;

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

    function automatic logic [16:0] bf16_max_left(
        input logic [16:0] lhs,
        input logic [16:0] rhs
    );
        begin
            if (!lhs[16])
                bf16_max_left = rhs;
            else if (rhs[16] && bf16_gt(rhs[15:0], lhs[15:0]))
                bf16_max_left = rhs;
            else
                bf16_max_left = lhs;
        end
    endfunction

    genvar max_lane;
    generate
        for (max_lane = 0; max_lane < 32; max_lane = max_lane + 1) begin : g_max_leaf
            if (max_lane < LANES) begin : g_active
                assign max_tree_l0[max_lane] =
                    block_lane_valid[max_lane] &&
                    bf16_is_finite(block_score_bf16[max_lane*16 +: 16]) ?
                    {1'b1, block_score_bf16[max_lane*16 +: 16]} : 17'b0;
                assign nonfinite_leaves[max_lane] =
                    block_lane_valid[max_lane] &&
                    !bf16_is_finite(block_score_bf16[max_lane*16 +: 16]);
            end else begin : g_inactive
                assign max_tree_l0[max_lane] = 17'b0;
                assign nonfinite_leaves[max_lane] = 1'b0;
            end
        end
        for (max_lane = 0; max_lane < 16; max_lane = max_lane + 1)
            assign max_tree_l1[max_lane] =
                bf16_max_left(max_tree_l0[2*max_lane], max_tree_l0[2*max_lane+1]);
        for (max_lane = 0; max_lane < 8; max_lane = max_lane + 1)
            assign max_tree_l2[max_lane] =
                bf16_max_left(max_tree_l1[2*max_lane], max_tree_l1[2*max_lane+1]);
        for (max_lane = 0; max_lane < 4; max_lane = max_lane + 1)
            assign max_tree_l3[max_lane] =
                bf16_max_left(max_tree_l2[2*max_lane], max_tree_l2[2*max_lane+1]);
        for (max_lane = 0; max_lane < 2; max_lane = max_lane + 1)
            assign max_tree_l4[max_lane] =
                bf16_max_left(max_tree_l3[2*max_lane], max_tree_l3[2*max_lane+1]);
    endgenerate

    assign max_tree_l5 = bf16_max_left(max_tree_l4[0], max_tree_l4[1]);
    generate
        for (max_lane = 0; max_lane < 4; max_lane = max_lane + 1)
            assign prep_max_l3_comb[max_lane] =
                bf16_max_left(prep_max_l2[2*max_lane], prep_max_l2[2*max_lane+1]);
        for (max_lane = 0; max_lane < 2; max_lane = max_lane + 1)
            assign prep_max_l4_comb[max_lane] =
                bf16_max_left(prep_max_l3_comb[2*max_lane], prep_max_l3_comb[2*max_lane+1]);
    endgenerate

    assign prep_max_l5 = bf16_max_left(prep_max_l4[0], prep_max_l4[1]);
    assign block_has_finite = prep_max_l5[16];
    assign block_max = prep_max_l5[15:0];
    assign block_has_nonfinite = prep_has_nonfinite;
    assign lane_count = prep_lane_count;

    always_comb begin
        input_lane_count = 0;
        for (count_lane = 0; count_lane < LANES; count_lane = count_lane + 1)
            input_lane_count = input_lane_count + block_lane_valid[count_lane];
    end

    always_comb begin
        selected_slot_valid = 1'b0;
        if (prep_slot_id < SLOTS)
            selected_slot_valid = slot_active[prep_slot_id[SLOT_W-1:0]];
        selected_token_match = 1'b0;
        selected_block_match = 1'b0;
        expected_lane_valid = '0;
        selected_lane_match = 1'b0;
        selected_is_last = 1'b0;

        if (selected_slot_valid) begin
            selected_token_match =
                prep_epoch == slot_epoch[prep_slot_id[SLOT_W-1:0]] &&
                prep_group == slot_group[prep_slot_id[SLOT_W-1:0]] &&
                prep_global_q_head == slot_head[prep_slot_id[SLOT_W-1:0]] &&
                prep_row == slot_row[prep_slot_id[SLOT_W-1:0]] &&
                prep_numeric_mode == slot_mode[prep_slot_id[SLOT_W-1:0]];
            selected_block_match =
                prep_key_block == slot_next_block[prep_slot_id[SLOT_W-1:0]];
            selected_is_last =
                prep_key_block == (prep_row / LANES);
        end

        for (lane = 0; lane < LANES; lane = lane + 1) begin
            if ((prep_key_block * LANES + lane) <= prep_row &&
                (prep_key_block * LANES + lane) < SEQ_LEN)
                expected_lane_valid[lane] = 1'b1;
        end
        selected_lane_match = prep_lane_valid == expected_lane_valid;

        completed_max = block_max;
        if (selected_slot_valid &&
            slot_max_valid[prep_slot_id[SLOT_W-1:0]] &&
            (!block_has_finite ||
             bf16_gt(slot_max[prep_slot_id[SLOT_W-1:0]], block_max)))
            completed_max = slot_max[prep_slot_id[SLOT_W-1:0]];

        selected_legal = txn_active && selected_slot_valid &&
                         selected_token_match && selected_block_match &&
                         selected_lane_match && block_has_finite &&
                         !block_has_nonfinite;

        store_wr_valid = block_valid && (max_prep_state == MAX_PREP_READY) &&
                         selected_legal &&
                         (!selected_is_last || !row_valid || row_ready);
        store_wr_slot_id = prep_slot_id;
        store_wr_key_base = prep_key_block * LANES;
        store_wr_lane_valid = prep_lane_valid;
        store_wr_score_bf16 = prep_score_bf16;
        block_ready = 1'b0;
        if (block_valid && (max_prep_state == MAX_PREP_READY) && selected_legal)
            block_ready = store_wr_ready &&
                          (!selected_is_last || !row_valid || row_ready);
        else if (block_valid && (max_prep_state == MAX_PREP_READY))
            block_ready = selected_slot_valid &&
                          (!abort_valid || abort_ready);

        txn_start_ready = !txn_active;
        row_open_ready = txn_active && (row_open_slot_id < SLOTS) &&
                         !slot_active[row_open_slot_id[SLOT_W-1:0]] &&
                         row_open_epoch == active_epoch &&
                         row_open_row < SEQ_LEN &&
                         (!abort_valid || abort_ready);
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
            max_prep_state <= MAX_PREP_IDLE;
            prep_epoch <= '0;
            prep_group <= '0;
            prep_global_q_head <= '0;
            prep_row <= '0;
            prep_slot_id <= '0;
            prep_numeric_mode <= '0;
            prep_key_block <= '0;
            prep_lane_valid <= '0;
            prep_score_bf16 <= '0;
            prep_has_nonfinite <= 1'b0;
            prep_lane_count <= '0;
            for (i = 0; i < 8; i = i + 1)
                prep_max_l2[i] <= '0;
            for (i = 0; i < 2; i = i + 1)
                prep_max_l4[i] <= '0;
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
            case (max_prep_state)
                MAX_PREP_IDLE: begin
                    if (block_valid) begin
                        prep_epoch <= block_epoch;
                        prep_group <= block_group;
                        prep_global_q_head <= block_global_q_head;
                        prep_row <= block_row;
                        prep_slot_id <= block_slot_id;
                        prep_numeric_mode <= block_numeric_mode;
                        prep_key_block <= block_key_block;
                        prep_lane_valid <= block_lane_valid;
                        prep_score_bf16 <= block_score_bf16;
                        prep_has_nonfinite <= |nonfinite_leaves;
                        prep_lane_count <= input_lane_count;
                        for (i = 0; i < 8; i = i + 1)
                            prep_max_l2[i] <= max_tree_l2[i];
                        max_prep_state <= MAX_PREP_L2;
                    end
                end
                MAX_PREP_L2: begin
                    if (!block_valid)
                        max_prep_state <= MAX_PREP_IDLE;
                    else begin
                        for (i = 0; i < 2; i = i + 1)
                            prep_max_l4[i] <= prep_max_l4_comb[i];
                        max_prep_state <= MAX_PREP_READY;
                    end
                end
                default: begin
                    if (!block_valid || block_ready)
                        max_prep_state <= MAX_PREP_IDLE;
                end
            endcase

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
                if (row_open_numeric_mode != active_numeric_mode) begin
                    abort_valid <= 1'b1;
                    abort_epoch <= row_open_epoch;
                    abort_group <= row_open_group;
                    abort_global_q_head <= row_open_global_q_head;
                    abort_row <= row_open_row;
                    abort_slot_id <= row_open_slot_id;
                    abort_numeric_mode <= row_open_numeric_mode;
                    abort_error_code <= 3'd3;
                    abort_error_key <= 0;
                    protocol_error_sticky <= 1'b1;
                end else begin
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
            end

            if (block_valid && block_ready && selected_legal) begin
                slot_max_valid[prep_slot_id[SLOT_W-1:0]] <= 1'b1;
                slot_max[prep_slot_id[SLOT_W-1:0]] <= completed_max;
                if (selected_is_last) begin
                    slot_active[prep_slot_id[SLOT_W-1:0]] <= 1'b0;
                    row_valid <= 1'b1;
                    row_epoch <= slot_epoch[prep_slot_id[SLOT_W-1:0]];
                    row_group <= slot_group[prep_slot_id[SLOT_W-1:0]];
                    row_global_q_head <= slot_head[prep_slot_id[SLOT_W-1:0]];
                    row_index <= slot_row[prep_slot_id[SLOT_W-1:0]];
                    row_slot_id <= prep_slot_id;
                    row_numeric_mode <= slot_mode[prep_slot_id[SLOT_W-1:0]];
                    row_max_bf16 <= completed_max;
                end else begin
                    slot_next_block[prep_slot_id[SLOT_W-1:0]] <=
                        slot_next_block[prep_slot_id[SLOT_W-1:0]] + 1'b1;
                end
            end else if (block_valid && block_ready) begin
                slot_active[prep_slot_id[SLOT_W-1:0]] <= 1'b0;
                abort_valid <= 1'b1;
                abort_epoch <= prep_epoch;
                abort_group <= prep_group;
                abort_global_q_head <= prep_global_q_head;
                abort_row <= prep_row;
                abort_slot_id <= prep_slot_id;
                abort_numeric_mode <= prep_numeric_mode;
                abort_error_code <= (!selected_token_match ||
                                     !selected_block_match ||
                                     !selected_lane_match) ? 3'd1 : 3'd2;
                abort_error_key <= prep_key_block * LANES;
                if (!selected_token_match || !selected_block_match ||
                    !selected_lane_match)
                    protocol_error_sticky <= 1'b1;
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
            if (row_open_valid && row_open_ready &&
                row_open_numeric_mode == active_numeric_mode)
                rows_opened <= rows_opened + 1'b1;
            if (row_open_valid && row_open_ready &&
                row_open_numeric_mode != active_numeric_mode)
                mode_errors <= mode_errors + 1'b1;
            if (block_valid && block_ready && selected_legal) begin
                blocks_accepted <= blocks_accepted + 1'b1;
                scores_accepted <= scores_accepted + lane_count;
                if (selected_is_last)
                    rows_completed <= rows_completed + 1'b1;
            end
            if (block_valid && block_ready && !selected_legal) begin
                if (!selected_token_match || !selected_block_match ||
                    !selected_lane_match)
                    protocol_errors <= protocol_errors + 1'b1;
                else
                    numeric_errors <= numeric_errors + 1'b1;
            end
        end
    end
endmodule
