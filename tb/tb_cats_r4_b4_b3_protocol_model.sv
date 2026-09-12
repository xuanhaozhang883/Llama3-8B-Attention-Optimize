`timescale 1ns/1ps

// Test-only replacement for the B3 arithmetic wrapper.  It instantiates the
// real B3 controller and supplies deterministic one-cycle MAC/normalize
// services for the all-equal-score/all-one-V B4 workload.  The service checks
// every forwarded weight, numerator and inv_sum; it is not synthesis RTL and
// is compiled only by the B4 protocol regression.
module cats_r4_b3_pv_32lane (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         clear,
    input  logic         counter_clear,
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
    output logic         weight_release_valid,
    input  logic         weight_release_ready,
    output logic [15:0]  weight_release_epoch,
    output logic [2:0]   weight_release_group,
    output logic [4:0]   weight_release_global_q_head,
    output logic [6:0]   weight_release_row,
    output logic [1:0]   weight_release_slot_id,
    output logic [1:0]   weight_release_numeric_mode,
    output logic [63:0]  pv_rows_accepted,
    output logic [63:0]  weight_rd_requests,
    output logic [63:0]  weight_rd_responses,
    output logic [63:0]  weight_rd_consumes,
    output logic [63:0]  v_requests,
    output logic [63:0]  v_responses,
    output logic [63:0]  v_consumes,
    output logic [63:0]  pv_mac_issue,
    output logic [63:0]  pv_mac_result,
    output logic [63:0]  pv_mac_commit,
    output logic [63:0]  context_words,
    output logic [63:0]  rows_released,
    output logic [63:0]  raw_scoreboard_stalls,
    output logic [63:0]  weight_stall_cycles,
    output logic [63:0]  v_stall_cycles,
    output logic [63:0]  mac_stall_cycles,
    output logic [63:0]  output_stall_cycles,
    output logic [63:0]  protocol_error_count,
    output logic [63:0]  numeric_error_count,
    output logic [63:0]  epoch_drop_count,
    output logic [63:0]  arithmetic_vector_issue,
    output logic [63:0]  arithmetic_lane_products,
    output logic [63:0]  arithmetic_lane_commits,
    output logic [63:0]  normalize_issue_count,
    output logic [63:0]  normalize_result_count,
    output logic [63:0]  arithmetic_protocol_errors,
    output logic [63:0]  arithmetic_numeric_errors,
    output logic         error_sticky
);
    logic mac_valid, mac_ready;
    logic [3:0] mac_context_tag;
    logic [6:0] mac_key;
    logic mac_first, mac_last;
    logic [1:0] mac_numeric_mode;
    logic [31:0] mac_weight_data;
    logic [511:0] mac_v_vec_bf16;
    logic mac_rsp_valid, mac_rsp_ready;
    logic [3:0] mac_rsp_context_tag;
    logic [6:0] mac_rsp_key;
    logic mac_rsp_last;
    logic [1023:0] mac_rsp_accum_fp32;
    logic norm_valid, norm_ready;
    logic [3:0] norm_context_tag;
    logic [1023:0] norm_numerator_fp32;
    logic [31:0] norm_inv_sum_fp32;
    logic norm_rsp_valid, norm_rsp_ready;
    logic [3:0] norm_rsp_context_tag;
    logic [511:0] norm_rsp_context_bf16;
    logic controller_error_sticky;
    logic model_error_sticky;
    logic [6:0] accepted_row [0:2];
    logic [1:0] accepted_mode [0:2];
    logic [31:0] accepted_inv [0:2];
    integer idx;

    function automatic logic [31:0] positive_integer_fp32(
        input integer value
    );
        integer msb;
        integer scan;
        integer fraction;
        begin
            if (value == 0) begin
                positive_integer_fp32 = 32'd0;
            end else begin
                msb = 0;
                for (scan = 0; scan < 8; scan = scan + 1)
                    if (value >= (1 << scan))
                        msb = scan;
                fraction = (value - (1 << msb)) << (23-msb);
                positive_integer_fp32 = ((127+msb) << 23) | fraction;
            end
        end
    endfunction

    assign mac_ready = !mac_rsp_valid || mac_rsp_ready;
    assign norm_ready = !norm_rsp_valid || norm_rsp_ready;
    assign norm_rsp_context_bf16 = {32{16'h3f80}};
    assign error_sticky = controller_error_sticky || model_error_sticky;

    cats_r4_b3_pv_controller u_controller (
        .*, .error_sticky(controller_error_sticky)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        integer slot;
        if (!rst_n) begin
            mac_rsp_valid <= 1'b0;
            mac_rsp_context_tag <= '0;
            mac_rsp_key <= '0;
            mac_rsp_last <= 1'b0;
            mac_rsp_accum_fp32 <= '0;
            norm_rsp_valid <= 1'b0;
            norm_rsp_context_tag <= '0;
            model_error_sticky <= 1'b0;
            arithmetic_vector_issue <= '0;
            arithmetic_lane_products <= '0;
            arithmetic_lane_commits <= '0;
            normalize_issue_count <= '0;
            normalize_result_count <= '0;
            arithmetic_protocol_errors <= '0;
            arithmetic_numeric_errors <= '0;
            for (idx = 0; idx < 3; idx = idx + 1) begin
                accepted_row[idx] <= '0;
                accepted_mode[idx] <= '0;
                accepted_inv[idx] <= '0;
            end
        end else if (clear) begin
            mac_rsp_valid <= 1'b0;
            norm_rsp_valid <= 1'b0;
            model_error_sticky <= 1'b0;
        end else begin
            if (pv_row_valid && pv_row_ready) begin
                if (pv_row_slot_id >= 3 ||
                    pv_row_sum_fp32 !=
                        positive_integer_fp32(pv_row_row+1))
                    $fatal(1, "B4 model row sum mismatch");
                accepted_row[pv_row_slot_id] <= pv_row_row;
                accepted_mode[pv_row_slot_id] <= pv_row_numeric_mode;
                accepted_inv[pv_row_slot_id] <= pv_row_inv_sum_fp32;
            end

            if (mac_rsp_valid && mac_rsp_ready)
                mac_rsp_valid <= 1'b0;
            if (mac_valid && mac_ready) begin
                slot = mac_context_tag[3:2];
                if (mac_context_tag >= 12 ||
                    mac_numeric_mode != accepted_mode[slot] ||
                    mac_first != (mac_key == 0) ||
                    mac_last != (mac_key == accepted_row[slot]) ||
                    mac_v_vec_bf16 != {32{16'h3f80}} ||
                    (mac_numeric_mode == 0 &&
                     mac_weight_data != 32'h00003f80) ||
                    (mac_numeric_mode == 1 &&
                     mac_weight_data != 32'h3f800000))
                    $fatal(1, "B4 model MAC numeric propagation mismatch");
                mac_rsp_valid <= 1'b1;
                mac_rsp_context_tag <= mac_context_tag;
                mac_rsp_key <= mac_key;
                mac_rsp_last <= mac_last;
                for (idx = 0; idx < 32; idx = idx + 1)
                    mac_rsp_accum_fp32[idx*32 +: 32] <=
                        positive_integer_fp32(mac_key+1);
                arithmetic_vector_issue <= arithmetic_vector_issue + 1'b1;
                arithmetic_lane_products <= arithmetic_lane_products + 32;
                arithmetic_lane_commits <= arithmetic_lane_commits + 32;
            end

            if (norm_rsp_valid && norm_rsp_ready)
                norm_rsp_valid <= 1'b0;
            if (norm_valid && norm_ready) begin
                slot = norm_context_tag[3:2];
                if (norm_context_tag >= 12 ||
                    norm_inv_sum_fp32 != accepted_inv[slot])
                    $fatal(1, "B4 model reciprocal propagation mismatch");
                for (idx = 0; idx < 32; idx = idx + 1)
                    if (norm_numerator_fp32[idx*32 +: 32] !=
                        positive_integer_fp32(accepted_row[slot]+1))
                        $fatal(1, "B4 model numerator mismatch");
                norm_rsp_valid <= 1'b1;
                norm_rsp_context_tag <= norm_context_tag;
                normalize_issue_count <= normalize_issue_count + 1'b1;
            end
            if (norm_rsp_valid && norm_rsp_ready)
                normalize_result_count <= normalize_result_count + 1'b1;

            if (counter_clear) begin
                arithmetic_vector_issue <= '0;
                arithmetic_lane_products <= '0;
                arithmetic_lane_commits <= '0;
                normalize_issue_count <= '0;
                normalize_result_count <= '0;
                arithmetic_protocol_errors <= '0;
                arithmetic_numeric_errors <= '0;
            end
        end
    end
endmodule
