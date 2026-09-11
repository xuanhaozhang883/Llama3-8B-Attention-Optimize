`timescale 1ns/1ps

// CATS-R4 B3 unit-development wrapper.  Public ports are restricted to the
// frozen V3 pv_row/weight channels, the frozen v1 V service, and the frozen
// cluster output shape.  No board or production top is modified here.
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
    logic controller_error_sticky, mac_error_sticky, norm_error_sticky;
    logic [63:0] mac_input_stalls, mac_output_stalls;
    logic [63:0] norm_output_stalls;
    assign error_sticky = controller_error_sticky || mac_error_sticky ||
                          norm_error_sticky;

    cats_r4_b3_pv_controller u_controller (
        .*, .error_sticky(controller_error_sticky)
    );

    cats_r4_b3_pv_mac_32lane u_mac (
        .clk, .rst_n, .clear, .counter_clear,
        .mac_valid, .mac_ready, .mac_context_tag, .mac_key,
        .mac_first, .mac_last, .mac_numeric_mode, .mac_weight_data,
        .mac_v_vec_bf16, .mac_rsp_valid, .mac_rsp_ready,
        .mac_rsp_context_tag, .mac_rsp_key, .mac_rsp_last,
        .mac_rsp_accum_fp32,
        .vector_issue_count(arithmetic_vector_issue),
        .lane_product_count(arithmetic_lane_products),
        .lane_commit_count(arithmetic_lane_commits),
        .input_stall_cycles(mac_input_stalls),
        .output_stall_cycles(mac_output_stalls),
        .protocol_error_count(arithmetic_protocol_errors),
        .error_sticky(mac_error_sticky)
    );

    cats_r4_b3_pv_normalize_32lane u_normalize (
        .clk, .rst_n, .clear, .counter_clear,
        .norm_valid, .norm_ready, .norm_context_tag,
        .norm_numerator_fp32, .norm_inv_sum_fp32,
        .norm_rsp_valid, .norm_rsp_ready, .norm_rsp_context_tag,
        .norm_rsp_context_bf16, .normalize_issue_count,
        .normalize_result_count,
        .output_stall_cycles(norm_output_stalls),
        .numeric_error_count(arithmetic_numeric_errors),
        .error_sticky(norm_error_sticky)
    );

    logic unused_service_stalls;
    assign unused_service_stalls = |mac_input_stalls |
                                   |mac_output_stalls |
                                   |norm_output_stalls;
endmodule
