// CATS-R4 A2 local checkpoint: 32-key-lane, R=16 QK issue scheduler.
//
// This module implements scheduling and protocol only.  The floating-point
// MAC array is an explicit tagged ready/valid service so measured IP latency
// can be connected without assuming a fixed result latency.  It is not an A2
// READY implementation and is intentionally absent from the production
// source manifest.
module cats_r4_qk_32lane_scheduler #(
    parameter int SEQ_LEN  = 128,
    parameter int HEAD_DIM = 128,
    parameter int CONTEXTS = 16,
    parameter int LANES    = 32
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         clear,
    input  logic         counter_clear,
    input  logic         start_valid,
    output logic         start_ready,
    input  logic [15:0]  start_epoch,
    input  logic [2:0]   start_group,
    input  logic [4:0]   start_global_q_head,
    input  logic [2:0]   start_row_window,
    input  logic [4:0]   start_row_count,
    input  logic [1:0]   start_key_block,
    output logic         done_valid,
    input  logic         done_ready,
    output logic [15:0]  done_epoch,
    output logic [2:0]   done_group,
    output logic [4:0]   done_global_q_head,
    output logic [2:0]   done_row_window,
    output logic [1:0]   done_key_block,
    output logic         done_error,
    output logic         q_req_valid,
    input  logic         q_req_ready,
    output logic [3:0]   q_req_context_tag,
    output logic [6:0]   q_req_d,
    input  logic         q_rsp_valid,
    input  logic [3:0]   q_rsp_context_tag,
    input  logic [15:0]  q_rsp_bf16,
    output logic         k_req_valid,
    input  logic         k_req_ready,
    output logic [3:0]   k_req_context_tag,
    output logic [1:0]   k_req_key_block,
    output logic [6:0]   k_req_d,
    input  logic         k_rsp_valid,
    input  logic [3:0]   k_rsp_context_tag,
    input  logic [511:0] k_rsp_vec,
    output logic         mac_valid,
    input  logic         mac_ready,
    output logic [15:0]  mac_epoch,
    output logic [2:0]   mac_group,
    output logic [4:0]   mac_global_q_head,
    output logic [6:0]   mac_row,
    output logic [1:0]   mac_key_block,
    output logic [3:0]   mac_context_tag,
    output logic [6:0]   mac_d,
    output logic [31:0]  mac_lane_valid,
    output logic         mac_first,
    output logic         mac_last,
    output logic [15:0]  mac_q_bf16,
    output logic [511:0] mac_k_vec,
    input  logic         mac_rsp_valid,
    output logic         mac_rsp_ready,
    input  logic [15:0]  mac_rsp_epoch,
    input  logic [2:0]   mac_rsp_group,
    input  logic [4:0]   mac_rsp_global_q_head,
    input  logic [6:0]   mac_rsp_row,
    input  logic [1:0]   mac_rsp_key_block,
    input  logic [3:0]   mac_rsp_context_tag,
    input  logic [6:0]   mac_rsp_d,
    output logic [63:0]  q_requests_accepted,
    output logic [63:0]  k_requests_accepted,
    output logic [63:0]  mac_steps_issued,
    output logic [63:0]  mac_steps_completed,
    output logic [63:0]  valid_macs,
    output logic [63:0]  causal_lane_bubbles,
    output logic [63:0]  causal_rows_skipped,
    output logic [63:0]  memory_request_stalls,
    output logic [63:0]  mac_issue_stalls,
    output logic [63:0]  protocol_errors,
    output logic         protocol_error_sticky
);
    typedef enum logic [1:0] { ST_IDLE, ST_RUN, ST_DONE } state_t;
    state_t state;

    logic [15:0] epoch_reg;
    logic [2:0] group_reg;
    logic [4:0] head_reg;
    logic [2:0] row_window_reg;
    logic [1:0] key_block_reg;
    logic [6:0] d_reg;
    logic [15:0] active_mask, q_sent, k_sent;
    logic [15:0] q_outstanding, k_outstanding;
    logic [15:0] q_buffer_valid, k_buffer_valid;
    logic [15:0] mac_busy, result_done;
    logic [15:0] q_buffer [0:CONTEXTS-1];
    logic [511:0] k_buffer [0:CONTEXTS-1];

    logic q_select_valid, k_select_valid, mac_select_valid;
    logic [3:0] q_select_context, k_select_context, mac_select_context;
    logic mac_hold_valid;
    logic [3:0] mac_hold_context;
    logic [15:0] mac_hold_q;
    logic [511:0] mac_hold_k;
    logic [31:0] mac_hold_lane_mask;
    logic [15:0] start_active_mask;
    logic [31:0] selected_lane_mask;
    logic [3:0] selected_context;
    logic [6:0] selected_row;
    logic start_fields_valid, all_results_done;

    function automatic [5:0] popcount32(input logic [31:0] value);
        integer lane;
        begin
            popcount32 = 0;
            for (lane = 0; lane < 32; lane = lane + 1)
                popcount32 = popcount32 + value[lane];
        end
    endfunction

    function automatic [4:0] popcount16(input logic [15:0] value);
        integer context_index;
        begin
            popcount16 = 0;
            for (context_index = 0; context_index < 16;
                 context_index = context_index + 1)
                popcount16 = popcount16 + value[context_index];
        end
    endfunction

    function automatic [31:0] lane_mask_for(
        input logic [6:0] row_value,
        input logic [1:0] key_block_value
    );
        integer lane, key_value;
        begin
            lane_mask_for = 0;
            for (lane = 0; lane < 32; lane = lane + 1) begin
                key_value = (key_block_value * 32) + lane;
                if ((key_value < SEQ_LEN) && (key_value <= row_value))
                    lane_mask_for[lane] = 1'b1;
            end
        end
    endfunction

    always_comb begin : p_start_active_mask
        integer start_scan;
        start_active_mask = 0;
        for (start_scan = 0; start_scan < CONTEXTS;
             start_scan = start_scan + 1)
            if (($unsigned(start_scan) < $unsigned(start_row_count)) &&
                (($unsigned(start_row_window) * CONTEXTS + start_scan) < SEQ_LEN) &&
                (($unsigned(start_row_window) * CONTEXTS + start_scan) >=
                 ($unsigned(start_key_block) * LANES)))
                start_active_mask[start_scan] = 1'b1;
    end

    always_comb begin : p_select
        integer select_scan;
        q_select_valid = 0;
        q_select_context = 0;
        k_select_valid = 0;
        k_select_context = 0;
        mac_select_valid = 0;
        mac_select_context = 0;
        for (select_scan = 0; select_scan < CONTEXTS;
             select_scan = select_scan + 1) begin
            if (!q_select_valid && active_mask[select_scan] &&
                !q_sent[select_scan]) begin
                q_select_valid = 1;
                q_select_context = select_scan[3:0];
            end
            if (!k_select_valid && active_mask[select_scan] &&
                !k_sent[select_scan]) begin
                k_select_valid = 1;
                k_select_context = select_scan[3:0];
            end
            if (!mac_select_valid && q_buffer_valid[select_scan] &&
                k_buffer_valid[select_scan] &&
                !mac_busy[select_scan]) begin
                mac_select_valid = 1;
                mac_select_context = select_scan[3:0];
            end
        end
    end

    assign start_fields_valid =
        (start_row_count != 0) &&
        ($unsigned(start_row_count) <= CONTEXTS) &&
        (($unsigned(start_row_window) * CONTEXTS +
          $unsigned(start_row_count)) <= SEQ_LEN) &&
        (start_global_q_head[4:2] == start_group);

    assign start_ready = (state == ST_IDLE);
    assign done_valid = (state == ST_DONE);
    assign done_epoch = epoch_reg;
    assign done_group = group_reg;
    assign done_global_q_head = head_reg;
    assign done_row_window = row_window_reg;
    assign done_key_block = key_block_reg;
    assign done_error = protocol_error_sticky;

    assign q_req_valid = (state == ST_RUN) && q_select_valid;
    assign q_req_context_tag = q_select_context;
    assign q_req_d = d_reg;
    assign k_req_valid = (state == ST_RUN) && k_select_valid;
    assign k_req_context_tag = k_select_context;
    assign k_req_key_block = key_block_reg;
    assign k_req_d = d_reg;

    assign selected_context = mac_hold_valid ?
                              mac_hold_context : mac_select_context;
    assign selected_row =
        ($unsigned(row_window_reg) * CONTEXTS) + selected_context;
    assign selected_lane_mask = mac_hold_valid ?
                                mac_hold_lane_mask :
                                lane_mask_for(selected_row, key_block_reg);
    assign mac_valid = (state == ST_RUN) &&
                       (mac_hold_valid || mac_select_valid);
    assign mac_epoch = epoch_reg;
    assign mac_group = group_reg;
    assign mac_global_q_head = head_reg;
    assign mac_row = selected_row;
    assign mac_key_block = key_block_reg;
    assign mac_context_tag = selected_context;
    assign mac_d = d_reg;
    assign mac_lane_valid = selected_lane_mask;
    assign mac_first = (d_reg == 0);
    assign mac_last = (d_reg == HEAD_DIM-1);
    assign mac_q_bf16 = mac_hold_valid ?
                        mac_hold_q : q_buffer[mac_select_context];
    assign mac_k_vec = mac_hold_valid ?
                       mac_hold_k : k_buffer[mac_select_context];
    assign mac_rsp_ready = (state == ST_RUN);
    assign all_results_done =
        (active_mask != 0) &&
        ((result_done & active_mask) == active_mask);

    always_ff @(posedge clk) begin : p_scheduler
        logic mac_rsp_matches;
        logic [5:0] active_lanes;

        if (!rst_n || clear) begin
            state <= ST_IDLE;
            epoch_reg <= 0;
            group_reg <= 0;
            head_reg <= 0;
            row_window_reg <= 0;
            key_block_reg <= 0;
            d_reg <= 0;
            active_mask <= 0;
            q_sent <= 0;
            k_sent <= 0;
            q_outstanding <= 0;
            k_outstanding <= 0;
            q_buffer_valid <= 0;
            k_buffer_valid <= 0;
            mac_busy <= 0;
            result_done <= 0;
            mac_hold_valid <= 0;
            mac_hold_context <= 0;
            mac_hold_q <= 0;
            mac_hold_k <= 0;
            mac_hold_lane_mask <= 0;
            q_requests_accepted <= 0;
            k_requests_accepted <= 0;
            mac_steps_issued <= 0;
            mac_steps_completed <= 0;
            valid_macs <= 0;
            causal_lane_bubbles <= 0;
            causal_rows_skipped <= 0;
            memory_request_stalls <= 0;
            mac_issue_stalls <= 0;
            protocol_errors <= 0;
            protocol_error_sticky <= 0;
        end else begin
            if (counter_clear) begin
                q_requests_accepted <= 0;
                k_requests_accepted <= 0;
                mac_steps_issued <= 0;
                mac_steps_completed <= 0;
                valid_macs <= 0;
                causal_lane_bubbles <= 0;
                causal_rows_skipped <= 0;
                memory_request_stalls <= 0;
                mac_issue_stalls <= 0;
                protocol_errors <= 0;
                protocol_error_sticky <= 0;
            end
            if ((state == ST_RUN) &&
                ((q_req_valid && !q_req_ready) ||
                 (k_req_valid && !k_req_ready)))
                memory_request_stalls <= memory_request_stalls + 1;
            if (mac_valid && !mac_ready)
                mac_issue_stalls <= mac_issue_stalls + 1;

            if (q_req_valid && q_req_ready) begin
                q_sent[q_req_context_tag] <= 1;
                q_outstanding[q_req_context_tag] <= 1;
                q_requests_accepted <= q_requests_accepted + 1;
            end
            if (k_req_valid && k_req_ready) begin
                k_sent[k_req_context_tag] <= 1;
                k_outstanding[k_req_context_tag] <= 1;
                k_requests_accepted <= k_requests_accepted + 1;
            end

            if (q_rsp_valid) begin
                if ((state == ST_RUN) &&
                    active_mask[q_rsp_context_tag] &&
                    q_outstanding[q_rsp_context_tag] &&
                    !q_buffer_valid[q_rsp_context_tag]) begin
                    q_buffer[q_rsp_context_tag] <= q_rsp_bf16;
                    q_buffer_valid[q_rsp_context_tag] <= 1;
                    q_outstanding[q_rsp_context_tag] <= 0;
                end else begin
                    protocol_errors <= protocol_errors + 1;
                    protocol_error_sticky <= 1;
                end
            end
            if (k_rsp_valid) begin
                if ((state == ST_RUN) &&
                    active_mask[k_rsp_context_tag] &&
                    k_outstanding[k_rsp_context_tag] &&
                    !k_buffer_valid[k_rsp_context_tag]) begin
                    k_buffer[k_rsp_context_tag] <= k_rsp_vec;
                    k_buffer_valid[k_rsp_context_tag] <= 1;
                    k_outstanding[k_rsp_context_tag] <= 0;
                end else begin
                    protocol_errors <= protocol_errors + 1;
                    protocol_error_sticky <= 1;
                end
            end

            if (!mac_hold_valid && mac_select_valid &&
                mac_valid && !mac_ready) begin
                mac_hold_valid <= 1;
                mac_hold_context <= mac_select_context;
                mac_hold_q <= q_buffer[mac_select_context];
                mac_hold_k <= k_buffer[mac_select_context];
                mac_hold_lane_mask <= lane_mask_for(
                    ($unsigned(row_window_reg) * CONTEXTS) +
                    mac_select_context, key_block_reg);
            end

            if (mac_valid && mac_ready) begin
                q_buffer_valid[selected_context] <= 0;
                k_buffer_valid[selected_context] <= 0;
                mac_busy[selected_context] <= 1;
                mac_hold_valid <= 0;
                active_lanes = popcount32(selected_lane_mask);
                mac_steps_issued <= mac_steps_issued + 1;
                valid_macs <= valid_macs + active_lanes;
                causal_lane_bubbles <= causal_lane_bubbles +
                                       (LANES - active_lanes);
            end

            if (mac_rsp_valid && mac_rsp_ready) begin
                mac_rsp_matches =
                    active_mask[mac_rsp_context_tag] &&
                    mac_busy[mac_rsp_context_tag] &&
                    (mac_rsp_epoch == epoch_reg) &&
                    (mac_rsp_group == group_reg) &&
                    (mac_rsp_global_q_head == head_reg) &&
                    (mac_rsp_row ==
                     (($unsigned(row_window_reg) * CONTEXTS) +
                      mac_rsp_context_tag)) &&
                    (mac_rsp_key_block == key_block_reg) &&
                    (mac_rsp_d == d_reg);
                if (mac_rsp_matches) begin
                    mac_busy[mac_rsp_context_tag] <= 0;
                    result_done[mac_rsp_context_tag] <= 1;
                    mac_steps_completed <= mac_steps_completed + 1;
                end else begin
                    protocol_errors <= protocol_errors + 1;
                    protocol_error_sticky <= 1;
                end
            end

            case (state)
                ST_IDLE: begin
                    mac_hold_valid <= 0;
                    if (start_valid && start_ready) begin
                        epoch_reg <= start_epoch;
                        group_reg <= start_group;
                        head_reg <= start_global_q_head;
                        row_window_reg <= start_row_window;
                        key_block_reg <= start_key_block;
                        d_reg <= 0;
                        active_mask <= start_active_mask;
                        q_sent <= 0;
                        k_sent <= 0;
                        q_outstanding <= 0;
                        k_outstanding <= 0;
                        q_buffer_valid <= 0;
                        k_buffer_valid <= 0;
                        mac_busy <= 0;
                        result_done <= 0;
                        causal_rows_skipped <= causal_rows_skipped +
                            ($unsigned(start_row_count) -
                             popcount16(start_active_mask));
                        if (!start_fields_valid) begin
                            protocol_errors <= protocol_errors + 1;
                            protocol_error_sticky <= 1;
                            state <= ST_DONE;
                        end else if (start_active_mask == 0) begin
                            state <= ST_DONE;
                        end else begin
                            state <= ST_RUN;
                        end
                    end
                end
                ST_RUN: begin
                    if (all_results_done) begin
                        if (d_reg == HEAD_DIM-1) begin
                            state <= ST_DONE;
                        end else begin
                            d_reg <= d_reg + 1;
                            q_sent <= 0;
                            k_sent <= 0;
                            q_outstanding <= 0;
                            k_outstanding <= 0;
                            q_buffer_valid <= 0;
                            k_buffer_valid <= 0;
                            mac_busy <= 0;
                            result_done <= 0;
                            mac_hold_valid <= 0;
                        end
                    end
                end
                ST_DONE: begin
                    if (done_valid && done_ready) begin
                        state <= ST_IDLE;
                        active_mask <= 0;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

    initial begin
        if ((SEQ_LEN != 128) || (HEAD_DIM <= 0) ||
            (CONTEXTS != 16) || (LANES != 32))
            $error("cats_r4_qk_32lane_scheduler: requires S=128,R=16,lanes=32 and positive D");
    end
endmodule
