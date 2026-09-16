`timescale 1ns/1ps

// A4 outer composition. P5 intentionally freezes the production N=1 path:
// one real A3 cluster plus the group-to-job control adapter. C-owned services
// remain external and keep the exact A3 payload/handshake contract.
module cats_r4_a4_compute_array #(
    parameter integer HEAD_DIM = 128,
    parameter logic [31:0] SCALE_FP32 = 32'h3db5_04f3,
    parameter EXP_LUT_FILE = "mem/exp_lut_q15.mem",
    parameter integer CLUSTERS = 1,
    parameter integer CLUSTER_ID = 0
) (
    input logic clk, input logic rst_n, input logic clear,
    input logic counter_clear,
    input logic txn_start_valid, output logic txn_start_ready,
    input logic [15:0] txn_epoch, input logic [1:0] txn_numeric_mode,
    output logic q_slab_need_valid, input logic q_slab_need_ready,
    output logic [15:0] q_slab_need_epoch,
    output logic [2:0] q_slab_need_group,
    output logic [4:0] q_slab_need_global_q_head,
    output logic [2:0] q_slab_need_row_window,
    input logic q_slab_ready_valid, output logic q_slab_ready_ready,
    input logic [15:0] q_slab_ready_epoch,
    input logic [2:0] q_slab_ready_group,
    input logic [4:0] q_slab_ready_global_q_head,
    input logic [2:0] q_slab_ready_row_window,
    input logic q_slab_ready_buffer,
    output logic q_slab_retire_valid, input logic q_slab_retire_ready,
    output logic [15:0] q_slab_retire_epoch,
    output logic [2:0] q_slab_retire_group,
    output logic [4:0] q_slab_retire_global_q_head,
    output logic [2:0] q_slab_retire_row_window,
    output logic q_slab_retire_buffer,
    output logic q_req_valid, input logic q_req_ready,
    output logic [3:0] q_req_context_tag, output logic [6:0] q_req_d,
    input logic q_rsp_valid, input logic [3:0] q_rsp_context_tag,
    input logic [15:0] q_rsp_bf16,
    output logic k_req_valid, input logic k_req_ready,
    output logic [3:0] k_req_context_tag,
    output logic [1:0] k_req_key_block, output logic [6:0] k_req_d,
    input logic k_rsp_valid, input logic [3:0] k_rsp_context_tag,
    input logic [511:0] k_rsp_vec,
    output logic weight_wr_valid, input logic weight_wr_ready,
    output logic [15:0] weight_wr_epoch,
    output logic [2:0] weight_wr_group,
    output logic [4:0] weight_wr_global_q_head,
    output logic [6:0] weight_wr_row,
    output logic [1:0] weight_wr_slot_id,
    output logic [1:0] weight_wr_numeric_mode,
    output logic [6:0] weight_wr_key, output logic weight_wr_mask,
    output logic [31:0] weight_wr_data, output logic weight_wr_last,
    output logic row_commit_valid, input logic row_commit_ready,
    output logic [15:0] row_commit_epoch,
    output logic [2:0] row_commit_group,
    output logic [4:0] row_commit_global_q_head,
    output logic [6:0] row_commit_row,
    output logic [1:0] row_commit_slot_id,
    output logic [1:0] row_commit_numeric_mode,
    output logic [31:0] row_commit_sum_fp32,
    output logic [31:0] row_commit_inv_sum_fp32,
    input logic pv_row_valid, output logic pv_row_ready,
    input logic [15:0] pv_row_epoch, input logic [2:0] pv_row_group,
    input logic [4:0] pv_row_global_q_head,
    input logic [6:0] pv_row_row, input logic [1:0] pv_row_slot_id,
    input logic [1:0] pv_row_numeric_mode,
    input logic [31:0] pv_row_sum_fp32,
    input logic [31:0] pv_row_inv_sum_fp32,
    output logic weight_rd_req_valid, input logic weight_rd_req_ready,
    output logic [15:0] weight_rd_req_epoch,
    output logic [2:0] weight_rd_req_group,
    output logic [4:0] weight_rd_req_global_q_head,
    output logic [6:0] weight_rd_req_row,
    output logic [1:0] weight_rd_req_slot_id,
    output logic [1:0] weight_rd_req_numeric_mode,
    output logic [6:0] weight_rd_req_key,
    input logic weight_rd_rsp_valid,
    input logic [15:0] weight_rd_rsp_epoch,
    input logic [2:0] weight_rd_rsp_group,
    input logic [4:0] weight_rd_rsp_global_q_head,
    input logic [6:0] weight_rd_rsp_row,
    input logic [1:0] weight_rd_rsp_slot_id,
    input logic [1:0] weight_rd_rsp_numeric_mode,
    input logic [6:0] weight_rd_rsp_key,
    input logic weight_rd_rsp_mask, input logic [31:0] weight_rd_rsp_data,
    output logic v_req_valid, input logic v_req_ready,
    output logic [3:0] v_req_context_tag, output logic [6:0] v_req_key,
    output logic [1:0] v_req_feature_block,
    input logic v_rsp_valid, input logic [3:0] v_rsp_context_tag,
    input logic [511:0] v_rsp_vec_bf16,
    output logic out_valid, input logic out_ready,
    output logic [15:0] out_epoch, output logic [11:0] out_seq,
    output logic [4:0] out_global_q_head, output logic [6:0] out_row,
    output logic [1:0] out_feature_block,
    output logic [511:0] out_data_bf16,
    output logic out_row_last, output logic out_tensor_last,
    output logic weight_release_valid, input logic weight_release_ready,
    output logic [15:0] weight_release_epoch,
    output logic [2:0] weight_release_group,
    output logic [4:0] weight_release_global_q_head,
    output logic [6:0] weight_release_row,
    output logic [1:0] weight_release_slot_id,
    output logic [1:0] weight_release_numeric_mode,
    output logic error_valid, input logic error_ready,
    output logic [1:0] error_source, output logic [15:0] error_epoch,
    output logic [2:0] error_group,
    output logic [4:0] error_global_q_head,
    output logic [6:0] error_row, output logic [1:0] error_slot_id,
    output logic [1:0] error_numeric_mode,
    output logic [3:0] error_code, output logic [6:0] error_bad_key,
    output logic [5:0] slot_owner,
    output logic [1:0] txn_numeric_mode_locked,
    output logic qk_fault_hold,
    output logic [63:0] cycle_count,
    output logic [63:0] first_issue_cycle,
    output logic first_issue_cycle_valid,
    output logic [63:0] last_commit_cycle,
    output logic last_commit_cycle_valid,
    output logic [63:0] slot0_occupied_cycles,
    output logic [63:0] slot1_occupied_cycles,
    output logic [63:0] slot2_occupied_cycles,
    output logic [63:0] row_stall_cycles,
    output logic [63:0] score_stall_cycles,
    output logic [63:0] weight_write_stall_cycles,
    output logic [63:0] row_commit_stall_cycles,
    output logic [63:0] weight_read_stall_cycles,
    output logic [63:0] v_request_stall_cycles,
    output logic [63:0] output_stall_cycles,
    output logic [63:0] error_stall_cycles,
    output logic [63:0] final_release_stall_cycles,
    output logic [63:0] q_slab_need_stall_cycles,
    output logic [63:0] q_slab_ready_stall_cycles,
    output logic [63:0] q_slab_retire_stall_cycles,
    output logic [63:0] q_request_stall_cycles,
    output logic [63:0] k_request_stall_cycles,
    output logic [63:0] pv_row_stall_cycles,
    output logic [63:0] weight_release_stall_cycles,
    output logic [63:0] q_slab_jobs_accepted,
    output logic [63:0] engine_jobs_started,
    output logic [63:0] qk_valid_macs,
    output logic [63:0] rows_transferred,
    output logic [63:0] scores_transferred,
    output logic [63:0] b2_exp_commit,
    output logic [63:0] b2_weight_writes,
    output logic [63:0] b3_pv_commit,
    output logic [63:0] b3_context_words,
    output logic [63:0] final_release_count,
    output logic cluster_quiescent,
    input logic group_cmd_valid, output logic group_cmd_ready,
    input logic [15:0] group_cmd_epoch,
    input logic [2:0] group_cmd_group,
    input logic [2:0] group_cmd_local_index,
    input logic [1:0] group_cmd_numeric_mode,
    input logic group_cmd_kv_buffer,
    output logic group_kv_buffer,
    input logic group_abort,
    output logic group_done_valid, input logic group_done_ready,
    output logic [15:0] group_done_epoch,
    output logic [2:0] group_done_group,
    output logic [2:0] group_done_local_index,
    output logic [1:0] group_done_numeric_mode,
    output logic group_done_aborted,
    output logic group_done_error,
    output logic control_error_valid, input logic control_error_ready,
    output logic [3:0] control_error_code,
    output logic [15:0] control_error_epoch,
    output logic [2:0] control_error_group,
    output logic [2:0] control_error_local_index,
    output logic group_adapter_busy,
    output logic txn_active_status,
    output logic [63:0] groups_accepted,
    output logic [63:0] groups_completed,
    output logic [63:0] groups_aborted,
    output logic [63:0] group_jobs_accepted,
    output logic [63:0] group_retires_accepted
);
    logic a3_txn_start_valid, a3_txn_start_ready;
    logic a3_job_valid, a3_job_ready;
    logic [15:0] a3_job_epoch;
    logic [2:0] a3_job_group;
    logic [4:0] a3_job_global_q_head;
    logic [2:0] a3_job_row_window;
    logic txn_active;
    logic [15:0] txn_epoch_locked;

    assign txn_start_ready = !txn_active && a3_txn_start_ready;
    assign a3_txn_start_valid = txn_start_valid && !txn_active;
    assign txn_active_status = txn_active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            txn_active <= 1'b0;
            txn_epoch_locked <= '0;
        end else if (clear) begin
            txn_active <= 1'b0;
            txn_epoch_locked <= '0;
        end else if (txn_start_valid && txn_start_ready) begin
            txn_active <= 1'b1;
            txn_epoch_locked <= txn_epoch;
        end
    end

    cats_r4_a4_group_job_adapter #(
        .CLUSTERS(CLUSTERS),
        .CLUSTER_ID(CLUSTER_ID)
    ) u_group_adapter (
        .clk,
        .rst_n,
        .clear,
        .counter_clear,
        .txn_active,
        .txn_epoch(txn_epoch_locked),
        .txn_numeric_mode(txn_numeric_mode_locked),
        .group_cmd_valid,
        .group_cmd_ready,
        .group_cmd_epoch,
        .group_cmd_group,
        .group_cmd_local_index,
        .group_cmd_numeric_mode,
        .group_cmd_kv_buffer,
        .job_valid(a3_job_valid),
        .job_ready(a3_job_ready),
        .job_epoch(a3_job_epoch),
        .job_group(a3_job_group),
        .job_global_q_head(a3_job_global_q_head),
        .job_row_window(a3_job_row_window),
        .group_kv_buffer,
        .retire_valid(q_slab_retire_valid),
        .retire_ready(q_slab_retire_ready),
        .retire_epoch(q_slab_retire_epoch),
        .retire_group(q_slab_retire_group),
        .retire_head(q_slab_retire_global_q_head),
        .retire_window(q_slab_retire_row_window),
        .context_words(b3_context_words),
        .final_release_count,
        .slot_owner,
        .cluster_quiescent,
        .cluster_error_seen(error_valid),
        .group_abort,
        .group_done_valid,
        .group_done_ready,
        .group_done_epoch,
        .group_done_group,
        .group_done_local_index,
        .group_done_numeric_mode,
        .group_done_aborted,
        .group_done_error,
        .protocol_error_valid(control_error_valid),
        .protocol_error_ready(control_error_ready),
        .protocol_error_code(control_error_code),
        .protocol_error_epoch(control_error_epoch),
        .protocol_error_group(control_error_group),
        .protocol_error_local_index(control_error_local_index),
        .busy(group_adapter_busy),
        .groups_accepted,
        .groups_completed,
        .groups_aborted,
        .jobs_accepted(group_jobs_accepted),
        .retires_accepted(group_retires_accepted)
    );

    cats_r4_a3_compute_cluster #(
        .HEAD_DIM(HEAD_DIM),
        .SCALE_FP32(SCALE_FP32),
        .EXP_LUT_FILE(EXP_LUT_FILE)
    ) u_cluster (
        .txn_start_valid(a3_txn_start_valid),
        .txn_start_ready(a3_txn_start_ready),
        .job_valid(a3_job_valid),
        .job_ready(a3_job_ready),
        .job_epoch(a3_job_epoch),
        .job_group(a3_job_group),
        .job_global_q_head(a3_job_global_q_head),
        .job_row_window(a3_job_row_window),
        .*
    );

`ifndef SYNTHESIS
    initial begin
        if (!(CLUSTERS == 1 || CLUSTERS == 2 || CLUSTERS == 4))
            $fatal(1, "cats_r4_a4_compute_array: CLUSTERS must be 1, 2, or 4");
        if (CLUSTER_ID < 0 || CLUSTER_ID >= CLUSTERS)
            $fatal(1, "cats_r4_a4_compute_array: CLUSTER_ID out of range");
    end
`endif
endmodule
