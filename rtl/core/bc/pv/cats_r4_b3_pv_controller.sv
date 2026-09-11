`timescale 1ns/1ps

// CATS-R4 B3 three-row / 32-feature-lane PV controller.
//
// This module owns protocol, scheduling, RAW hazards, counters, output order,
// and the final V3 weight release.  Floating-point arithmetic is deliberately
// behind the mac_* and norm_* internal ready/valid services so the controller
// can be stressed with variable latency and the Vivado FP implementation can
// be audited independently.
//
// A context tag is {slot_id[1:0], feature_block[1:0]}; only tags 0..11 are
// legal.  At most one key is in flight for a context.  That scoreboard rule
// preserves strict key order for every output element without a partial-sum
// tree.  A scalar weight is read once and broadcast across the four feature
// blocks (128 features) of the row.
module cats_r4_b3_pv_controller #(
    parameter int SEQ_LEN = 128,
    parameter int FEATURE_BLOCKS = 4,
    parameter int V_FIFO_DEPTH = 16
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         clear,
    input  logic         counter_clear,

    // Frozen V3 C->B sealed-row transfer.
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

    // Frozen V3 scalar weight read service.  Response has no ready.
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

    // Frozen v1 V service.  The response is exactly tagged by context and
    // has no ready; key/block metadata is retained by this controller.
    output logic         v_req_valid,
    input  logic         v_req_ready,
    output logic [3:0]   v_req_context_tag,
    output logic [6:0]   v_req_key,
    output logic [1:0]   v_req_feature_block,
    input  logic         v_rsp_valid,
    input  logic [3:0]   v_rsp_context_tag,
    input  logic [511:0] v_rsp_vec_bf16,

    // Internal 32-lane, separate-multiply/add, key-ordered FP32 MAC service.
    output logic          mac_valid,
    input  logic          mac_ready,
    output logic [3:0]    mac_context_tag,
    output logic [6:0]    mac_key,
    output logic          mac_first,
    output logic          mac_last,
    output logic [1:0]    mac_numeric_mode,
    output logic [31:0]   mac_weight_data,
    output logic [511:0]  mac_v_vec_bf16,
    input  logic          mac_rsp_valid,
    output logic          mac_rsp_ready,
    input  logic [3:0]    mac_rsp_context_tag,
    input  logic [6:0]    mac_rsp_key,
    input  logic          mac_rsp_last,
    input  logic [1023:0] mac_rsp_accum_fp32,

    // Internal row-end FP32 multiply by inv_sum and BF16-RNE service.
    output logic          norm_valid,
    input  logic          norm_ready,
    output logic [3:0]    norm_context_tag,
    output logic [1023:0] norm_numerator_fp32,
    output logic [31:0]   norm_inv_sum_fp32,
    input  logic          norm_rsp_valid,
    output logic          norm_rsp_ready,
    input  logic [3:0]    norm_rsp_context_tag,
    input  logic [511:0]  norm_rsp_context_bf16,

    // Frozen cluster-to-output shape.
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

    // Frozen V3 B->C release; asserted only after the final output transfer.
    output logic         weight_release_valid,
    input  logic         weight_release_ready,
    output logic [15:0]  weight_release_epoch,
    output logic [2:0]   weight_release_group,
    output logic [4:0]   weight_release_global_q_head,
    output logic [6:0]   weight_release_row,
    output logic [1:0]   weight_release_slot_id,
    output logic [1:0]   weight_release_numeric_mode,

    output logic [63:0] pv_rows_accepted,
    output logic [63:0] weight_rd_requests,
    output logic [63:0] weight_rd_responses,
    output logic [63:0] weight_rd_consumes,
    output logic [63:0] v_requests,
    output logic [63:0] v_responses,
    output logic [63:0] v_consumes,
    output logic [63:0] pv_mac_issue,
    output logic [63:0] pv_mac_result,
    output logic [63:0] pv_mac_commit,
    output logic [63:0] context_words,
    output logic [63:0] rows_released,
    output logic [63:0] raw_scoreboard_stalls,
    output logic [63:0] weight_stall_cycles,
    output logic [63:0] v_stall_cycles,
    output logic [63:0] mac_stall_cycles,
    output logic [63:0] output_stall_cycles,
    output logic [63:0] protocol_error_count,
    output logic [63:0] numeric_error_count,
    output logic [63:0] epoch_drop_count,
    output logic         error_sticky
);
    localparam int SLOTS = 3;
    localparam int CONTEXTS = SLOTS * FEATURE_BLOCKS;
    localparam int FIFO_PTR_W = $clog2(V_FIFO_DEPTH);

    logic slot_active [0:SLOTS-1];
    logic [15:0] slot_epoch [0:SLOTS-1];
    logic [2:0] slot_group [0:SLOTS-1];
    logic [4:0] slot_head [0:SLOTS-1];
    logic [6:0] slot_row [0:SLOTS-1];
    logic [1:0] slot_mode [0:SLOTS-1];
    logic [31:0] slot_inv_sum [0:SLOTS-1];
    logic [7:0] slot_next_weight_key [0:SLOTS-1];
    logic slot_weight_outstanding [0:SLOTS-1];
    logic [6:0] slot_weight_request_key [0:SLOTS-1];
    logic slot_weight_valid [0:SLOTS-1];
    logic [6:0] slot_weight_key [0:SLOTS-1];
    logic [31:0] slot_weight_data [0:SLOTS-1];
    logic [3:0] slot_block_sent [0:SLOTS-1];
    logic [4:0] slot_v_outstanding [0:SLOTS-1];
    logic [3:0] slot_block_ready [0:SLOTS-1];
    logic [511:0] slot_output_data [0:CONTEXTS-1];
    logic slot_output_done [0:SLOTS-1];
    logic [1:0] slot_output_block [0:SLOTS-1];

    logic active_epoch_valid;
    logic [15:0] active_epoch;

    logic [1:0] row_queue [0:SLOTS-1];
    logic [1:0] row_queue_wr_ptr, row_queue_rd_ptr;
    logic [2:0] row_queue_count;

    logic context_busy [0:15];
    logic [6:0] context_expected_key [0:15];
    logic context_expected_last [0:15];
    logic [31:0] context_inv_sum [0:15];
    logic norm_pending [0:15];

    logic pending_valid [0:15];
    logic [6:0] pending_key [0:15];
    logic pending_first [0:15];
    logic pending_last [0:15];
    logic [1:0] pending_mode [0:15];
    logic [31:0] pending_weight [0:15];

    logic [3:0] fifo_context [0:V_FIFO_DEPTH-1];
    logic [6:0] fifo_key [0:V_FIFO_DEPTH-1];
    logic fifo_first [0:V_FIFO_DEPTH-1];
    logic fifo_last [0:V_FIFO_DEPTH-1];
    logic [1:0] fifo_mode [0:V_FIFO_DEPTH-1];
    logic [31:0] fifo_weight [0:V_FIFO_DEPTH-1];
    logic [511:0] fifo_v [0:V_FIFO_DEPTH-1];
    logic [FIFO_PTR_W-1:0] fifo_wr_ptr, fifo_rd_ptr;
    logic [FIFO_PTR_W:0] fifo_count;
    logic [FIFO_PTR_W:0] v_inflight_count;

    logic weight_hold_valid;
    logic [1:0] weight_hold_slot;
    logic [6:0] weight_hold_key;
    logic [1:0] weight_rr;
    logic v_hold_valid;
    logic [1:0] v_hold_slot;
    logic [1:0] v_hold_block;
    logic [6:0] v_hold_key;
    logic [31:0] v_hold_weight;
    logic [1:0] v_rr_slot;
    logic [1:0] v_rr_block;

    logic weight_candidate_valid;
    logic [1:0] weight_candidate_slot;
    logic v_candidate_valid;
    logic [1:0] v_candidate_slot;
    logic [1:0] v_candidate_block;
    logic [3:0] v_candidate_context;
    logic pv_row_fire, pv_row_good, pv_enqueue;
    logic weight_req_fire, weight_rsp_good;
    logic v_req_fire, v_rsp_good, fifo_push, mac_fire;
    logic mac_rsp_fire, mac_rsp_good, norm_rsp_good;
    logic out_fire, release_fire;
    logic [1:0] pv_slot_safe, rsp_slot_safe, head_slot;
    logic [3:0] rsp_context_safe, mac_rsp_context_safe;
    logic [3:0] norm_rsp_context_safe;
    logic [1:0] norm_rsp_slot, norm_rsp_block;
    logic head_slot_quiescent;

    integer scan;
    integer head_scan;
    integer candidate_index;
    integer seq_index;

    function automatic logic [1:0] inc3(input logic [1:0] value);
        begin
            inc3 = value == 2 ? 0 : value + 1'b1;
        end
    endfunction

    function automatic logic fp32_positive_finite(input logic [31:0] value);
        begin
            fp32_positive_finite = !value[31] &&
                                   value[30:23] != 8'hff &&
                                   value[30:0] != 0;
        end
    endfunction

    function automatic logic weight_value_legal(
        input logic [31:0] value,
        input logic [1:0] mode
    );
        begin
            case (mode)
                2'd0: weight_value_legal = value[31:16] == 0 &&
                    !value[15] && value[14:7] != 8'hff;
                2'd1: weight_value_legal = !value[31] &&
                    value[30:23] != 8'hff;
                default: weight_value_legal = 1'b0;
            endcase
        end
    endfunction

    function automatic logic bf16_vector_finite(input logic [511:0] value);
        integer lane;
        begin
            bf16_vector_finite = 1'b1;
            for (lane = 0; lane < 32; lane = lane + 1)
                if (value[lane*16 + 7 +: 8] == 8'hff)
                    bf16_vector_finite = 1'b0;
        end
    endfunction

    always_comb begin : p_candidates
        weight_candidate_valid = 1'b0;
        weight_candidate_slot = '0;
        for (scan = 0; scan < SLOTS; scan = scan + 1) begin
            candidate_index = weight_rr + scan;
            if (candidate_index >= SLOTS)
                candidate_index = candidate_index - SLOTS;
            if (!weight_candidate_valid && slot_active[candidate_index] &&
                !slot_weight_outstanding[candidate_index] &&
                !slot_weight_valid[candidate_index] &&
                slot_next_weight_key[candidate_index] <=
                    {1'b0,slot_row[candidate_index]}) begin
                weight_candidate_valid = 1'b1;
                weight_candidate_slot = candidate_index[1:0];
            end
        end

        v_candidate_valid = 1'b0;
        v_candidate_slot = '0;
        v_candidate_block = '0;
        v_candidate_context = '0;
        for (scan = 0; scan < CONTEXTS; scan = scan + 1) begin
            candidate_index = (v_rr_slot * FEATURE_BLOCKS) + v_rr_block + scan;
            if (candidate_index >= CONTEXTS)
                candidate_index = candidate_index - CONTEXTS;
            if (!v_candidate_valid &&
                slot_active[candidate_index / FEATURE_BLOCKS] &&
                slot_weight_valid[candidate_index / FEATURE_BLOCKS] &&
                !slot_block_sent[candidate_index / FEATURE_BLOCKS]
                                [candidate_index % FEATURE_BLOCKS] &&
                !context_busy[candidate_index] &&
                v_inflight_count < V_FIFO_DEPTH) begin
                v_candidate_valid = 1'b1;
                v_candidate_slot = candidate_index / FEATURE_BLOCKS;
                v_candidate_block = candidate_index % FEATURE_BLOCKS;
                v_candidate_context = candidate_index[3:0];
            end
        end
    end

    assign pv_slot_safe = pv_row_slot_id < SLOTS ? pv_row_slot_id : 0;
    assign rsp_slot_safe = weight_rd_rsp_slot_id < SLOTS ?
                           weight_rd_rsp_slot_id : 0;
    assign rsp_context_safe = v_rsp_context_tag < CONTEXTS ?
                              v_rsp_context_tag : 0;
    assign mac_rsp_context_safe = mac_rsp_context_tag < CONTEXTS ?
                                  mac_rsp_context_tag : 0;
    assign norm_rsp_context_safe = norm_rsp_context_tag < CONTEXTS ?
                                   norm_rsp_context_tag : 0;
    assign norm_rsp_slot = norm_rsp_context_safe[3:2];
    assign norm_rsp_block = norm_rsp_context_safe[1:0];

    assign pv_row_ready = !error_sticky && row_queue_count < SLOTS;
    assign pv_row_fire = pv_row_valid && pv_row_ready;
    assign pv_row_good = pv_row_slot_id < SLOTS &&
                         pv_row_numeric_mode < 2 &&
                         pv_row_group == pv_row_global_q_head[4:2] &&
                         !slot_active[pv_slot_safe] &&
                         (!active_epoch_valid || pv_row_epoch == active_epoch) &&
                         fp32_positive_finite(pv_row_sum_fp32) &&
                         fp32_positive_finite(pv_row_inv_sum_fp32);
    assign pv_enqueue = pv_row_fire && pv_row_good;

    assign weight_rd_req_valid = weight_hold_valid;
    assign weight_rd_req_epoch = slot_epoch[weight_hold_slot];
    assign weight_rd_req_group = slot_group[weight_hold_slot];
    assign weight_rd_req_global_q_head = slot_head[weight_hold_slot];
    assign weight_rd_req_row = slot_row[weight_hold_slot];
    assign weight_rd_req_slot_id = weight_hold_slot;
    assign weight_rd_req_numeric_mode = slot_mode[weight_hold_slot];
    assign weight_rd_req_key = weight_hold_key;
    assign weight_req_fire = weight_rd_req_valid && weight_rd_req_ready;

    assign weight_rsp_good = weight_rd_rsp_slot_id < SLOTS &&
        slot_active[rsp_slot_safe] &&
        slot_weight_outstanding[rsp_slot_safe] &&
        weight_rd_rsp_epoch == slot_epoch[rsp_slot_safe] &&
        weight_rd_rsp_group == slot_group[rsp_slot_safe] &&
        weight_rd_rsp_global_q_head == slot_head[rsp_slot_safe] &&
        weight_rd_rsp_row == slot_row[rsp_slot_safe] &&
        weight_rd_rsp_numeric_mode == slot_mode[rsp_slot_safe] &&
        weight_rd_rsp_key == slot_weight_request_key[rsp_slot_safe] &&
        !weight_rd_rsp_mask &&
        weight_value_legal(weight_rd_rsp_data, slot_mode[rsp_slot_safe]);

    assign v_req_valid = v_hold_valid;
    assign v_req_context_tag = {v_hold_slot,v_hold_block};
    assign v_req_key = v_hold_key;
    assign v_req_feature_block = v_hold_block;
    assign v_req_fire = v_req_valid && v_req_ready;
    assign v_rsp_good = v_rsp_context_tag < CONTEXTS &&
                        pending_valid[rsp_context_safe] &&
                        bf16_vector_finite(v_rsp_vec_bf16);
    assign fifo_push = v_rsp_valid && v_rsp_good;

    assign mac_valid = fifo_count != 0 && !error_sticky;
    assign mac_context_tag = fifo_context[fifo_rd_ptr];
    assign mac_key = fifo_key[fifo_rd_ptr];
    assign mac_first = fifo_first[fifo_rd_ptr];
    assign mac_last = fifo_last[fifo_rd_ptr];
    assign mac_numeric_mode = fifo_mode[fifo_rd_ptr];
    assign mac_weight_data = fifo_weight[fifo_rd_ptr];
    assign mac_v_vec_bf16 = fifo_v[fifo_rd_ptr];
    assign mac_fire = mac_valid && mac_ready;

    assign mac_rsp_good = mac_rsp_context_tag < CONTEXTS &&
        context_busy[mac_rsp_context_safe] &&
        mac_rsp_key == context_expected_key[mac_rsp_context_safe] &&
        mac_rsp_last == context_expected_last[mac_rsp_context_safe];
    assign mac_rsp_ready = !mac_rsp_last || norm_ready;
    assign mac_rsp_fire = mac_rsp_valid && mac_rsp_ready;
    assign norm_valid = mac_rsp_valid && mac_rsp_good && mac_rsp_last;
    assign norm_context_tag = mac_rsp_context_tag;
    assign norm_numerator_fp32 = mac_rsp_accum_fp32;
    assign norm_inv_sum_fp32 = context_inv_sum[mac_rsp_context_safe];

    assign norm_rsp_ready = 1'b1;
    assign norm_rsp_good = norm_rsp_context_tag < CONTEXTS &&
        slot_active[norm_rsp_slot] &&
        norm_pending[norm_rsp_context_safe] &&
        !slot_block_ready[norm_rsp_slot][norm_rsp_block];

    assign head_slot = row_queue_count != 0 ?
                       row_queue[row_queue_rd_ptr] : 0;
    assign out_valid = row_queue_count != 0 &&
        slot_block_ready[head_slot][slot_output_block[head_slot]] &&
        !slot_output_done[head_slot] && !error_sticky;
    assign out_epoch = slot_epoch[head_slot];
    assign out_seq = {slot_head[head_slot],7'd0} + slot_row[head_slot];
    assign out_global_q_head = slot_head[head_slot];
    assign out_row = slot_row[head_slot];
    assign out_feature_block = slot_output_block[head_slot];
    assign out_data_bf16 =
        slot_output_data[{head_slot,slot_output_block[head_slot]}];
    assign out_row_last = slot_output_block[head_slot] == FEATURE_BLOCKS-1;
    assign out_tensor_last = slot_head[head_slot] == 31 &&
                             slot_row[head_slot] == SEQ_LEN-1 &&
                             out_row_last;
    assign out_fire = out_valid && out_ready;

    always_comb begin : p_head_quiescent
        head_slot_quiescent = !slot_weight_outstanding[head_slot] &&
                              !slot_weight_valid[head_slot] &&
                              slot_v_outstanding[head_slot] == 0;
        for (head_scan = 0; head_scan < FEATURE_BLOCKS;
             head_scan = head_scan + 1)
            if (context_busy[{head_slot,head_scan[1:0]}] ||
                norm_pending[{head_slot,head_scan[1:0]}])
                head_slot_quiescent = 1'b0;
    end

    assign weight_release_valid = row_queue_count != 0 &&
        slot_output_done[head_slot] && head_slot_quiescent && !error_sticky;
    assign weight_release_epoch = slot_epoch[head_slot];
    assign weight_release_group = slot_group[head_slot];
    assign weight_release_global_q_head = slot_head[head_slot];
    assign weight_release_row = slot_row[head_slot];
    assign weight_release_slot_id = head_slot;
    assign weight_release_numeric_mode = slot_mode[head_slot];
    assign release_fire = weight_release_valid && weight_release_ready;

    always_ff @(posedge clk or negedge rst_n) begin : p_state
        logic [3:0] sent_after_fire;
        if (!rst_n) begin
            active_epoch_valid <= 1'b0;
            active_epoch <= '0;
            row_queue_wr_ptr <= '0;
            row_queue_rd_ptr <= '0;
            row_queue_count <= '0;
            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
            fifo_count <= '0;
            v_inflight_count <= '0;
            weight_hold_valid <= 1'b0;
            weight_hold_slot <= '0;
            weight_hold_key <= '0;
            weight_rr <= '0;
            v_hold_valid <= 1'b0;
            v_hold_slot <= '0;
            v_hold_block <= '0;
            v_hold_key <= '0;
            v_hold_weight <= '0;
            v_rr_slot <= '0;
            v_rr_block <= '0;
            for (seq_index = 0; seq_index < SLOTS; seq_index = seq_index + 1) begin
                slot_active[seq_index] <= 1'b0;
                slot_epoch[seq_index] <= '0;
                slot_group[seq_index] <= '0;
                slot_head[seq_index] <= '0;
                slot_row[seq_index] <= '0;
                slot_mode[seq_index] <= '0;
                slot_inv_sum[seq_index] <= '0;
                slot_next_weight_key[seq_index] <= '0;
                slot_weight_outstanding[seq_index] <= 1'b0;
                slot_weight_request_key[seq_index] <= '0;
                slot_weight_valid[seq_index] <= 1'b0;
                slot_weight_key[seq_index] <= '0;
                slot_weight_data[seq_index] <= '0;
                slot_block_sent[seq_index] <= '0;
                slot_v_outstanding[seq_index] <= '0;
                slot_block_ready[seq_index] <= '0;
                slot_output_done[seq_index] <= 1'b0;
                slot_output_block[seq_index] <= '0;
                row_queue[seq_index] <= '0;
            end
            for (seq_index = 0; seq_index < 16; seq_index = seq_index + 1) begin
                context_busy[seq_index] <= 1'b0;
                context_expected_key[seq_index] <= '0;
                context_expected_last[seq_index] <= 1'b0;
                context_inv_sum[seq_index] <= '0;
                norm_pending[seq_index] <= 1'b0;
                pending_valid[seq_index] <= 1'b0;
                pending_key[seq_index] <= '0;
                pending_first[seq_index] <= 1'b0;
                pending_last[seq_index] <= 1'b0;
                pending_mode[seq_index] <= '0;
                pending_weight[seq_index] <= '0;
            end
        end else if (clear) begin
            active_epoch_valid <= 1'b0;
            row_queue_wr_ptr <= '0;
            row_queue_rd_ptr <= '0;
            row_queue_count <= '0;
            fifo_wr_ptr <= '0;
            fifo_rd_ptr <= '0;
            fifo_count <= '0;
            v_inflight_count <= '0;
            weight_hold_valid <= 1'b0;
            v_hold_valid <= 1'b0;
            for (seq_index = 0; seq_index < SLOTS; seq_index = seq_index + 1) begin
                slot_active[seq_index] <= 1'b0;
                slot_weight_outstanding[seq_index] <= 1'b0;
                slot_weight_valid[seq_index] <= 1'b0;
                slot_block_sent[seq_index] <= '0;
                slot_v_outstanding[seq_index] <= '0;
                slot_block_ready[seq_index] <= '0;
                slot_output_done[seq_index] <= 1'b0;
                slot_output_block[seq_index] <= '0;
            end
            for (seq_index = 0; seq_index < 16; seq_index = seq_index + 1) begin
                context_busy[seq_index] <= 1'b0;
                norm_pending[seq_index] <= 1'b0;
                pending_valid[seq_index] <= 1'b0;
            end
        end else begin
            if (!weight_hold_valid && weight_candidate_valid) begin
                weight_hold_valid <= 1'b1;
                weight_hold_slot <= weight_candidate_slot;
                weight_hold_key <=
                    slot_next_weight_key[weight_candidate_slot][6:0];
            end else if (weight_req_fire) begin
                weight_hold_valid <= 1'b0;
                slot_weight_outstanding[weight_hold_slot] <= 1'b1;
                slot_weight_request_key[weight_hold_slot] <= weight_hold_key;
                weight_rr <= inc3(weight_hold_slot);
            end

            if (!v_hold_valid && v_candidate_valid) begin
                v_hold_valid <= 1'b1;
                v_hold_slot <= v_candidate_slot;
                v_hold_block <= v_candidate_block;
                v_hold_key <= slot_weight_key[v_candidate_slot];
                v_hold_weight <= slot_weight_data[v_candidate_slot];
            end else if (v_req_fire) begin
                v_hold_valid <= 1'b0;
                sent_after_fire = slot_block_sent[v_hold_slot] |
                                  (4'b0001 << v_hold_block);
                slot_block_sent[v_hold_slot] <= sent_after_fire;
                context_busy[{v_hold_slot,v_hold_block}] <= 1'b1;
                context_expected_key[{v_hold_slot,v_hold_block}] <=
                    v_hold_key;
                context_expected_last[{v_hold_slot,v_hold_block}] <=
                    v_hold_key == slot_row[v_hold_slot];
                context_inv_sum[{v_hold_slot,v_hold_block}] <=
                    slot_inv_sum[v_hold_slot];
                pending_valid[{v_hold_slot,v_hold_block}] <= 1'b1;
                pending_key[{v_hold_slot,v_hold_block}] <= v_hold_key;
                pending_first[{v_hold_slot,v_hold_block}] <=
                    v_hold_key == 0;
                pending_last[{v_hold_slot,v_hold_block}] <=
                    v_hold_key == slot_row[v_hold_slot];
                pending_mode[{v_hold_slot,v_hold_block}] <=
                    slot_mode[v_hold_slot];
                pending_weight[{v_hold_slot,v_hold_block}] <=
                    v_hold_weight;
                if (v_hold_block == FEATURE_BLOCKS-1) begin
                    v_rr_block <= '0;
                    v_rr_slot <= inc3(v_hold_slot);
                end else begin
                    v_rr_block <= v_hold_block + 1'b1;
                    v_rr_slot <= v_hold_slot;
                end
                if (sent_after_fire == 4'hf) begin
                    slot_weight_valid[v_hold_slot] <= 1'b0;
                    slot_block_sent[v_hold_slot] <= '0;
                    slot_next_weight_key[v_hold_slot] <=
                        slot_next_weight_key[v_hold_slot] + 1'b1;
                end
            end

            if (pv_enqueue) begin
                slot_active[pv_row_slot_id] <= 1'b1;
                slot_epoch[pv_row_slot_id] <= pv_row_epoch;
                slot_group[pv_row_slot_id] <= pv_row_group;
                slot_head[pv_row_slot_id] <= pv_row_global_q_head;
                slot_row[pv_row_slot_id] <= pv_row_row;
                slot_mode[pv_row_slot_id] <= pv_row_numeric_mode;
                slot_inv_sum[pv_row_slot_id] <= pv_row_inv_sum_fp32;
                slot_next_weight_key[pv_row_slot_id] <= '0;
                slot_weight_outstanding[pv_row_slot_id] <= 1'b0;
                slot_weight_valid[pv_row_slot_id] <= 1'b0;
                slot_block_sent[pv_row_slot_id] <= '0;
                slot_v_outstanding[pv_row_slot_id] <= '0;
                slot_block_ready[pv_row_slot_id] <= '0;
                slot_output_done[pv_row_slot_id] <= 1'b0;
                slot_output_block[pv_row_slot_id] <= '0;
                row_queue[row_queue_wr_ptr] <= pv_row_slot_id;
                row_queue_wr_ptr <= inc3(row_queue_wr_ptr);
                if (!active_epoch_valid) begin
                    active_epoch_valid <= 1'b1;
                    active_epoch <= pv_row_epoch;
                end
            end

            if (weight_rd_rsp_valid && weight_rd_rsp_slot_id < SLOTS) begin
                slot_weight_outstanding[rsp_slot_safe] <= 1'b0;
                if (weight_rsp_good) begin
                    slot_weight_valid[rsp_slot_safe] <= 1'b1;
                    slot_weight_key[rsp_slot_safe] <= weight_rd_rsp_key;
                    slot_weight_data[rsp_slot_safe] <= weight_rd_rsp_data;
                end
            end

            if (v_rsp_valid && v_rsp_context_tag < CONTEXTS) begin
                pending_valid[rsp_context_safe] <= 1'b0;
            end

            for (seq_index = 0; seq_index < SLOTS; seq_index = seq_index + 1)
                case ({v_req_fire && v_hold_slot == seq_index,
                       v_rsp_valid && v_rsp_context_tag < CONTEXTS &&
                       rsp_context_safe[3:2] == seq_index &&
                       slot_v_outstanding[seq_index] != 0})
                    2'b10: slot_v_outstanding[seq_index] <=
                                slot_v_outstanding[seq_index] + 1'b1;
                    2'b01: slot_v_outstanding[seq_index] <=
                                slot_v_outstanding[seq_index] - 1'b1;
                    default: ;
                endcase

            if (fifo_push) begin
                fifo_wr_ptr <= fifo_wr_ptr + 1'b1;
            end
            if (mac_fire) begin
                fifo_rd_ptr <= fifo_rd_ptr + 1'b1;
            end
            case ({fifo_push,mac_fire})
                2'b10: fifo_count <= fifo_count + 1'b1;
                2'b01: fifo_count <= fifo_count - 1'b1;
                default: fifo_count <= fifo_count;
            endcase
            case ({v_req_fire,mac_fire})
                2'b10: v_inflight_count <= v_inflight_count + 1'b1;
                2'b01: v_inflight_count <= v_inflight_count - 1'b1;
                default: v_inflight_count <= v_inflight_count;
            endcase

            if (mac_rsp_fire && mac_rsp_context_tag < CONTEXTS) begin
                context_busy[mac_rsp_context_safe] <= 1'b0;
                if (mac_rsp_good && mac_rsp_last)
                    norm_pending[mac_rsp_context_safe] <= 1'b1;
            end

            if (norm_rsp_valid && norm_rsp_good) begin
                slot_block_ready[norm_rsp_slot][norm_rsp_block] <= 1'b1;
                norm_pending[norm_rsp_context_safe] <= 1'b0;
            end

            if (out_fire) begin
                if (slot_output_block[head_slot] == FEATURE_BLOCKS-1)
                    slot_output_done[head_slot] <= 1'b1;
                else
                    slot_output_block[head_slot] <=
                        slot_output_block[head_slot] + 1'b1;
            end

            if (release_fire) begin
                slot_active[head_slot] <= 1'b0;
                slot_block_ready[head_slot] <= '0;
                slot_output_done[head_slot] <= 1'b0;
                row_queue_rd_ptr <= inc3(row_queue_rd_ptr);
            end

            case ({pv_enqueue,release_fire})
                2'b10: row_queue_count <= row_queue_count + 1'b1;
                2'b01: row_queue_count <= row_queue_count - 1'b1;
                default: row_queue_count <= row_queue_count;
            endcase
        end
    end

    // The FIFO payload is protected by fifo_count and pointer reset.  Do not
    // reset its data array: reset-sensitive RAM styles force the 512-bit-wide
    // response buffer into FFs and obscure the intended banked storage cost.
    always_ff @(posedge clk) begin : p_fifo_payload_storage
        if (rst_n && !clear && fifo_push) begin
            fifo_context[fifo_wr_ptr] <= v_rsp_context_tag;
            fifo_key[fifo_wr_ptr] <= pending_key[rsp_context_safe];
            fifo_first[fifo_wr_ptr] <= pending_first[rsp_context_safe];
            fifo_last[fifo_wr_ptr] <= pending_last[rsp_context_safe];
            fifo_mode[fifo_wr_ptr] <= pending_mode[rsp_context_safe];
            fifo_weight[fifo_wr_ptr] <= pending_weight[rsp_context_safe];
            fifo_v[fifo_wr_ptr] <= v_rsp_vec_bf16;
        end
    end

    // Output data is valid only when the matching block-ready bit is set.
    // A reset-free payload process avoids reset/set inference on this RAM.
    always_ff @(posedge clk) begin : p_output_payload_storage
        if (rst_n && !clear && norm_rsp_valid && norm_rsp_good)
            slot_output_data[norm_rsp_context_safe] <=
                norm_rsp_context_bf16;
    end

    always_ff @(posedge clk or negedge rst_n) begin : p_counters
        if (!rst_n) begin
            pv_rows_accepted <= '0;
            weight_rd_requests <= '0;
            weight_rd_responses <= '0;
            weight_rd_consumes <= '0;
            v_requests <= '0;
            v_responses <= '0;
            v_consumes <= '0;
            pv_mac_issue <= '0;
            pv_mac_result <= '0;
            pv_mac_commit <= '0;
            context_words <= '0;
            rows_released <= '0;
            raw_scoreboard_stalls <= '0;
            weight_stall_cycles <= '0;
            v_stall_cycles <= '0;
            mac_stall_cycles <= '0;
            output_stall_cycles <= '0;
            protocol_error_count <= '0;
            numeric_error_count <= '0;
            epoch_drop_count <= '0;
            error_sticky <= 1'b0;
        end else if (clear || counter_clear) begin
            pv_rows_accepted <= '0;
            weight_rd_requests <= '0;
            weight_rd_responses <= '0;
            weight_rd_consumes <= '0;
            v_requests <= '0;
            v_responses <= '0;
            v_consumes <= '0;
            pv_mac_issue <= '0;
            pv_mac_result <= '0;
            pv_mac_commit <= '0;
            context_words <= '0;
            rows_released <= '0;
            raw_scoreboard_stalls <= '0;
            weight_stall_cycles <= '0;
            v_stall_cycles <= '0;
            mac_stall_cycles <= '0;
            output_stall_cycles <= '0;
            protocol_error_count <= '0;
            numeric_error_count <= '0;
            epoch_drop_count <= '0;
            error_sticky <= 1'b0;
        end else begin
            if (pv_enqueue)
                pv_rows_accepted <= pv_rows_accepted + 1'b1;
            if (weight_req_fire)
                weight_rd_requests <= weight_rd_requests + 1'b1;
            if (weight_rd_rsp_valid)
                weight_rd_responses <= weight_rd_responses + 1'b1;
            if (v_req_fire)
                v_requests <= v_requests + 1'b1;
            if (v_rsp_valid)
                v_responses <= v_responses + 1'b1;
            if (mac_fire) begin
                v_consumes <= v_consumes + 1'b1;
                pv_mac_issue <= pv_mac_issue + 32;
            end
            if (mac_rsp_fire && mac_rsp_good) begin
                pv_mac_result <= pv_mac_result + 32;
                pv_mac_commit <= pv_mac_commit + 32;
            end
            if (v_req_fire &&
                (slot_block_sent[v_hold_slot] |
                 (4'b0001 << v_hold_block)) == 4'hf)
                weight_rd_consumes <= weight_rd_consumes + 1'b1;
            if (out_fire)
                context_words <= context_words + 32;
            if (release_fire)
                rows_released <= rows_released + 1'b1;

            if (weight_rd_req_valid && !weight_rd_req_ready)
                weight_stall_cycles <= weight_stall_cycles + 1'b1;
            if (v_req_valid && !v_req_ready)
                v_stall_cycles <= v_stall_cycles + 1'b1;
            if (mac_valid && !mac_ready)
                mac_stall_cycles <= mac_stall_cycles + 1'b1;
            if (out_valid && !out_ready)
                output_stall_cycles <= output_stall_cycles + 1'b1;
            if (v_inflight_count < V_FIFO_DEPTH &&
                !v_hold_valid && !v_candidate_valid && row_queue_count != 0)
                raw_scoreboard_stalls <= raw_scoreboard_stalls + 1'b1;

            if (pv_row_fire && !pv_row_good) begin
                error_sticky <= 1'b1;
                if (pv_row_slot_id >= SLOTS ||
                    pv_row_numeric_mode >= 2 ||
                    pv_row_group != pv_row_global_q_head[4:2] ||
                    slot_active[pv_slot_safe])
                    protocol_error_count <= protocol_error_count + 1'b1;
                if ((active_epoch_valid && pv_row_epoch != active_epoch))
                    epoch_drop_count <= epoch_drop_count + 1'b1;
                if (!fp32_positive_finite(pv_row_sum_fp32) ||
                    !fp32_positive_finite(pv_row_inv_sum_fp32))
                    numeric_error_count <= numeric_error_count + 1'b1;
            end
            if (weight_rd_rsp_valid && !weight_rsp_good) begin
                error_sticky <= 1'b1;
                if (weight_rd_rsp_slot_id < SLOTS &&
                    weight_rd_rsp_epoch != slot_epoch[rsp_slot_safe])
                    epoch_drop_count <= epoch_drop_count + 1'b1;
                else if (weight_rd_rsp_slot_id < SLOTS &&
                    !weight_value_legal(weight_rd_rsp_data,
                                        slot_mode[rsp_slot_safe]))
                    numeric_error_count <= numeric_error_count + 1'b1;
                else
                    protocol_error_count <= protocol_error_count + 1'b1;
            end
            if (v_rsp_valid && !v_rsp_good) begin
                error_sticky <= 1'b1;
                if (v_rsp_context_tag < CONTEXTS &&
                    !bf16_vector_finite(v_rsp_vec_bf16))
                    numeric_error_count <= numeric_error_count + 1'b1;
                else
                    protocol_error_count <= protocol_error_count + 1'b1;
            end
            if (mac_rsp_fire && !mac_rsp_good) begin
                error_sticky <= 1'b1;
                protocol_error_count <= protocol_error_count + 1'b1;
            end
            if (norm_rsp_valid && !norm_rsp_good) begin
                error_sticky <= 1'b1;
                protocol_error_count <= protocol_error_count + 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (rst_n && !clear) begin
            if (fifo_count > V_FIFO_DEPTH)
                $fatal(1, "B3 V response FIFO overflow");
            if (v_req_valid && !v_req_ready &&
                (v_req_context_tag != {v_hold_slot,v_hold_block} ||
                 v_req_key != v_hold_key))
                $fatal(1, "B3 stalled V request changed");
            if (weight_release_valid && !slot_output_done[head_slot])
                $fatal(1, "B3 released before final output acceptance");
        end
    end
`endif

    initial begin
        if (SEQ_LEN != 128 || FEATURE_BLOCKS != 4 ||
            V_FIFO_DEPTH != 16)
            $error("cats_r4_b3_pv_controller requires S=128, four blocks, FIFO=16");
    end
endmodule
