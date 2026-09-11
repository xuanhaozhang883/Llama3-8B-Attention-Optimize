`timescale 1ns/1ps

// CATS-R4 B2 three-slot whole-row weight staging and V3 publication.
//
// This module is deliberately arithmetic-agnostic.  A Compatibility or
// Accuracy engine first supplies every valid causal weight (key=0..row), then
// finalizes the row with validated FP32 sum/reciprocal metadata.  Only a
// successful finalize makes the row eligible for the public B->C transfer.
// Masked keys are generated locally as +0 during the fixed 128-write publish
// pass.  Consequently a row rejected before finalize produces no C write.
//
// A successful row remains HELD after row_commit.  slot_release must carry the
// complete token and represents the later B3/PV final-release event; row_commit
// alone never makes a slot reusable.
module cats_r4_b2_weight_stager #(
    parameter int SEQ_LEN = 128,
    parameter int SLOTS = 3
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        clear,
    input  logic        counter_clear,

    input  logic        stage_begin_valid,
    output logic        stage_begin_ready,
    input  logic [15:0] stage_begin_epoch,
    input  logic [2:0]  stage_begin_group,
    input  logic [4:0]  stage_begin_global_q_head,
    input  logic [6:0]  stage_begin_row,
    input  logic [1:0]  stage_begin_slot_id,
    input  logic [1:0]  stage_begin_numeric_mode,

    // Only unmasked causal keys are staged here.  Compatibility data uses
    // {16'h0000,bf16}; Accuracy data is IEEE binary32 raw bits.
    input  logic        stage_weight_valid,
    output logic        stage_weight_ready,
    input  logic [15:0] stage_weight_epoch,
    input  logic [2:0]  stage_weight_group,
    input  logic [4:0]  stage_weight_global_q_head,
    input  logic [6:0]  stage_weight_row,
    input  logic [1:0]  stage_weight_slot_id,
    input  logic [1:0]  stage_weight_numeric_mode,
    input  logic [6:0]  stage_weight_key,
    input  logic [31:0] stage_weight_data,
    input  logic        stage_weight_last,

    // numeric_error may terminate a row before all causal weights arrive.
    // A non-error finalize is accepted only after exactly row+1 legal weights.
    input  logic        stage_finalize_valid,
    output logic        stage_finalize_ready,
    input  logic [15:0] stage_finalize_epoch,
    input  logic [2:0]  stage_finalize_group,
    input  logic [4:0]  stage_finalize_global_q_head,
    input  logic [6:0]  stage_finalize_row,
    input  logic [1:0]  stage_finalize_slot_id,
    input  logic [1:0]  stage_finalize_numeric_mode,
    input  logic [31:0] stage_finalize_sum_fp32,
    input  logic [31:0] stage_finalize_inv_sum_fp32,
    input  logic        stage_finalize_numeric_error,

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

    // Local B error report.  This is not a B->C weight_abort channel.  The
    // consumer must arrange the matching A/B slot release or global clear.
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

    // Normal rows use this after B3 final output and C weight_release.
    // Error rows use it after the local error report is accepted.  In either
    // case full-token matching is mandatory.
    input  logic        slot_release_valid,
    output logic        slot_release_ready,
    input  logic [15:0] slot_release_epoch,
    input  logic [2:0]  slot_release_group,
    input  logic [4:0]  slot_release_global_q_head,
    input  logic [6:0]  slot_release_row,
    input  logic [1:0]  slot_release_slot_id,
    input  logic [1:0]  slot_release_numeric_mode,

    output logic [8:0]  slot_state,
    output logic [63:0] rows_begin,
    output logic [63:0] stage_weight_accept,
    output logic [63:0] rows_validated,
    output logic [63:0] rows_error,
    output logic [63:0] weight_wr_accept,
    output logic [63:0] row_commit_count,
    output logic [63:0] slot_release_count,
    output logic [63:0] output_stall_cycles,
    output logic [63:0] protocol_error_count,
    output logic [63:0] numeric_error_count,
    output logic [63:0] last_error_count,
    output logic [63:0] mode_error_count,
    output logic [63:0] epoch_drop_count,
    output logic [63:0] owner_error_count,
    output logic [63:0] mask_error_count,
    output logic        error_sticky
);
    localparam logic [2:0] ST_FREE       = 3'd0;
    localparam logic [2:0] ST_FILL       = 3'd1;
    localparam logic [2:0] ST_READY      = 3'd2;
    localparam logic [2:0] ST_PUBLISH    = 3'd3;
    localparam logic [2:0] ST_HELD       = 3'd4;
    localparam logic [2:0] ST_ERROR      = 3'd5;
    localparam logic [2:0] ST_ERROR_HELD = 3'd6;

    localparam logic [3:0] ERR_TOKEN       = 4'd1;
    localparam logic [3:0] ERR_KEY_ORDER   = 4'd2;
    localparam logic [3:0] ERR_LAST         = 4'd3;
    localparam logic [3:0] ERR_MODE         = 4'd4;
    localparam logic [3:0] ERR_WEIGHT_VALUE = 4'd5;
    localparam logic [3:0] ERR_SUM_VALUE    = 4'd6;
    localparam logic [3:0] ERR_UPSTREAM_NUM = 4'd7;

    logic [2:0] state [0:SLOTS-1];
    logic [15:0] token_epoch [0:SLOTS-1];
    logic [2:0] token_group [0:SLOTS-1];
    logic [4:0] token_head [0:SLOTS-1];
    logic [6:0] token_row [0:SLOTS-1];
    logic [1:0] token_mode [0:SLOTS-1];
    logic [7:0] fill_count [0:SLOTS-1];
    logic       fill_last_seen [0:SLOTS-1];
    logic [31:0] sum_fp32 [0:SLOTS-1];
    logic [31:0] inv_sum_fp32 [0:SLOTS-1];
    logic [3:0] error_code [0:SLOTS-1];
    logic [6:0] error_key [0:SLOTS-1];
    logic [31:0] weight_mem [0:SLOTS-1][0:SEQ_LEN-1];

    logic begin_fire;
    logic weight_fire;
    logic finalize_fire;
    logic release_fire;
    logic weight_token_match;
    logic finalize_token_match;
    logic release_token_match;
    logic begin_token_legal;
    logic weight_key_legal;
    logic weight_last_legal;
    logic weight_value_legal;
    logic finalize_count_legal;
    logic finalize_values_legal;
    logic begin_error_event;
    logic weight_error_event;
    logic finalize_error_event;
    logic weight_epoch_error_event;
    logic finalize_epoch_error_event;
    logic weight_key_error_event;
    logic weight_last_error_event;
    logic weight_numeric_error_event;
    logic finalize_numeric_error_event;
    logic finalize_protocol_error_event;
    logic release_reject_seen;
    logic release_reject_event;
    logic release_epoch_error_event;

    logic select_publish_valid;
    logic [1:0] select_publish_slot;
    logic publish_active;
    logic publish_commit_phase;
    logic [1:0] publish_slot;
    logic [6:0] publish_key;
    logic weight_wr_fire;
    logic row_commit_fire;

    logic select_error_valid;
    logic [1:0] select_error_slot;
    logic error_active;
    logic [1:0] active_error_slot;
    logic row_error_fire;

    integer comb_index;
    integer state_index;
    integer seq_index;

    function automatic logic token_matches(
        input logic [1:0] slot,
        input logic [15:0] epoch,
        input logic [2:0] group_id,
        input logic [4:0] head,
        input logic [6:0] row_id,
        input logic [1:0] mode
    );
        begin
            token_matches = token_epoch[slot] == epoch &&
                            token_group[slot] == group_id &&
                            token_head[slot] == head &&
                            token_row[slot] == row_id &&
                            token_mode[slot] == mode;
        end
    endfunction

    function automatic logic weight_is_legal(
        input logic [31:0] data,
        input logic [1:0] mode
    );
        begin
            case (mode)
                2'd0: weight_is_legal = data[31:16] == 0 &&
                                               !data[15] &&
                                               data[14:7] != 8'hff;
                2'd1: weight_is_legal = !data[31] &&
                                               data[30:23] != 8'hff;
                default: weight_is_legal = 1'b0;
            endcase
        end
    endfunction

    function automatic logic fp32_positive_finite(input logic [31:0] data);
        begin
            fp32_positive_finite = !data[31] &&
                                   data[30:23] != 8'hff &&
                                   data[30:0] != 0;
        end
    endfunction

    always_comb begin
        stage_begin_ready = 1'b0;
        if (stage_begin_slot_id < SLOTS)
            stage_begin_ready = state[stage_begin_slot_id] == ST_FREE;

        stage_weight_ready = 1'b0;
        if (stage_weight_slot_id < SLOTS)
            stage_weight_ready = state[stage_weight_slot_id] == ST_FILL;

        // Finalize is deliberately a separate transfer from the last weight.
        // This also gives one unambiguous priority point for validation.
        stage_finalize_ready = 1'b0;
        if (stage_finalize_slot_id < SLOTS)
            stage_finalize_ready =
                state[stage_finalize_slot_id] == ST_FILL &&
                !(stage_weight_valid && stage_weight_ready &&
                  stage_weight_slot_id == stage_finalize_slot_id);

        slot_release_ready = 1'b0;
        release_token_match = 1'b0;
        if (slot_release_slot_id < SLOTS) begin
            release_token_match = token_matches(
                slot_release_slot_id, slot_release_epoch, slot_release_group,
                slot_release_global_q_head, slot_release_row,
                slot_release_numeric_mode);
            slot_release_ready =
                (state[slot_release_slot_id] == ST_HELD ||
                 state[slot_release_slot_id] == ST_ERROR_HELD) &&
                release_token_match;
        end

        weight_token_match = 1'b0;
        weight_key_legal = 1'b0;
        weight_last_legal = 1'b0;
        weight_value_legal = 1'b0;
        if (stage_weight_slot_id < SLOTS) begin
            weight_token_match = token_matches(
                stage_weight_slot_id, stage_weight_epoch,
                stage_weight_group, stage_weight_global_q_head,
                stage_weight_row, stage_weight_numeric_mode);
            weight_key_legal =
                {1'b0,stage_weight_key} == fill_count[stage_weight_slot_id] &&
                stage_weight_key <= token_row[stage_weight_slot_id];
            weight_last_legal = stage_weight_last ==
                                (stage_weight_key ==
                                 token_row[stage_weight_slot_id]);
            weight_value_legal = weight_is_legal(
                stage_weight_data, token_mode[stage_weight_slot_id]);
        end

        finalize_token_match = 1'b0;
        finalize_count_legal = 1'b0;
        if (stage_finalize_slot_id < SLOTS) begin
            finalize_token_match = token_matches(
                stage_finalize_slot_id, stage_finalize_epoch,
                stage_finalize_group, stage_finalize_global_q_head,
                stage_finalize_row, stage_finalize_numeric_mode);
            finalize_count_legal =
                fill_count[stage_finalize_slot_id] ==
                    ({1'b0,token_row[stage_finalize_slot_id]} + 1'b1) &&
                fill_last_seen[stage_finalize_slot_id];
        end
        finalize_values_legal =
            fp32_positive_finite(stage_finalize_sum_fp32) &&
            fp32_positive_finite(stage_finalize_inv_sum_fp32);

        begin_token_legal =
            stage_begin_group == stage_begin_global_q_head[4:2] &&
            stage_begin_numeric_mode < 2;

        begin_fire = stage_begin_valid && stage_begin_ready;
        weight_fire = stage_weight_valid && stage_weight_ready;
        finalize_fire = stage_finalize_valid && stage_finalize_ready;
        release_fire = slot_release_valid && slot_release_ready;
        weight_wr_fire = weight_wr_valid && weight_wr_ready;
        row_commit_fire = row_commit_valid && row_commit_ready;
        row_error_fire = row_error_valid && row_error_ready;

        begin_error_event = begin_fire && !begin_token_legal;
        weight_error_event = weight_fire &&
            (!weight_token_match || !weight_key_legal ||
             !weight_last_legal || !weight_value_legal);
        finalize_error_event = finalize_fire &&
            (stage_finalize_numeric_error || !finalize_token_match ||
             !finalize_count_legal || !finalize_values_legal);
        weight_epoch_error_event = weight_fire && !weight_token_match &&
            stage_weight_epoch != token_epoch[stage_weight_slot_id];
        finalize_epoch_error_event = finalize_fire &&
            !finalize_token_match &&
            stage_finalize_epoch != token_epoch[stage_finalize_slot_id];
        weight_key_error_event = weight_fire && weight_token_match &&
                                 !weight_key_legal;
        weight_last_error_event = weight_fire && weight_token_match &&
                                  weight_key_legal && !weight_last_legal;
        weight_numeric_error_event = weight_fire && weight_token_match &&
                                     weight_key_legal && weight_last_legal &&
                                     !weight_value_legal;
        finalize_numeric_error_event = finalize_fire &&
            (stage_finalize_numeric_error ||
             (finalize_token_match && finalize_count_legal &&
              !finalize_values_legal));
        finalize_protocol_error_event = finalize_fire &&
            !stage_finalize_numeric_error &&
            (!finalize_token_match || !finalize_count_legal);
        release_reject_event = slot_release_valid && !slot_release_ready &&
                               !release_reject_seen;
        release_epoch_error_event = release_reject_event &&
            slot_release_slot_id < SLOTS &&
            (state[slot_release_slot_id] == ST_HELD ||
             state[slot_release_slot_id] == ST_ERROR_HELD) &&
            slot_release_epoch != token_epoch[slot_release_slot_id];

        select_publish_valid = 1'b0;
        select_publish_slot = '0;
        for (comb_index = 0; comb_index < SLOTS; comb_index = comb_index + 1) begin
            if (!select_publish_valid && state[comb_index] == ST_READY) begin
                select_publish_valid = 1'b1;
                select_publish_slot = comb_index[1:0];
            end
        end

        select_error_valid = 1'b0;
        select_error_slot = '0;
        for (comb_index = 0; comb_index < SLOTS; comb_index = comb_index + 1) begin
            if (!select_error_valid && state[comb_index] == ST_ERROR) begin
                select_error_valid = 1'b1;
                select_error_slot = comb_index[1:0];
            end
        end
    end

    assign weight_wr_valid = publish_active && !publish_commit_phase;
    assign weight_wr_epoch = token_epoch[publish_slot];
    assign weight_wr_group = token_group[publish_slot];
    assign weight_wr_global_q_head = token_head[publish_slot];
    assign weight_wr_row = token_row[publish_slot];
    assign weight_wr_slot_id = publish_slot;
    assign weight_wr_numeric_mode = token_mode[publish_slot];
    assign weight_wr_key = publish_key;
    assign weight_wr_mask = publish_key > token_row[publish_slot];
    assign weight_wr_data = weight_wr_mask ? 32'd0 :
                            weight_mem[publish_slot][publish_key];
    assign weight_wr_last = publish_key == SEQ_LEN-1;

    assign row_commit_valid = publish_active && publish_commit_phase;
    assign row_commit_epoch = token_epoch[publish_slot];
    assign row_commit_group = token_group[publish_slot];
    assign row_commit_global_q_head = token_head[publish_slot];
    assign row_commit_row = token_row[publish_slot];
    assign row_commit_slot_id = publish_slot;
    assign row_commit_numeric_mode = token_mode[publish_slot];
    assign row_commit_sum_fp32 = sum_fp32[publish_slot];
    assign row_commit_inv_sum_fp32 = inv_sum_fp32[publish_slot];

    assign row_error_valid = error_active;
    assign row_error_epoch = token_epoch[active_error_slot];
    assign row_error_group = token_group[active_error_slot];
    assign row_error_global_q_head = token_head[active_error_slot];
    assign row_error_row = token_row[active_error_slot];
    assign row_error_slot_id = active_error_slot;
    assign row_error_numeric_mode = token_mode[active_error_slot];
    assign row_error_code = error_code[active_error_slot];
    assign row_error_bad_key = error_key[active_error_slot];

    always_comb begin
        slot_state = '0;
        for (state_index = 0; state_index < SLOTS;
             state_index = state_index + 1)
            slot_state[state_index*3 +: 3] = state[state_index];
    end

    always_ff @(posedge clk or negedge rst_n) begin : p_state
        if (!rst_n) begin
            publish_active <= 1'b0;
            publish_commit_phase <= 1'b0;
            publish_slot <= '0;
            publish_key <= '0;
            error_active <= 1'b0;
            active_error_slot <= '0;
            for (seq_index = 0; seq_index < SLOTS; seq_index = seq_index + 1) begin
                state[seq_index] <= ST_FREE;
                token_epoch[seq_index] <= '0;
                token_group[seq_index] <= '0;
                token_head[seq_index] <= '0;
                token_row[seq_index] <= '0;
                token_mode[seq_index] <= '0;
                fill_count[seq_index] <= '0;
                fill_last_seen[seq_index] <= 1'b0;
                sum_fp32[seq_index] <= '0;
                inv_sum_fp32[seq_index] <= '0;
                error_code[seq_index] <= '0;
                error_key[seq_index] <= '0;
            end
        end else if (clear) begin
            publish_active <= 1'b0;
            publish_commit_phase <= 1'b0;
            publish_slot <= '0;
            publish_key <= '0;
            error_active <= 1'b0;
            active_error_slot <= '0;
            for (seq_index = 0; seq_index < SLOTS; seq_index = seq_index + 1) begin
                state[seq_index] <= ST_FREE;
                token_epoch[seq_index] <= '0;
                token_group[seq_index] <= '0;
                token_head[seq_index] <= '0;
                token_row[seq_index] <= '0;
                token_mode[seq_index] <= '0;
                fill_count[seq_index] <= '0;
                fill_last_seen[seq_index] <= 1'b0;
                sum_fp32[seq_index] <= '0;
                inv_sum_fp32[seq_index] <= '0;
                error_code[seq_index] <= '0;
                error_key[seq_index] <= '0;
            end
        end else begin
            if (begin_fire) begin
                token_epoch[stage_begin_slot_id] <= stage_begin_epoch;
                token_group[stage_begin_slot_id] <= stage_begin_group;
                token_head[stage_begin_slot_id] <=
                    stage_begin_global_q_head;
                token_row[stage_begin_slot_id] <= stage_begin_row;
                token_mode[stage_begin_slot_id] <=
                    stage_begin_numeric_mode;
                fill_count[stage_begin_slot_id] <= '0;
                fill_last_seen[stage_begin_slot_id] <= 1'b0;
                error_code[stage_begin_slot_id] <= '0;
                error_key[stage_begin_slot_id] <= '0;
                if (begin_token_legal) begin
                    state[stage_begin_slot_id] <= ST_FILL;
                end else begin
                    state[stage_begin_slot_id] <= ST_ERROR;
                    error_code[stage_begin_slot_id] <=
                        stage_begin_numeric_mode < 2 ? ERR_TOKEN : ERR_MODE;
                end
            end

            if (weight_fire) begin
                if (weight_token_match && weight_key_legal &&
                    weight_last_legal && weight_value_legal) begin
                    weight_mem[stage_weight_slot_id][stage_weight_key] <=
                        stage_weight_data;
                    fill_count[stage_weight_slot_id] <=
                        fill_count[stage_weight_slot_id] + 1'b1;
                    if (stage_weight_last)
                        fill_last_seen[stage_weight_slot_id] <= 1'b1;
                end else begin
                    state[stage_weight_slot_id] <= ST_ERROR;
                    error_key[stage_weight_slot_id] <= stage_weight_key;
                    if (!weight_token_match)
                        error_code[stage_weight_slot_id] <= ERR_TOKEN;
                    else if (!weight_key_legal)
                        error_code[stage_weight_slot_id] <= ERR_KEY_ORDER;
                    else if (!weight_last_legal)
                        error_code[stage_weight_slot_id] <= ERR_LAST;
                    else
                        error_code[stage_weight_slot_id] <= ERR_WEIGHT_VALUE;
                end
            end

            if (finalize_fire) begin
                if (stage_finalize_numeric_error) begin
                    state[stage_finalize_slot_id] <= ST_ERROR;
                    error_code[stage_finalize_slot_id] <= ERR_UPSTREAM_NUM;
                    error_key[stage_finalize_slot_id] <=
                        fill_count[stage_finalize_slot_id][6:0];
                end else if (!finalize_token_match ||
                             !finalize_count_legal ||
                             !finalize_values_legal) begin
                    state[stage_finalize_slot_id] <= ST_ERROR;
                    error_key[stage_finalize_slot_id] <=
                        fill_count[stage_finalize_slot_id][6:0];
                    error_code[stage_finalize_slot_id] <=
                        !finalize_token_match ? ERR_TOKEN :
                        !finalize_count_legal ? ERR_KEY_ORDER :
                                                  ERR_SUM_VALUE;
                end else begin
                    state[stage_finalize_slot_id] <= ST_READY;
                    sum_fp32[stage_finalize_slot_id] <=
                        stage_finalize_sum_fp32;
                    inv_sum_fp32[stage_finalize_slot_id] <=
                        stage_finalize_inv_sum_fp32;
                end
            end

            if (!publish_active && select_publish_valid) begin
                publish_active <= 1'b1;
                publish_commit_phase <= 1'b0;
                publish_slot <= select_publish_slot;
                publish_key <= '0;
                state[select_publish_slot] <= ST_PUBLISH;
            end else if (weight_wr_fire) begin
                if (publish_key == SEQ_LEN-1) begin
                    publish_commit_phase <= 1'b1;
                end else begin
                    publish_key <= publish_key + 1'b1;
                end
            end else if (row_commit_fire) begin
                publish_active <= 1'b0;
                publish_commit_phase <= 1'b0;
                state[publish_slot] <= ST_HELD;
            end

            if (!error_active && select_error_valid) begin
                error_active <= 1'b1;
                active_error_slot <= select_error_slot;
            end else if (row_error_fire) begin
                error_active <= 1'b0;
                state[active_error_slot] <= ST_ERROR_HELD;
            end

            if (release_fire) begin
                state[slot_release_slot_id] <= ST_FREE;
                fill_count[slot_release_slot_id] <= '0;
                fill_last_seen[slot_release_slot_id] <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin : p_counters
        if (!rst_n) begin
            rows_begin <= '0;
            stage_weight_accept <= '0;
            rows_validated <= '0;
            rows_error <= '0;
            weight_wr_accept <= '0;
            row_commit_count <= '0;
            slot_release_count <= '0;
            output_stall_cycles <= '0;
            protocol_error_count <= '0;
            numeric_error_count <= '0;
            last_error_count <= '0;
            mode_error_count <= '0;
            epoch_drop_count <= '0;
            owner_error_count <= '0;
            mask_error_count <= '0;
            error_sticky <= 1'b0;
            release_reject_seen <= 1'b0;
        end else if (clear || counter_clear) begin
            rows_begin <= '0;
            stage_weight_accept <= '0;
            rows_validated <= '0;
            rows_error <= '0;
            weight_wr_accept <= '0;
            row_commit_count <= '0;
            slot_release_count <= '0;
            output_stall_cycles <= '0;
            protocol_error_count <= '0;
            numeric_error_count <= '0;
            last_error_count <= '0;
            mode_error_count <= '0;
            epoch_drop_count <= '0;
            owner_error_count <= '0;
            mask_error_count <= '0;
            error_sticky <= 1'b0;
            release_reject_seen <= 1'b0;
        end else begin
            if (begin_fire)
                rows_begin <= rows_begin + 1'b1;
            if (weight_fire && !weight_error_event)
                stage_weight_accept <= stage_weight_accept + 1'b1;
            if (finalize_fire && !finalize_error_event)
                rows_validated <= rows_validated + 1'b1;
            if (begin_error_event || weight_error_event ||
                finalize_error_event) begin
                rows_error <= rows_error + begin_error_event +
                              weight_error_event + finalize_error_event;
                error_sticky <= 1'b1;
            end
            if (!slot_release_valid)
                release_reject_seen <= 1'b0;
            else if (release_reject_event) begin
                release_reject_seen <= 1'b1;
                owner_error_count <= owner_error_count + 1'b1;
                error_sticky <= 1'b1;
            end
            if (weight_wr_fire)
                weight_wr_accept <= weight_wr_accept + 1'b1;
            if (row_commit_fire)
                row_commit_count <= row_commit_count + 1'b1;
            if (release_fire)
                slot_release_count <= slot_release_count + 1'b1;
            if ((weight_wr_valid && !weight_wr_ready) ||
                (row_commit_valid && !row_commit_ready) ||
                (row_error_valid && !row_error_ready))
                output_stall_cycles <= output_stall_cycles + 1'b1;

            if ((begin_error_event &&
                 stage_begin_numeric_mode < 2) ||
                weight_key_error_event || weight_last_error_event ||
                (weight_fire && !weight_token_match) ||
                finalize_protocol_error_event)
                protocol_error_count <= protocol_error_count +
                    (begin_error_event && stage_begin_numeric_mode < 2) +
                    weight_key_error_event + weight_last_error_event +
                    (weight_fire && !weight_token_match) +
                    finalize_protocol_error_event;
            if (weight_numeric_error_event ||
                finalize_numeric_error_event)
                numeric_error_count <= numeric_error_count +
                    weight_numeric_error_event +
                    finalize_numeric_error_event;
            if (weight_last_error_event)
                last_error_count <= last_error_count + 1'b1;
            if (begin_error_event && stage_begin_numeric_mode >= 2)
                mode_error_count <= mode_error_count + 1'b1;
            if (weight_epoch_error_event || finalize_epoch_error_event ||
                release_epoch_error_event)
                epoch_drop_count <= epoch_drop_count +
                    weight_epoch_error_event + finalize_epoch_error_event +
                    release_epoch_error_event;
        end
    end

`ifndef SYNTHESIS
    // Publication-phase violations are internal invariants.  Per the frozen
    // scheme-A contract they are fatal and require global clear, not a C-side
    // row abort protocol.
    always @(posedge clk) begin
        if (rst_n && !clear) begin
            if (weight_wr_valid && row_commit_valid)
                $fatal(1, "weight write and row commit overlapped");
            if (weight_wr_valid && weight_wr_mask && weight_wr_data != 0)
                $fatal(1, "masked V3 weight was not +0");
            if (weight_wr_valid &&
                weight_wr_last != (weight_wr_key == SEQ_LEN-1))
                $fatal(1, "V3 weight last/key invariant failed");
            if (weight_wr_valid &&
                weight_wr_mask != (weight_wr_key > weight_wr_row))
                $fatal(1, "V3 mask/key invariant failed");
            if (row_commit_valid && state[publish_slot] != ST_PUBLISH)
                $fatal(1, "row commit without publishing owner");
        end
    end
`endif

    initial begin
        if (SEQ_LEN != 128)
            $error("cats_r4_b2_weight_stager requires S=128");
        if (SLOTS != 3)
            $error("cats_r4_b2_weight_stager requires three slots");
    end
endmodule
