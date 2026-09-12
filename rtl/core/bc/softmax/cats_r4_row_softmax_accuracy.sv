`timescale 1ns/1ps

// CATS-R4 B2 whole-row Accuracy arithmetic checkpoint.
//
// Up to three V3 score slots may be active.  Each score passes through the
// fixed exp operator, is staged as FP32 weight, and is accumulated strictly in
// key order by the positive FP32 adder.  The last sum enters the bounded FP32
// reciprocal.  This module does not publish to C directly; scheme-A staging is
// provided by cats_r4_b2_accuracy_v3_wrapper.
module cats_r4_row_softmax_accuracy (
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

    output logic        weight_valid,
    input  logic        weight_ready,
    output logic [15:0] weight_epoch,
    output logic [2:0]  weight_group,
    output logic [4:0]  weight_global_q_head,
    output logic [6:0]  weight_row,
    output logic [1:0]  weight_slot_id,
    output logic [1:0]  weight_numeric_mode,
    output logic [6:0]  weight_key,
    output logic [31:0] weight_fp32,
    output logic        weight_last,

    output logic        done_valid,
    input  logic        done_ready,
    output logic [15:0] done_epoch,
    output logic [2:0]  done_group,
    output logic [4:0]  done_global_q_head,
    output logic [6:0]  done_row,
    output logic [1:0]  done_slot_id,
    output logic [1:0]  done_numeric_mode,
    output logic [31:0] done_sum_fp32,
    output logic [31:0] done_inv_sum_fp32,
    output logic        done_error,
    output logic [3:0]  done_error_code,
    output logic [6:0]  done_bad_key,

    output logic [63:0] rows_issue,
    output logic [63:0] rows_result,
    output logic [63:0] rows_commit,
    output logic [63:0] exp_issue,
    output logic [63:0] exp_result,
    output logic [63:0] exp_commit,
    output logic [63:0] sum_issue,
    output logic [63:0] sum_result,
    output logic [63:0] sum_commit,
    output logic [63:0] reciprocal_issue,
    output logic [63:0] reciprocal_result,
    output logic [63:0] reciprocal_commit,
    output logic [63:0] protocol_error_count,
    output logic [63:0] numeric_error_count,
    output logic [63:0] exp_stall_cycles,
    output logic [63:0] sum_stall_cycles,
    output logic [63:0] reciprocal_busy_stall_cycles,
    output logic [63:0] reciprocal_output_stall_cycles,
    output logic        error_sticky
);
    localparam int TOKEN_META_W = 43;
    localparam int PATH_META_W = 44;
    localparam int RECIP_META_W = 76;
    localparam int META_LAST = 0;
    localparam int META_KEY_LSB = 1;
    localparam int META_MODE_LSB = 8;
    localparam int META_SLOT_LSB = 10;
    localparam int META_ROW_LSB = 12;
    localparam int META_HEAD_LSB = 19;
    localparam int META_GROUP_LSB = 24;
    localparam int META_EPOCH_LSB = 27;

    logic [2:0] slot_active;
    logic [2:0] slot_closing;
    logic [2:0] slot_error;
    logic [15:0] slot_epoch [0:2];
    logic [2:0] slot_group [0:2];
    logic [4:0] slot_head [0:2];
    logic [6:0] slot_row [0:2];
    logic [1:0] slot_mode [0:2];
    logic [15:0] slot_max [0:2];
    logic [6:0] slot_expected_key [0:2];
    logic [31:0] slot_sum [0:2];
    logic [3:0] slot_error_code [0:2];
    logic [6:0] slot_bad_key [0:2];

    logic row_fire;
    logic row_shape_legal;
    logic score_fire;
    logic score_slot_available;
    logic score_token_legal;
    logic score_key_legal;
    logic score_last_legal;
    logic score_transfer_legal;
    logic score_internal_last;
    logic row_slot_free;
    logic [1:0] score_array_slot;

    logic exp_in_valid;
    logic exp_in_ready;
    logic [TOKEN_META_W-1:0] exp_in_meta;
    logic exp_out_valid;
    logic exp_out_ready;
    logic [31:0] exp_out_weight;
    logic exp_out_error;
    logic [TOKEN_META_W-1:0] exp_out_meta;
    logic [63:0] exp_numeric_errors;
    logic fork_weight_sent;
    logic fork_add_sent;
    logic weight_fire;
    logic add_input_fire;
    logic exp_output_fire;

    logic add_in_valid;
    logic add_in_ready;
    logic [31:0] add_in_accumulator;
    logic [PATH_META_W-1:0] add_in_meta;
    logic add_out_valid;
    logic add_out_ready;
    logic [31:0] add_out_sum;
    logic add_out_error;
    logic [PATH_META_W-1:0] add_out_meta;
    logic add_out_fire;
    logic [63:0] add_numeric_errors;

    logic reciprocal_in_valid;
    logic reciprocal_in_ready;
    logic [RECIP_META_W-1:0] reciprocal_in_meta;
    logic reciprocal_out_valid;
    logic reciprocal_out_ready;
    logic [31:0] reciprocal_out_data;
    logic reciprocal_out_error;
    logic [RECIP_META_W-1:0] reciprocal_out_meta;
    logic [63:0] reciprocal_numeric_errors;
    logic [63:0] row_numeric_errors;

    logic [1:0] exp_slot;
    logic [1:0] add_slot;
    logic [1:0] done_slot;
    logic add_is_last;
    logic add_bypass_same_slot;

    function automatic logic [TOKEN_META_W-1:0] pack_token_meta(
        input logic [15:0] epoch,
        input logic [2:0] group,
        input logic [4:0] head,
        input logic [6:0] row,
        input logic [1:0] slot_id,
        input logic [1:0] mode,
        input logic [6:0] key,
        input logic last
    );
        begin
            pack_token_meta = {epoch,group,head,row,slot_id,mode,key,last};
        end
    endfunction

    always_comb begin
        row_slot_free = 1'b0;
        if (row_slot_id < 3)
            row_slot_free = !slot_active[row_slot_id];

        score_array_slot = score_slot_id < 3 ? score_slot_id : 2'd0;
        score_slot_available = 1'b0;
        if (score_slot_id < 3)
            score_slot_available = slot_active[score_array_slot] &&
                                   !slot_closing[score_array_slot];

        score_internal_last = 1'b0;
        score_token_legal = 1'b0;
        score_key_legal = 1'b0;
        score_last_legal = 1'b0;
        if (score_slot_available) begin
            score_internal_last =
                slot_expected_key[score_array_slot] == slot_row[score_array_slot];
            score_token_legal =
                score_epoch == slot_epoch[score_array_slot] &&
                score_group == slot_group[score_array_slot] &&
                score_global_q_head == slot_head[score_array_slot] &&
                score_row == slot_row[score_array_slot] &&
                score_numeric_mode == slot_mode[score_array_slot];
            score_key_legal =
                score_key == slot_expected_key[score_array_slot];
            score_last_legal = score_last == score_internal_last;
        end
    end

    assign row_shape_legal = row_slot_id < 3 &&
                             row_group == row_global_q_head[4:2] &&
                             row_numeric_mode == 2'd1;
    assign row_ready = row_shape_legal && row_slot_free && !clear;
    assign row_fire = row_valid && row_ready;

    assign score_ready = score_slot_available && exp_in_ready && !clear;
    assign score_fire = score_valid && score_ready;
    assign score_transfer_legal = score_token_legal && score_key_legal &&
                                  score_last_legal;

    assign exp_in_valid = score_valid && score_slot_available;
    assign exp_in_meta = pack_token_meta(
        slot_epoch[score_array_slot],
        slot_group[score_array_slot],
        slot_head[score_array_slot],
        slot_row[score_array_slot],
        score_array_slot,
        slot_mode[score_array_slot],
        slot_expected_key[score_array_slot],
        score_internal_last
    );

    cats_r4_accuracy_exp_fixed #(.META_W(TOKEN_META_W)) u_exp (
        .clk,
        .rst_n,
        .clear,
        .counter_clear,
        .in_valid(exp_in_valid),
        .in_ready(exp_in_ready),
        .in_row_max_bf16(slot_max[score_array_slot]),
        .in_score_bf16(score_bf16),
        .in_meta(exp_in_meta),
        .out_valid(exp_out_valid),
        .out_ready(exp_out_ready),
        .out_weight_fp32(exp_out_weight),
        .out_numeric_error(exp_out_error),
        .out_meta(exp_out_meta),
        .exp_issue,
        .exp_result,
        .exp_commit,
        .numeric_error_count(exp_numeric_errors),
        .output_stall_cycles(exp_stall_cycles)
    );

    assign exp_slot = exp_out_meta[META_SLOT_LSB +: 2];
    assign weight_valid = exp_out_valid && !fork_weight_sent;
    assign weight_epoch = exp_out_meta[META_EPOCH_LSB +: 16];
    assign weight_group = exp_out_meta[META_GROUP_LSB +: 3];
    assign weight_global_q_head = exp_out_meta[META_HEAD_LSB +: 5];
    assign weight_row = exp_out_meta[META_ROW_LSB +: 7];
    assign weight_slot_id = exp_slot;
    assign weight_numeric_mode = exp_out_meta[META_MODE_LSB +: 2];
    assign weight_key = exp_out_meta[META_KEY_LSB +: 7];
    assign weight_fp32 = exp_out_weight;
    assign weight_last = exp_out_meta[META_LAST];
    assign weight_fire = weight_valid && weight_ready;

    assign add_in_valid = exp_out_valid && !fork_add_sent &&
                          (fork_weight_sent || weight_ready);
    assign add_input_fire = add_in_valid && add_in_ready;
    assign exp_out_ready =
        (fork_weight_sent || weight_ready) &&
        (fork_add_sent || add_in_ready);
    assign exp_output_fire = exp_out_valid && exp_out_ready;

    assign add_slot = add_out_meta[META_SLOT_LSB +: 2];
    assign add_is_last = add_out_meta[META_LAST];
    // A stalled result already owns u_sum's elastic output, so in_ready is low
    // and the speculative accumulator value cannot be accepted.  Basing the
    // RAW bypass only on the registered result identity therefore preserves
    // behavior while keeping reciprocal ready/clear out of the FP32 add data
    // path.  When the result is accepted, this is the required same-cycle
    // forwarding path for the next key of that slot.
    assign add_bypass_same_slot = add_out_valid && add_slot == exp_slot;
    assign add_in_accumulator = add_bypass_same_slot ? add_out_sum :
                                 slot_sum[exp_slot];
    assign add_in_meta = {exp_out_error,exp_out_meta};

    cats_r4_fp32_positive_add #(.META_W(PATH_META_W)) u_sum (
        .clk,
        .rst_n,
        .clear,
        .counter_clear,
        .in_valid(add_in_valid),
        .in_ready(add_in_ready),
        .in_a_fp32(add_in_accumulator),
        .in_b_fp32(exp_out_weight),
        .in_meta(add_in_meta),
        .out_valid(add_out_valid),
        .out_ready(add_out_ready),
        .out_sum_fp32(add_out_sum),
        .out_numeric_error(add_out_error),
        .out_meta(add_out_meta),
        .add_issue(sum_issue),
        .add_result(sum_result),
        .add_commit(sum_commit),
        .numeric_error_count(add_numeric_errors),
        .output_stall_cycles(sum_stall_cycles)
    );

    assign reciprocal_in_valid = add_out_valid && add_is_last;
    assign add_out_ready = !add_is_last || reciprocal_in_ready;
    assign add_out_fire = add_out_valid && add_out_ready;
    assign reciprocal_in_meta = {
        add_out_meta[PATH_META_W-1] || add_out_error,
        add_out_sum,
        add_out_meta[TOKEN_META_W-1:0]
    };

    cats_r4_fp32_row_reciprocal #(.META_W(RECIP_META_W)) u_reciprocal (
        .clk,
        .rst_n,
        .clear,
        .counter_clear,
        .in_valid(reciprocal_in_valid),
        .in_ready(reciprocal_in_ready),
        .in_sum_fp32(add_out_sum),
        .in_meta(reciprocal_in_meta),
        .out_valid(reciprocal_out_valid),
        .out_ready(reciprocal_out_ready),
        .out_inv_sum_fp32(reciprocal_out_data),
        .out_numeric_error(reciprocal_out_error),
        .out_meta(reciprocal_out_meta),
        .reciprocal_issue,
        .reciprocal_result,
        .reciprocal_commit,
        .numeric_error_count(reciprocal_numeric_errors),
        .busy_stall_cycles(reciprocal_busy_stall_cycles),
        .output_stall_cycles(reciprocal_output_stall_cycles)
    );

    assign done_valid = reciprocal_out_valid;
    assign reciprocal_out_ready = done_ready;
    assign done_epoch = reciprocal_out_meta[META_EPOCH_LSB +: 16];
    assign done_group = reciprocal_out_meta[META_GROUP_LSB +: 3];
    assign done_global_q_head = reciprocal_out_meta[META_HEAD_LSB +: 5];
    assign done_row = reciprocal_out_meta[META_ROW_LSB +: 7];
    assign done_slot_id = reciprocal_out_meta[META_SLOT_LSB +: 2];
    assign done_numeric_mode = reciprocal_out_meta[META_MODE_LSB +: 2];
    assign done_sum_fp32 = reciprocal_out_meta[TOKEN_META_W +: 32];
    assign done_inv_sum_fp32 = reciprocal_out_data;
    assign done_slot = done_slot_id;
    assign done_error = reciprocal_out_meta[RECIP_META_W-1] ||
                        reciprocal_out_error || slot_error[done_slot];
    assign done_error_code = slot_error[done_slot] ?
                             slot_error_code[done_slot] :
                             (reciprocal_out_meta[RECIP_META_W-1] ? 4'h2 :
                              (reciprocal_out_error ? 4'h4 : 4'h0));
    assign done_bad_key = slot_bad_key[done_slot];

    assign rows_result = reciprocal_result;
    assign rows_commit = reciprocal_commit;
    assign numeric_error_count = row_numeric_errors + exp_numeric_errors +
                                 add_numeric_errors + reciprocal_numeric_errors;

    always_ff @(posedge clk or negedge rst_n) begin : p_state
        integer slot;
        if (!rst_n) begin
            slot_active <= 0;
            slot_closing <= 0;
            slot_error <= 0;
            fork_weight_sent <= 1'b0;
            fork_add_sent <= 1'b0;
            rows_issue <= 0;
            protocol_error_count <= 0;
            row_numeric_errors <= 0;
            error_sticky <= 1'b0;
            for (slot = 0; slot < 3; slot = slot+1) begin
                slot_epoch[slot] <= 0;
                slot_group[slot] <= 0;
                slot_head[slot] <= 0;
                slot_row[slot] <= 0;
                slot_mode[slot] <= 0;
                slot_max[slot] <= 0;
                slot_expected_key[slot] <= 0;
                slot_sum[slot] <= 0;
                slot_error_code[slot] <= 0;
                slot_bad_key[slot] <= 0;
            end
        end else if (clear) begin
            slot_active <= 0;
            slot_closing <= 0;
            slot_error <= 0;
            fork_weight_sent <= 1'b0;
            fork_add_sent <= 1'b0;
            error_sticky <= 1'b0;
            for (slot = 0; slot < 3; slot = slot+1) begin
                slot_expected_key[slot] <= 0;
                slot_sum[slot] <= 0;
                slot_error_code[slot] <= 0;
                slot_bad_key[slot] <= 0;
            end
        end else begin
            if (exp_output_fire) begin
                fork_weight_sent <= 1'b0;
                fork_add_sent <= 1'b0;
            end else begin
                if (weight_fire)
                    fork_weight_sent <= 1'b1;
                if (add_input_fire)
                    fork_add_sent <= 1'b1;
            end

            if (row_fire) begin
                slot_active[row_slot_id] <= 1'b1;
                slot_closing[row_slot_id] <= 1'b0;
                slot_error[row_slot_id] <=
                    row_max_bf16[14:7] == 8'hff;
                slot_epoch[row_slot_id] <= row_epoch;
                slot_group[row_slot_id] <= row_group;
                slot_head[row_slot_id] <= row_global_q_head;
                slot_row[row_slot_id] <= row_index;
                slot_mode[row_slot_id] <= row_numeric_mode;
                slot_max[row_slot_id] <= row_max_bf16;
                slot_expected_key[row_slot_id] <= 0;
                slot_sum[row_slot_id] <= 0;
                slot_error_code[row_slot_id] <=
                    row_max_bf16[14:7] == 8'hff ? 4'h2 : 4'h0;
                slot_bad_key[row_slot_id] <= 0;
                if (row_max_bf16[14:7] == 8'hff)
                    error_sticky <= 1'b1;
            end

            if (score_fire) begin
                if (score_internal_last)
                    slot_closing[score_slot_id] <= 1'b1;
                else
                    slot_expected_key[score_slot_id] <=
                        slot_expected_key[score_slot_id]+1'b1;
                if (!score_transfer_legal) begin
                    slot_error[score_slot_id] <= 1'b1;
                    if (slot_error_code[score_slot_id] == 0)
                        slot_error_code[score_slot_id] <= 4'h1;
                    slot_bad_key[score_slot_id] <= score_key;
                    error_sticky <= 1'b1;
                end
            end

            if (exp_output_fire && exp_out_error) begin
                slot_error[exp_slot] <= 1'b1;
                if (slot_error_code[exp_slot] == 0)
                    slot_error_code[exp_slot] <= 4'h2;
                slot_bad_key[exp_slot] <=
                    exp_out_meta[META_KEY_LSB +: 7];
                error_sticky <= 1'b1;
            end

            if (add_out_fire) begin
                slot_sum[add_slot] <= add_out_sum;
                if (add_out_error || add_out_meta[PATH_META_W-1]) begin
                    slot_error[add_slot] <= 1'b1;
                    if (slot_error_code[add_slot] == 0)
                        slot_error_code[add_slot] <= 4'h2;
                    slot_bad_key[add_slot] <=
                        add_out_meta[META_KEY_LSB +: 7];
                    error_sticky <= 1'b1;
                end
            end

            if (done_valid && done_ready) begin
                slot_active[done_slot] <= 1'b0;
                slot_closing[done_slot] <= 1'b0;
                slot_error[done_slot] <= 1'b0;
                slot_error_code[done_slot] <= 0;
                slot_bad_key[done_slot] <= 0;
            end

            if (counter_clear) begin
                rows_issue <= 0;
                protocol_error_count <= 0;
                row_numeric_errors <= 0;
                error_sticky <= 1'b0;
            end else begin
                if (row_fire) begin
                    rows_issue <= rows_issue+1'b1;
                    if (row_max_bf16[14:7] == 8'hff)
                        row_numeric_errors <= row_numeric_errors+1'b1;
                end
                if (score_fire && !score_transfer_legal)
                    protocol_error_count <= protocol_error_count+1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && !clear) begin
            if (row_fire && row_numeric_mode != 2'd1)
                $fatal(1, "Accuracy core accepted a non-Accuracy row");
            if (weight_valid && weight_ready && weight_numeric_mode != 2'd1)
                $fatal(1, "Accuracy core emitted a non-Accuracy weight");
            if (done_valid && done_ready && done_numeric_mode != 2'd1)
                $fatal(1, "Accuracy core emitted a non-Accuracy completion");
        end
    end
`endif
endmodule
