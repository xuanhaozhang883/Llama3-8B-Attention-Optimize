`timescale 1ns/1ps

// CATS-R4 IF_V3 three-slot FP32 weight memory service candidate.
//
// The first legal key-0 write allocates a FREE slot to the SOFTMAX owner.
// A complete 128-key row can be committed, announced to PV, read at II=1
// with a fixed N+2 response, and released only after all responses drain.
// This unit is intentionally not in the production manifest until the C
// unit and integration release gates are closed.
module cats_r4_weight_slot_mem #(
    parameter int SLOTS = 3,
    parameter int KEYS  = 128
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,

    input  logic        weight_wr_valid,
    output logic        weight_wr_ready,
    input  logic [15:0] weight_wr_epoch,
    input  logic [2:0]  weight_wr_group,
    input  logic [4:0]  weight_wr_global_q_head,
    input  logic [6:0]  weight_wr_row,
    input  logic [1:0]  weight_wr_slot_id,
    input  logic [1:0]  weight_wr_numeric_mode,
    input  logic [6:0]  weight_wr_key,
    input  logic        weight_wr_mask,
    input  logic [31:0] weight_wr_data,
    input  logic        weight_wr_last,

    input  logic        row_commit_valid,
    output logic        row_commit_ready,
    input  logic [15:0] row_commit_epoch,
    input  logic [2:0]  row_commit_group,
    input  logic [4:0]  row_commit_global_q_head,
    input  logic [6:0]  row_commit_row,
    input  logic [1:0]  row_commit_slot_id,
    input  logic [1:0]  row_commit_numeric_mode,
    input  logic [31:0] row_commit_sum_fp32,
    input  logic [31:0] row_commit_inv_sum_fp32,

    output logic        pv_row_valid,
    input  logic        pv_row_ready,
    output logic [15:0] pv_row_epoch,
    output logic [2:0]  pv_row_group,
    output logic [4:0]  pv_row_global_q_head,
    output logic [6:0]  pv_row_row,
    output logic [1:0]  pv_row_slot_id,
    output logic [1:0]  pv_row_numeric_mode,
    output logic [31:0] pv_row_sum_fp32,
    output logic [31:0] pv_row_inv_sum_fp32,

    input  logic        weight_rd_req_valid,
    output logic        weight_rd_req_ready,
    input  logic [15:0] weight_rd_req_epoch,
    input  logic [2:0]  weight_rd_req_group,
    input  logic [4:0]  weight_rd_req_global_q_head,
    input  logic [6:0]  weight_rd_req_row,
    input  logic [1:0]  weight_rd_req_slot_id,
    input  logic [1:0]  weight_rd_req_numeric_mode,
    input  logic [6:0]  weight_rd_req_key,

    output logic        weight_rd_rsp_valid,
    output logic [15:0] weight_rd_rsp_epoch,
    output logic [2:0]  weight_rd_rsp_group,
    output logic [4:0]  weight_rd_rsp_global_q_head,
    output logic [6:0]  weight_rd_rsp_row,
    output logic [1:0]  weight_rd_rsp_slot_id,
    output logic [1:0]  weight_rd_rsp_numeric_mode,
    output logic [6:0]  weight_rd_rsp_key,
    output logic        weight_rd_rsp_mask,
    output logic [31:0] weight_rd_rsp_data,

    input  logic        weight_release_valid,
    output logic        weight_release_ready,
    input  logic [15:0] weight_release_epoch,
    input  logic [2:0]  weight_release_group,
    input  logic [4:0]  weight_release_global_q_head,
    input  logic [6:0]  weight_release_row,
    input  logic [1:0]  weight_release_slot_id,
    input  logic [1:0]  weight_release_numeric_mode,

    output logic [63:0] weight_wr_accept,
    output logic [63:0] weight_rd_request,
    output logic [63:0] weight_rd_response,
    output logic [63:0] row_commit_count,
    output logic [63:0] pv_row_count,
    output logic [63:0] weight_release_count,
    output logic [63:0] owner_error,
    output logic [63:0] mask_error,
    output logic [63:0] last_error,
    output logic [63:0] mode_error,
    output logic [63:0] numeric_error,
    output logic [63:0] epoch_drop,
    output logic [63:0] bank_conflict,
    output logic [63:0] outstanding_max
);
    localparam logic [1:0] ST_FREE    = 2'd0;
    localparam logic [1:0] ST_SOFTMAX = 2'd1;
    localparam logic [1:0] ST_READY   = 2'd2;
    localparam logic [1:0] ST_PV      = 2'd3;

    logic [1:0]  slot_state [0:SLOTS-1];
    logic [15:0] slot_epoch [0:SLOTS-1];
    logic [2:0]  slot_group [0:SLOTS-1];
    logic [4:0]  slot_head [0:SLOTS-1];
    logic [6:0]  slot_row [0:SLOTS-1];
    logic [1:0]  slot_mode [0:SLOTS-1];
    logic [7:0]  slot_write_count [0:SLOTS-1];
    logic [2:0]  slot_outstanding [0:SLOTS-1];
    logic [31:0] slot_sum [0:SLOTS-1];
    logic [31:0] slot_inv_sum [0:SLOTS-1];
    logic        slot_announced [0:SLOTS-1];

    // One physical RAM per slot.  The 7-bit key address is the frozen logical
    // mapping {addr[1:0],bank[4:0]} = {key[6:5],key[4:0]}.
    // Packing mask with data keeps token and payload atomic at the RAM edge.
    (* ram_style = "distributed" *) logic [32:0] slot_mem_0 [0:KEYS-1];
    (* ram_style = "distributed" *) logic [32:0] slot_mem_1 [0:KEYS-1];
    (* ram_style = "distributed" *) logic [32:0] slot_mem_2 [0:KEYS-1];

    logic wr_slot_valid, commit_slot_valid, rd_slot_valid, release_slot_valid;
    logic wr_token_ok, commit_token_ok, rd_token_ok, release_token_ok;
    logic wr_mode_ok, commit_mode_ok, rd_mode_ok, release_mode_ok;
    logic wr_key_ok, wr_mask_ok, wr_last_ok, commit_numeric_ok;
    logic weight_wr_fire, row_commit_fire, weight_rd_fire, weight_release_fire;
    logic pv_row_fire;

    logic pv_hold_valid;
    logic [1:0] pv_hold_slot;
    logic ready_select_valid;
    logic [1:0] ready_select_slot;

    logic [2:0] owner_error_inc;
    logic       mask_error_inc;
    logic       last_error_inc;
    logic [2:0] mode_error_inc;
    logic       numeric_error_inc;
    logic [2:0] epoch_drop_inc;

    logic rd_v0, rd_v1;
    logic [15:0] rd_epoch0, rd_epoch1;
    logic [2:0]  rd_group0, rd_group1;
    logic [4:0]  rd_head0, rd_head1;
    logic [6:0]  rd_row0, rd_row1;
    logic [1:0]  rd_slot0, rd_slot1;
    logic [1:0]  rd_mode0, rd_mode1;
    logic [6:0]  rd_key0, rd_key1;
    logic        rd_mask0, rd_mask1;
    logic [31:0] rd_data0, rd_data1;

    integer i;
    integer j;

    function automatic logic fp32_positive_finite(input logic [31:0] value);
        fp32_positive_finite =
            !value[31] && (value[30:23] != 8'hff) && (value[30:0] != 31'd0);
    endfunction

    always_comb begin
        wr_slot_valid = (weight_wr_slot_id < SLOTS);
        commit_slot_valid = (row_commit_slot_id < SLOTS);
        rd_slot_valid = (weight_rd_req_slot_id < SLOTS);
        release_slot_valid = (weight_release_slot_id < SLOTS);

        wr_mode_ok = (weight_wr_numeric_mode < 2);
        commit_mode_ok = (row_commit_numeric_mode < 2);
        rd_mode_ok = (weight_rd_req_numeric_mode < 2);
        release_mode_ok = (weight_release_numeric_mode < 2);

        wr_token_ok = 1'b0;
        commit_token_ok = 1'b0;
        rd_token_ok = 1'b0;
        release_token_ok = 1'b0;
        wr_key_ok = 1'b0;
        if (wr_slot_valid) begin
            if (slot_state[weight_wr_slot_id] == ST_FREE) begin
                wr_token_ok = (weight_wr_group == weight_wr_global_q_head[4:2]);
                wr_key_ok = (weight_wr_key == 7'd0);
            end else begin
                wr_token_ok =
                    (slot_state[weight_wr_slot_id] == ST_SOFTMAX) &&
                    (slot_epoch[weight_wr_slot_id] == weight_wr_epoch) &&
                    (slot_group[weight_wr_slot_id] == weight_wr_group) &&
                    (slot_head[weight_wr_slot_id] == weight_wr_global_q_head) &&
                    (slot_row[weight_wr_slot_id] == weight_wr_row) &&
                    (slot_mode[weight_wr_slot_id] == weight_wr_numeric_mode);
                wr_key_ok =
                    (slot_write_count[weight_wr_slot_id] < KEYS) &&
                    (weight_wr_key == slot_write_count[weight_wr_slot_id][6:0]);
            end
        end
        if (commit_slot_valid) begin
            commit_token_ok =
                (slot_state[row_commit_slot_id] == ST_SOFTMAX) &&
                (slot_epoch[row_commit_slot_id] == row_commit_epoch) &&
                (slot_group[row_commit_slot_id] == row_commit_group) &&
                (slot_head[row_commit_slot_id] == row_commit_global_q_head) &&
                (slot_row[row_commit_slot_id] == row_commit_row) &&
                (slot_mode[row_commit_slot_id] == row_commit_numeric_mode) &&
                (slot_write_count[row_commit_slot_id] == KEYS);
        end
        if (rd_slot_valid) begin
            rd_token_ok =
                (slot_state[weight_rd_req_slot_id] == ST_PV) &&
                (slot_epoch[weight_rd_req_slot_id] == weight_rd_req_epoch) &&
                (slot_group[weight_rd_req_slot_id] == weight_rd_req_group) &&
                (slot_head[weight_rd_req_slot_id] == weight_rd_req_global_q_head) &&
                (slot_row[weight_rd_req_slot_id] == weight_rd_req_row) &&
                (slot_mode[weight_rd_req_slot_id] == weight_rd_req_numeric_mode);
        end
        if (release_slot_valid) begin
            release_token_ok =
                (slot_state[weight_release_slot_id] == ST_PV) &&
                (slot_epoch[weight_release_slot_id] == weight_release_epoch) &&
                (slot_group[weight_release_slot_id] == weight_release_group) &&
                (slot_head[weight_release_slot_id] == weight_release_global_q_head) &&
                (slot_row[weight_release_slot_id] == weight_release_row) &&
                (slot_mode[weight_release_slot_id] == weight_release_numeric_mode);
        end

        wr_mask_ok = (weight_wr_mask == (weight_wr_key > weight_wr_row)) &&
                     (!weight_wr_mask || (weight_wr_data == 32'd0));
        wr_last_ok = (weight_wr_last == (weight_wr_key == KEYS-1));
        commit_numeric_ok = fp32_positive_finite(row_commit_sum_fp32) &&
                            fp32_positive_finite(row_commit_inv_sum_fp32);

        weight_wr_ready = wr_slot_valid && wr_mode_ok && wr_token_ok &&
                          wr_key_ok && wr_mask_ok && wr_last_ok;
        row_commit_ready = commit_slot_valid && commit_mode_ok &&
                           commit_token_ok && commit_numeric_ok;
        weight_rd_req_ready = rd_slot_valid && rd_mode_ok && rd_token_ok;
        weight_release_ready = release_slot_valid && release_mode_ok &&
                               release_token_ok &&
                               (slot_outstanding[weight_release_slot_id] == 0);

        ready_select_valid = 1'b0;
        ready_select_slot = '0;
        for (j = 0; j < SLOTS; j = j + 1) begin
            if (!ready_select_valid && (slot_state[j] == ST_READY) &&
                !slot_announced[j]) begin
                ready_select_valid = 1'b1;
                ready_select_slot = j[1:0];
            end
        end

        owner_error_inc = '0;
        mask_error_inc = 1'b0;
        last_error_inc = 1'b0;
        mode_error_inc = '0;
        numeric_error_inc = 1'b0;
        epoch_drop_inc = '0;
        if (weight_wr_valid && !weight_wr_ready) begin
            if (!wr_mode_ok)
                mode_error_inc = mode_error_inc + 1'b1;
            else if (!wr_mask_ok)
                mask_error_inc = 1'b1;
            else if (!wr_last_ok)
                last_error_inc = 1'b1;
            else if (wr_slot_valid &&
                     (slot_state[weight_wr_slot_id] != ST_FREE) &&
                     (slot_epoch[weight_wr_slot_id] != weight_wr_epoch))
                epoch_drop_inc = epoch_drop_inc + 1'b1;
            else
                owner_error_inc = owner_error_inc + 1'b1;
        end
        if (row_commit_valid && !row_commit_ready) begin
            if (!commit_mode_ok)
                mode_error_inc = mode_error_inc + 1'b1;
            else if (!commit_numeric_ok)
                numeric_error_inc = 1'b1;
            else if (commit_slot_valid &&
                     (slot_state[row_commit_slot_id] != ST_FREE) &&
                     (slot_epoch[row_commit_slot_id] != row_commit_epoch))
                epoch_drop_inc = epoch_drop_inc + 1'b1;
            else
                owner_error_inc = owner_error_inc + 1'b1;
        end
        if (weight_rd_req_valid && !weight_rd_req_ready) begin
            if (!rd_mode_ok)
                mode_error_inc = mode_error_inc + 1'b1;
            else if (rd_slot_valid &&
                     (slot_state[weight_rd_req_slot_id] != ST_FREE) &&
                     (slot_epoch[weight_rd_req_slot_id] != weight_rd_req_epoch))
                epoch_drop_inc = epoch_drop_inc + 1'b1;
            else
                owner_error_inc = owner_error_inc + 1'b1;
        end
        if (weight_release_valid && !weight_release_ready) begin
            if (!release_mode_ok)
                mode_error_inc = mode_error_inc + 1'b1;
            else if (release_slot_valid &&
                     (slot_state[weight_release_slot_id] != ST_FREE) &&
                     (slot_epoch[weight_release_slot_id] != weight_release_epoch))
                epoch_drop_inc = epoch_drop_inc + 1'b1;
            else if (!release_token_ok)
                owner_error_inc = owner_error_inc + 1'b1;
        end
    end

    assign weight_wr_fire = weight_wr_valid && weight_wr_ready;
    assign row_commit_fire = row_commit_valid && row_commit_ready;
    assign weight_rd_fire = weight_rd_req_valid && weight_rd_req_ready;
    assign weight_release_fire = weight_release_valid && weight_release_ready;
    assign pv_row_fire = pv_row_valid && pv_row_ready;

    // The payload RAMs deliberately have no reset: validity is carried only
    // by slot_state.  Keeping RAM writes and synchronous reads in this
    // reset-free process permits real block-RAM inference.
    always_ff @(posedge clk) begin
        if (weight_wr_fire) begin
            case (weight_wr_slot_id)
                2'd0: slot_mem_0[weight_wr_key] <=
                    {weight_wr_mask, weight_wr_data};
                2'd1: slot_mem_1[weight_wr_key] <=
                    {weight_wr_mask, weight_wr_data};
                2'd2: slot_mem_2[weight_wr_key] <=
                    {weight_wr_mask, weight_wr_data};
                default: begin end
            endcase
        end
        if (weight_rd_fire) begin
            case (weight_rd_req_slot_id)
                2'd0: {rd_mask0, rd_data0} <= slot_mem_0[weight_rd_req_key];
                2'd1: {rd_mask0, rd_data0} <= slot_mem_1[weight_rd_req_key];
                2'd2: {rd_mask0, rd_data0} <= slot_mem_2[weight_rd_req_key];
                default: {rd_mask0, rd_data0} <= '0;
            endcase
        end
    end

    always_comb begin
        pv_row_valid = pv_hold_valid;
        pv_row_epoch = '0;
        pv_row_group = '0;
        pv_row_global_q_head = '0;
        pv_row_row = '0;
        pv_row_slot_id = pv_hold_slot;
        pv_row_numeric_mode = '0;
        pv_row_sum_fp32 = '0;
        pv_row_inv_sum_fp32 = '0;
        if (pv_hold_valid) begin
            pv_row_epoch = slot_epoch[pv_hold_slot];
            pv_row_group = slot_group[pv_hold_slot];
            pv_row_global_q_head = slot_head[pv_hold_slot];
            pv_row_row = slot_row[pv_hold_slot];
            pv_row_numeric_mode = slot_mode[pv_hold_slot];
            pv_row_sum_fp32 = slot_sum[pv_hold_slot];
            pv_row_inv_sum_fp32 = slot_inv_sum[pv_hold_slot];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pv_hold_valid <= 1'b0;
            pv_hold_slot <= '0;
            rd_v0 <= 1'b0;
            rd_v1 <= 1'b0;
            rd_epoch0 <= '0; rd_epoch1 <= '0;
            rd_group0 <= '0; rd_group1 <= '0;
            rd_head0 <= '0; rd_head1 <= '0;
            rd_row0 <= '0; rd_row1 <= '0;
            rd_slot0 <= '0; rd_slot1 <= '0;
            rd_mode0 <= '0; rd_mode1 <= '0;
            rd_key0 <= '0; rd_key1 <= '0;
            rd_mask1 <= '0; rd_data1 <= '0;
            weight_rd_rsp_valid <= 1'b0;
            weight_rd_rsp_epoch <= '0;
            weight_rd_rsp_group <= '0;
            weight_rd_rsp_global_q_head <= '0;
            weight_rd_rsp_row <= '0;
            weight_rd_rsp_slot_id <= '0;
            weight_rd_rsp_numeric_mode <= '0;
            weight_rd_rsp_key <= '0;
            weight_rd_rsp_mask <= '0;
            weight_rd_rsp_data <= '0;
            weight_wr_accept <= '0;
            weight_rd_request <= '0;
            weight_rd_response <= '0;
            row_commit_count <= '0;
            pv_row_count <= '0;
            weight_release_count <= '0;
            owner_error <= '0;
            mask_error <= '0;
            last_error <= '0;
            mode_error <= '0;
            numeric_error <= '0;
            epoch_drop <= '0;
            bank_conflict <= '0;
            outstanding_max <= '0;
            for (i = 0; i < SLOTS; i = i + 1) begin
                slot_state[i] <= ST_FREE;
                slot_epoch[i] <= '0;
                slot_group[i] <= '0;
                slot_head[i] <= '0;
                slot_row[i] <= '0;
                slot_mode[i] <= '0;
                slot_write_count[i] <= '0;
                slot_outstanding[i] <= '0;
                slot_sum[i] <= '0;
                slot_inv_sum[i] <= '0;
                slot_announced[i] <= 1'b0;
            end
        end else if (clear) begin
            pv_hold_valid <= 1'b0;
            pv_hold_slot <= '0;
            rd_v0 <= 1'b0;
            rd_v1 <= 1'b0;
            rd_epoch0 <= '0; rd_epoch1 <= '0;
            rd_group0 <= '0; rd_group1 <= '0;
            rd_head0 <= '0; rd_head1 <= '0;
            rd_row0 <= '0; rd_row1 <= '0;
            rd_slot0 <= '0; rd_slot1 <= '0;
            rd_mode0 <= '0; rd_mode1 <= '0;
            rd_key0 <= '0; rd_key1 <= '0;
            rd_mask1 <= '0; rd_data1 <= '0;
            weight_rd_rsp_valid <= 1'b0;
            weight_rd_rsp_epoch <= '0;
            weight_rd_rsp_group <= '0;
            weight_rd_rsp_global_q_head <= '0;
            weight_rd_rsp_row <= '0;
            weight_rd_rsp_slot_id <= '0;
            weight_rd_rsp_numeric_mode <= '0;
            weight_rd_rsp_key <= '0;
            weight_rd_rsp_mask <= '0;
            weight_rd_rsp_data <= '0;
            weight_wr_accept <= '0;
            weight_rd_request <= '0;
            weight_rd_response <= '0;
            row_commit_count <= '0;
            pv_row_count <= '0;
            weight_release_count <= '0;
            owner_error <= '0;
            mask_error <= '0;
            last_error <= '0;
            mode_error <= '0;
            numeric_error <= '0;
            epoch_drop <= '0;
            bank_conflict <= '0;
            outstanding_max <= '0;
            for (i = 0; i < SLOTS; i = i + 1) begin
                slot_state[i] <= ST_FREE;
                slot_write_count[i] <= '0;
                slot_outstanding[i] <= '0;
                slot_announced[i] <= 1'b0;
            end
        end else begin
            rd_v0 <= weight_rd_fire;
            rd_v1 <= rd_v0;
            weight_rd_rsp_valid <= rd_v1;
            if (weight_rd_fire) begin
                rd_epoch0 <= weight_rd_req_epoch;
                rd_group0 <= weight_rd_req_group;
                rd_head0 <= weight_rd_req_global_q_head;
                rd_row0 <= weight_rd_req_row;
                rd_slot0 <= weight_rd_req_slot_id;
                rd_mode0 <= weight_rd_req_numeric_mode;
                rd_key0 <= weight_rd_req_key;
            end
            if (rd_v0) begin
                rd_epoch1 <= rd_epoch0;
                rd_group1 <= rd_group0;
                rd_head1 <= rd_head0;
                rd_row1 <= rd_row0;
                rd_slot1 <= rd_slot0;
                rd_mode1 <= rd_mode0;
                rd_key1 <= rd_key0;
                rd_mask1 <= rd_mask0;
                rd_data1 <= rd_data0;
            end
            if (rd_v1) begin
                weight_rd_rsp_epoch <= rd_epoch1;
                weight_rd_rsp_group <= rd_group1;
                weight_rd_rsp_global_q_head <= rd_head1;
                weight_rd_rsp_row <= rd_row1;
                weight_rd_rsp_slot_id <= rd_slot1;
                weight_rd_rsp_numeric_mode <= rd_mode1;
                weight_rd_rsp_key <= rd_key1;
                weight_rd_rsp_mask <= rd_mask1;
                weight_rd_rsp_data <= rd_data1;
                weight_rd_response <= weight_rd_response + 1'b1;
            end

            if (weight_wr_fire) begin
                if (slot_state[weight_wr_slot_id] == ST_FREE) begin
                    slot_state[weight_wr_slot_id] <= ST_SOFTMAX;
                    slot_epoch[weight_wr_slot_id] <= weight_wr_epoch;
                    slot_group[weight_wr_slot_id] <= weight_wr_group;
                    slot_head[weight_wr_slot_id] <= weight_wr_global_q_head;
                    slot_row[weight_wr_slot_id] <= weight_wr_row;
                    slot_mode[weight_wr_slot_id] <= weight_wr_numeric_mode;
                    slot_write_count[weight_wr_slot_id] <= 8'd1;
                end else begin
                    slot_write_count[weight_wr_slot_id] <=
                        slot_write_count[weight_wr_slot_id] + 1'b1;
                end
                weight_wr_accept <= weight_wr_accept + 1'b1;
            end

            if (row_commit_fire) begin
                slot_state[row_commit_slot_id] <= ST_READY;
                slot_sum[row_commit_slot_id] <= row_commit_sum_fp32;
                slot_inv_sum[row_commit_slot_id] <= row_commit_inv_sum_fp32;
                slot_announced[row_commit_slot_id] <= 1'b0;
                row_commit_count <= row_commit_count + 1'b1;
            end

            if (pv_hold_valid) begin
                if (pv_row_fire) begin
                    slot_state[pv_hold_slot] <= ST_PV;
                    pv_hold_valid <= 1'b0;
                    pv_row_count <= pv_row_count + 1'b1;
                end
            end else if (ready_select_valid) begin
                pv_hold_valid <= 1'b1;
                pv_hold_slot <= ready_select_slot;
                slot_announced[ready_select_slot] <= 1'b1;
            end

            for (i = 0; i < SLOTS; i = i + 1) begin
                case ({weight_rd_fire && (weight_rd_req_slot_id == i),
                       rd_v1 && (rd_slot1 == i)})
                    2'b10: begin
                        slot_outstanding[i] <= slot_outstanding[i] + 1'b1;
                        if ((slot_outstanding[i] + 1'b1) > outstanding_max)
                            outstanding_max <= slot_outstanding[i] + 1'b1;
                    end
                    2'b01: slot_outstanding[i] <= slot_outstanding[i] - 1'b1;
                    default: begin end
                endcase
            end

            if (weight_rd_fire)
                weight_rd_request <= weight_rd_request + 1'b1;

            if (weight_release_fire) begin
                slot_state[weight_release_slot_id] <= ST_FREE;
                slot_write_count[weight_release_slot_id] <= '0;
                slot_announced[weight_release_slot_id] <= 1'b0;
                weight_release_count <= weight_release_count + 1'b1;
            end

            if (owner_error_inc != 0)
                owner_error <= owner_error + owner_error_inc;
            if (mask_error_inc)
                mask_error <= mask_error + 1'b1;
            if (last_error_inc)
                last_error <= last_error + 1'b1;
            if (mode_error_inc != 0)
                mode_error <= mode_error + mode_error_inc;
            if (numeric_error_inc)
                numeric_error <= numeric_error + 1'b1;
            if (epoch_drop_inc != 0)
                epoch_drop <= epoch_drop + epoch_drop_inc;
        end
    end

    initial begin
        if ((SLOTS != 3) || (KEYS != 128))
            $error("cats_r4_weight_slot_mem: CATS_R4_IF_V3 requires 3 slots and 128 keys");
    end
endmodule
