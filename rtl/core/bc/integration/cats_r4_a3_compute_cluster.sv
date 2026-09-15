`timescale 1ns/1ps

// Single CATS-R4 A3 compute cluster.  C-owned memories remain external.
module cats_r4_a3_compute_cluster #(
    parameter integer HEAD_DIM = 128,
    parameter logic [31:0] SCALE_FP32 = 32'h3db5_04f3,
    parameter EXP_LUT_FILE = "mem/exp_lut_q15.mem"
) (
    input logic clk, input logic rst_n, input logic clear,
    input logic counter_clear,
    input logic txn_start_valid, output logic txn_start_ready,
    input logic [15:0] txn_epoch, input logic [1:0] txn_numeric_mode,
    input logic job_valid, output logic job_ready,
    input logic [15:0] job_epoch, input logic [2:0] job_group,
    input logic [4:0] job_global_q_head,
    input logic [2:0] job_row_window,
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
    output logic cluster_quiescent
);
    logic client_job_ready;
    logic client_start_valid, client_start_ready;
    logic engine_start_valid, engine_start_ready;
    logic [15:0] client_start_epoch; logic [2:0] client_start_group;
    logic [4:0] client_start_head; logic [2:0] client_start_window;
    logic [3:0] client_start_row_offset; logic [4:0] client_start_row_count;
    logic [1:0] client_start_key_block; logic client_start_q_buffer;
    logic engine_done_valid, engine_done_ready, engine_done_error;
    logic [15:0] engine_done_epoch; logic [2:0] engine_done_group;
    logic [4:0] engine_done_head; logic [2:0] engine_done_window;
    logic [1:0] engine_done_key_block;
    wire [3:0] client_done_row_offset = client_start_row_offset;
    wire [4:0] client_done_row_count = client_start_row_count;
    logic client_engine_error_valid, client_engine_error_ready;
    logic [15:0] client_engine_error_epoch;
    logic [2:0] client_engine_error_group;
    logic [4:0] client_engine_error_head;
    logic [2:0] client_engine_error_window;
    logic [3:0] client_engine_error_row_offset;
    logic [4:0] client_engine_error_row_count;
    logic [1:0] client_engine_error_key_block;
    logic [63:0] unused64 [0:63]; logic unused_sticky [0:7];

    logic engine_score_valid, engine_score_ready;
    logic [15:0] engine_score_epoch; logic [2:0] engine_score_group;
    logic [4:0] engine_score_head; logic [6:0] engine_score_row;
    logic [1:0] engine_score_key_block;
    logic [3:0] engine_score_context_tag;
    logic [31:0] engine_score_lane_valid;
    logic [1023:0] engine_score_fp32;
    logic engine_q_req_valid, engine_q_req_ready;
    logic engine_k_req_valid, engine_k_req_ready;
    logic [2:0] q_rsp_pending, k_rsp_pending;
    logic q_rsp_admit, k_rsp_admit;
    logic frontend_raw_score_valid, frontend_raw_score_ready;
    logic row_frontend_raw_score_ready;
    logic frontend_txn_ready;

    logic b_row_valid, b_row_ready; logic [15:0] b_row_epoch;
    logic [2:0] b_row_group; logic [4:0] b_row_head;
    logic [6:0] b_row_index; logic [1:0] b_row_slot, b_row_mode;
    logic [15:0] b_row_max;
    logic b_score_valid, b_score_ready; logic [15:0] b_score_epoch;
    logic [2:0] b_score_group; logic [4:0] b_score_head;
    logic [6:0] b_score_row, b_score_key;
    logic [1:0] b_score_slot, b_score_mode;
    logic [15:0] b_score_data; logic b_score_last;
    logic final_release_valid, final_release_ready;
    logic [15:0] final_release_epoch; logic [2:0] final_release_group;
    logic [4:0] final_release_head; logic [6:0] final_release_row;
    logic [1:0] final_release_slot, final_release_mode;
    logic row_abort_valid, row_abort_ready; logic [15:0] row_abort_epoch;
    logic [2:0] row_abort_group; logic [4:0] row_abort_head;
    logic [6:0] row_abort_row, row_abort_key;
    logic [1:0] row_abort_slot, row_abort_mode;
    logic [2:0] row_abort_code;

    logic invalid_context_valid, qk_error_source_valid;
    logic qk_error_valid, qk_error_ready;
    logic qk_quarantine_safe;
    logic qk_arbiter_ready;
    logic [15:0] qk_error_epoch; logic [2:0] qk_error_group;
    logic [4:0] qk_error_head; logic [6:0] qk_error_row, qk_error_key;
    logic [1:0] qk_error_slot, qk_error_mode; logic [2:0] qk_error_code;
    logic a_side_valid, a_side_ready; logic [15:0] a_side_epoch;
    logic [2:0] a_side_group; logic [4:0] a_side_head;
    logic [6:0] a_side_row, a_side_key;
    logic [1:0] a_side_slot, a_side_mode; logic [2:0] a_side_code;
    logic b4_error_valid, b4_error_ready; logic [15:0] b4_error_epoch;
    logic [2:0] b4_error_group; logic [4:0] b4_error_head;
    logic [6:0] b4_error_row, b4_error_key;
    logic [1:0] b4_error_slot, b4_error_mode; logic [3:0] b4_error_code;

    assign job_ready = client_job_ready && !qk_fault_hold;
    assign txn_start_ready = frontend_txn_ready && !qk_fault_hold;
    assign engine_start_valid = client_start_valid && !qk_fault_hold;
    assign client_start_ready = engine_start_ready && !qk_fault_hold;
    assign q_req_valid = engine_q_req_valid && !qk_fault_hold;
    assign engine_q_req_ready = q_req_ready && !qk_fault_hold;
    assign k_req_valid = engine_k_req_valid && !qk_fault_hold;
    assign engine_k_req_ready = k_req_ready && !qk_fault_hold;
    assign q_rsp_admit = q_rsp_context_tag >= 3 ? 1'b1 :
                         q_rsp_pending[q_rsp_context_tag];
    assign k_rsp_admit = k_rsp_context_tag >= 3 ? 1'b1 :
                         k_rsp_pending[k_rsp_context_tag];
    assign invalid_context_valid = engine_score_valid &&
                                   engine_score_context_tag >= 3;
    assign qk_error_source_valid = client_engine_error_valid ||
                                   invalid_context_valid;
    // Public A-owned idle status for composition.  It is intentionally based
    // on registered ownership/pending state and visible handshakes, so an A4
    // wrapper never has to inspect implementation hierarchy.
    assign cluster_quiescent =
        !q_slab_need_valid && !q_slab_ready_ready && !client_start_valid &&
        !engine_done_ready && !client_engine_error_valid &&
        !q_slab_retire_valid && !qk_fault_hold &&
        !engine_start_valid && !engine_done_valid && !engine_score_valid &&
        !frontend_raw_score_valid && !b_row_valid && !b_score_valid &&
        !row_abort_valid && !weight_wr_valid && !row_commit_valid &&
        !weight_rd_req_valid && !v_req_valid && !out_valid &&
        !weight_release_valid && !final_release_valid && !error_valid &&
        q_rsp_pending == 0 && k_rsp_pending == 0 && slot_owner == 0;
    // Drain every presented and accepted memory request before exposing the
    // fault to the error join.  Entering quarantine earlier would discard a
    // response owed by the fixed-latency service.
    assign qk_quarantine_safe = !engine_q_req_valid && !engine_k_req_valid &&
                                q_rsp_pending == 0 && k_rsp_pending == 0;
    assign qk_error_valid = qk_error_source_valid && !qk_fault_hold &&
                            qk_quarantine_safe;
    assign qk_error_ready = qk_arbiter_ready && !qk_fault_hold &&
                            qk_quarantine_safe;
    assign client_engine_error_ready = qk_error_ready;
    assign frontend_raw_score_ready = row_frontend_raw_score_ready &&
                                      !qk_fault_hold;
    assign engine_score_ready = invalid_context_valid ?
        (!client_engine_error_valid && qk_error_ready) :
        (qk_fault_hold ? 1'b0 : frontend_raw_score_ready);
    assign frontend_raw_score_valid = engine_score_valid &&
                                      !invalid_context_valid && !qk_fault_hold;
    assign qk_error_epoch = client_engine_error_valid ?
        client_engine_error_epoch : engine_score_epoch;
    assign qk_error_group = client_engine_error_valid ?
        client_engine_error_group : engine_score_group;
    assign qk_error_head = client_engine_error_valid ?
        client_engine_error_head : engine_score_head;
    assign qk_error_row = client_engine_error_valid ?
        ({client_engine_error_window,4'b0}+client_engine_error_row_offset) :
        engine_score_row;
    assign qk_error_slot = 2'd0;
    assign qk_error_mode = txn_numeric_mode_locked;
    assign qk_error_code = 3'd7;
    assign qk_error_key = client_engine_error_valid ?
        {client_engine_error_key_block,5'b0} :
        {engine_score_key_block,5'b0};

    cats_r4_qk_q_slab_client u_q_slab_client (
        .clk(clk), .rst_n(rst_n), .clear(clear), .counter_clear(counter_clear),
        .job_valid(job_valid && !qk_fault_hold), .job_ready(client_job_ready),
        .job_epoch(job_epoch), .job_group(job_group),
        .job_global_q_head(job_global_q_head), .job_row_window(job_row_window),
        .q_slab_need_valid(q_slab_need_valid), .q_slab_need_ready(q_slab_need_ready),
        .q_slab_need_epoch(q_slab_need_epoch), .q_slab_need_group(q_slab_need_group),
        .q_slab_need_global_q_head(q_slab_need_global_q_head),
        .q_slab_need_row_window(q_slab_need_row_window),
        .q_slab_ready_valid(q_slab_ready_valid), .q_slab_ready_ready(q_slab_ready_ready),
        .q_slab_ready_epoch(q_slab_ready_epoch), .q_slab_ready_group(q_slab_ready_group),
        .q_slab_ready_global_q_head(q_slab_ready_global_q_head),
        .q_slab_ready_row_window(q_slab_ready_row_window),
        .q_slab_ready_buffer(q_slab_ready_buffer),
        .engine_start_valid(client_start_valid), .engine_start_ready(client_start_ready),
        .engine_start_epoch(client_start_epoch), .engine_start_group(client_start_group),
        .engine_start_global_q_head(client_start_head),
        .engine_start_row_window(client_start_window),
        .engine_start_row_offset(client_start_row_offset),
        .engine_start_row_count(client_start_row_count),
        .engine_start_key_block(client_start_key_block),
        .engine_start_q_buffer(client_start_q_buffer),
        .engine_done_valid(engine_done_valid), .engine_done_ready(engine_done_ready),
        .engine_done_epoch(engine_done_epoch), .engine_done_group(engine_done_group),
        .engine_done_global_q_head(engine_done_head),
        .engine_done_row_window(engine_done_window),
        .engine_done_row_offset(client_done_row_offset),
        .engine_done_row_count(client_done_row_count),
        .engine_done_key_block(engine_done_key_block),
        .engine_done_error(engine_done_error),
        .engine_error_valid(client_engine_error_valid),
        .engine_error_ready(client_engine_error_ready),
        .engine_error_epoch(client_engine_error_epoch),
        .engine_error_group(client_engine_error_group),
        .engine_error_global_q_head(client_engine_error_head),
        .engine_error_row_window(client_engine_error_window),
        .engine_error_row_offset(client_engine_error_row_offset),
        .engine_error_row_count(client_engine_error_row_count),
        .engine_error_key_block(client_engine_error_key_block),
        .q_slab_retire_valid(q_slab_retire_valid),
        .q_slab_retire_ready(q_slab_retire_ready),
        .q_slab_retire_epoch(q_slab_retire_epoch),
        .q_slab_retire_group(q_slab_retire_group),
        .q_slab_retire_global_q_head(q_slab_retire_global_q_head),
        .q_slab_retire_row_window(q_slab_retire_row_window),
        .q_slab_retire_buffer(q_slab_retire_buffer),
        .jobs_accepted(q_slab_jobs_accepted),
        .q_slab_needs_transferred(unused64[0]),
        .q_slab_ready_transferred(unused64[1]),
        .engine_jobs_started(engine_jobs_started),
        .engine_jobs_completed(unused64[2]), .q_slab_retires_transferred(unused64[3]),
        .engine_errors(unused64[4]), .error_reports(unused64[5]),
        .protocol_errors(unused64[6]), .epoch_drops(unused64[7]),
        .protocol_error_sticky(unused_sticky[0]));

    cats_r4_qk_32lane_engine #(.HEAD_DIM(HEAD_DIM)) u_qk_engine (
        .clk(clk), .rst_n(rst_n), .clear(clear), .counter_clear(counter_clear),
        .start_valid(engine_start_valid), .start_ready(engine_start_ready),
        .start_epoch(client_start_epoch), .start_group(client_start_group),
        .start_global_q_head(client_start_head), .start_row_window(client_start_window),
        .start_row_offset(client_start_row_offset), .start_row_count(client_start_row_count),
        .start_key_block(client_start_key_block),
        .done_valid(engine_done_valid), .done_ready(engine_done_ready),
        .done_epoch(engine_done_epoch), .done_group(engine_done_group),
        .done_global_q_head(engine_done_head), .done_row_window(engine_done_window),
        .done_key_block(engine_done_key_block), .done_error(engine_done_error),
        .q_req_valid(engine_q_req_valid), .q_req_ready(engine_q_req_ready),
        .q_req_context_tag(q_req_context_tag), .q_req_d(q_req_d),
        // Q/K responses are non-backpressured.  Fault hold quarantines and
        // discards old responses until clear resets the engine epoch/state.
        .q_rsp_valid(q_rsp_valid && !qk_fault_hold && q_rsp_admit),
        .q_rsp_context_tag(q_rsp_context_tag),
        .q_rsp_bf16(q_rsp_bf16), .k_req_valid(engine_k_req_valid),
        .k_req_ready(engine_k_req_ready), .k_req_context_tag(k_req_context_tag),
        .k_req_key_block(k_req_key_block), .k_req_d(k_req_d),
        .k_rsp_valid(k_rsp_valid && !qk_fault_hold && k_rsp_admit),
        .k_rsp_context_tag(k_rsp_context_tag),
        .k_rsp_vec(k_rsp_vec), .score_valid(engine_score_valid),
        .score_ready(engine_score_ready), .score_epoch(engine_score_epoch),
        .score_group(engine_score_group), .score_global_q_head(engine_score_head),
        .score_row(engine_score_row), .score_key_block(engine_score_key_block),
        .score_context_tag(engine_score_context_tag),
        .score_lane_valid(engine_score_lane_valid), .score_fp32(engine_score_fp32),
        .q_requests_accepted(unused64[8]), .k_requests_accepted(unused64[9]),
        .mac_steps_issued(unused64[10]), .mac_steps_completed(unused64[11]),
        .valid_macs(qk_valid_macs), .causal_lane_bubbles(unused64[12]),
        .causal_rows_skipped(unused64[13]), .memory_request_stalls(unused64[14]),
        .mac_issue_stalls(unused64[15]), .scheduler_protocol_errors(unused64[16]),
        .scheduler_protocol_error_sticky(unused_sticky[1]),
        .fp32_requests_accepted(unused64[17]),
        .fp32_mul_products_completed(unused64[18]),
        .fp32_add_results_completed(unused64[19]),
        .fp32_response_transfers(unused64[20]), .fp32_protocol_errors(unused64[21]),
        .fp32_protocol_error_sticky(unused_sticky[2]), .score_commits(unused64[22]),
        .score_commit_stalls(unused64[23]), .score_fifo_max_occupancy(unused64[24]));

    cats_r4_a3_row_frontend #(.SCALE_FP32(SCALE_FP32)) u_row_frontend (
        .clk(clk), .rst_n(rst_n), .clear(clear), .counter_clear(counter_clear),
        .txn_start_valid(txn_start_valid && !qk_fault_hold),
        .txn_start_ready(frontend_txn_ready), .txn_epoch(txn_epoch),
        .txn_numeric_mode(txn_numeric_mode), .raw_score_valid(frontend_raw_score_valid),
        .raw_score_ready(row_frontend_raw_score_ready), .raw_score_epoch(engine_score_epoch),
        .raw_score_group(engine_score_group),
        .raw_score_global_q_head(engine_score_head), .raw_score_row(engine_score_row),
        .raw_score_key_block(engine_score_key_block),
        .raw_score_context_tag(engine_score_context_tag),
        .raw_score_lane_valid(engine_score_lane_valid), .raw_score_fp32(engine_score_fp32),
        .b_row_valid(b_row_valid), .b_row_ready(b_row_ready), .b_row_epoch(b_row_epoch),
        .b_row_group(b_row_group), .b_row_global_q_head(b_row_head),
        .b_row_index(b_row_index), .b_row_slot_id(b_row_slot),
        .b_row_numeric_mode(b_row_mode), .b_row_max_bf16(b_row_max),
        .b_score_valid(b_score_valid), .b_score_ready(b_score_ready),
        .b_score_epoch(b_score_epoch), .b_score_group(b_score_group),
        .b_score_global_q_head(b_score_head), .b_score_row(b_score_row),
        .b_score_key(b_score_key), .b_score_slot_id(b_score_slot),
        .b_score_numeric_mode(b_score_mode), .b_score_bf16(b_score_data),
        .b_score_last(b_score_last), .final_release_valid(final_release_valid),
        .final_release_ready(final_release_ready), .final_release_epoch(final_release_epoch),
        .final_release_group(final_release_group),
        .final_release_global_q_head(final_release_head),
        .final_release_row(final_release_row), .final_release_slot_id(final_release_slot),
        .final_release_numeric_mode(final_release_mode), .row_abort_valid(row_abort_valid),
        .row_abort_ready(row_abort_ready), .row_abort_epoch(row_abort_epoch),
        .row_abort_group(row_abort_group), .row_abort_global_q_head(row_abort_head),
        .row_abort_row(row_abort_row), .row_abort_error_key(row_abort_key),
        .row_abort_slot_id(row_abort_slot), .row_abort_numeric_mode(row_abort_mode),
        .row_abort_error_code(row_abort_code), .slot_owner(slot_owner),
        .rows_completed(unused64[25]), .scores_transferred(scores_transferred),
        .rows_transferred(rows_transferred), .aborts(unused64[26]),
        .owner_errors(unused64[27]), .scale_requests_accepted(unused64[28]),
        .scale_products_completed(unused64[29]), .score_format_transfers(unused64[30]),
        .formatter_protocol_errors(unused64[31]), .score_write_vectors(unused64[32]),
        .score_write_scores(unused64[33]), .score_read_requests(unused64[34]),
        .score_read_responses(unused64[35]), .score_read_stall_cycles(unused64[36]),
        .score_memory_errors(unused64[37]), .context_slot_errors(unused64[38]),
        .a2_protocol_error_sticky(unused_sticky[3]),
        .score_memory_error_sticky(unused_sticky[4]),
        .context_slot_error_sticky(unused_sticky[5]),
        .protocol_error_sticky(unused_sticky[6]));

    cats_r4_qk_row_abort_arbiter u_a_side_error_arbiter (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .a_valid(row_abort_valid), .a_ready(row_abort_ready), .a_epoch(row_abort_epoch),
        .a_group(row_abort_group), .a_head(row_abort_head), .a_row(row_abort_row),
        .a_slot(row_abort_slot), .a_mode(row_abort_mode), .a_code(row_abort_code),
        .a_key(row_abort_key),
        .b_valid(qk_error_valid),
        .b_ready(qk_arbiter_ready),
        .b_epoch(qk_error_epoch), .b_group(qk_error_group), .b_head(qk_error_head),
        .b_row(qk_error_row), .b_slot(qk_error_slot), .b_mode(qk_error_mode),
        .b_code(qk_error_code), .b_key(qk_error_key), .out_valid(a_side_valid),
        .out_ready(a_side_ready), .out_epoch(a_side_epoch), .out_group(a_side_group),
        .out_head(a_side_head), .out_row(a_side_row), .out_slot(a_side_slot),
        .out_mode(a_side_mode), .out_code(a_side_code), .out_key(a_side_key));

    cats_r4_a3_error_join u_error_join (
        .clk(clk), .rst_n(rst_n), .clear(clear), .counter_clear(counter_clear),
        .a_valid(a_side_valid), .a_ready(a_side_ready), .a_epoch(a_side_epoch),
        .a_group(a_side_group), .a_global_q_head(a_side_head), .a_row(a_side_row),
        .a_slot_id(a_side_slot), .a_numeric_mode(a_side_mode), .a_code(a_side_code),
        .a_bad_key(a_side_key), .b_valid(b4_error_valid), .b_ready(b4_error_ready),
        .b_epoch(b4_error_epoch), .b_group(b4_error_group),
        .b_global_q_head(b4_error_head), .b_row(b4_error_row),
        .b_slot_id(b4_error_slot), .b_numeric_mode(b4_error_mode),
        .b_code(b4_error_code), .b_bad_key(b4_error_key), .error_valid(error_valid),
        .error_ready(error_ready), .error_source(error_source), .error_epoch(error_epoch),
        .error_group(error_group), .error_global_q_head(error_global_q_head),
        .error_row(error_row), .error_slot_id(error_slot_id),
        .error_numeric_mode(error_numeric_mode), .error_code(error_code),
        .error_bad_key(error_bad_key), .a_errors_accepted(unused64[39]),
        .b_errors_accepted(unused64[40]), .errors_delivered(unused64[41]),
        .simultaneous_errors(unused64[42]), .error_stall_cycles(unused64[43]));

    cats_r4_b4_softmax_pv_cluster #(.EXP_LUT_FILE(EXP_LUT_FILE)) u_b4 (
        .clk(clk), .rst_n(rst_n), .clear(clear), .counter_clear(counter_clear),
        .row_valid(b_row_valid), .row_ready(b_row_ready), .row_epoch(b_row_epoch),
        .row_group(b_row_group), .row_global_q_head(b_row_head), .row_index(b_row_index),
        .row_slot_id(b_row_slot), .row_numeric_mode(b_row_mode), .row_max_bf16(b_row_max),
        .score_valid(b_score_valid), .score_ready(b_score_ready),
        .score_epoch(b_score_epoch), .score_group(b_score_group),
        .score_global_q_head(b_score_head), .score_row(b_score_row),
        .score_slot_id(b_score_slot), .score_numeric_mode(b_score_mode),
        .score_key(b_score_key), .score_bf16(b_score_data), .score_last(b_score_last),
        .weight_wr_valid(weight_wr_valid), .weight_wr_ready(weight_wr_ready),
        .weight_wr_epoch(weight_wr_epoch), .weight_wr_group(weight_wr_group),
        .weight_wr_global_q_head(weight_wr_global_q_head), .weight_wr_row(weight_wr_row),
        .weight_wr_slot_id(weight_wr_slot_id),
        .weight_wr_numeric_mode(weight_wr_numeric_mode), .weight_wr_key(weight_wr_key),
        .weight_wr_mask(weight_wr_mask), .weight_wr_data(weight_wr_data),
        .weight_wr_last(weight_wr_last), .row_commit_valid(row_commit_valid),
        .row_commit_ready(row_commit_ready), .row_commit_epoch(row_commit_epoch),
        .row_commit_group(row_commit_group),
        .row_commit_global_q_head(row_commit_global_q_head), .row_commit_row(row_commit_row),
        .row_commit_slot_id(row_commit_slot_id),
        .row_commit_numeric_mode(row_commit_numeric_mode),
        .row_commit_sum_fp32(row_commit_sum_fp32),
        .row_commit_inv_sum_fp32(row_commit_inv_sum_fp32),
        .row_error_valid(b4_error_valid), .row_error_ready(b4_error_ready),
        .row_error_epoch(b4_error_epoch), .row_error_group(b4_error_group),
        .row_error_global_q_head(b4_error_head), .row_error_row(b4_error_row),
        .row_error_slot_id(b4_error_slot), .row_error_numeric_mode(b4_error_mode),
        .row_error_code(b4_error_code), .row_error_bad_key(b4_error_key),
        .pv_row_valid(pv_row_valid), .pv_row_ready(pv_row_ready),
        .pv_row_epoch(pv_row_epoch), .pv_row_group(pv_row_group),
        .pv_row_global_q_head(pv_row_global_q_head), .pv_row_row(pv_row_row),
        .pv_row_slot_id(pv_row_slot_id), .pv_row_numeric_mode(pv_row_numeric_mode),
        .pv_row_sum_fp32(pv_row_sum_fp32), .pv_row_inv_sum_fp32(pv_row_inv_sum_fp32),
        .weight_rd_req_valid(weight_rd_req_valid),
        .weight_rd_req_ready(weight_rd_req_ready),
        .weight_rd_req_epoch(weight_rd_req_epoch), .weight_rd_req_group(weight_rd_req_group),
        .weight_rd_req_global_q_head(weight_rd_req_global_q_head),
        .weight_rd_req_row(weight_rd_req_row), .weight_rd_req_slot_id(weight_rd_req_slot_id),
        .weight_rd_req_numeric_mode(weight_rd_req_numeric_mode),
        .weight_rd_req_key(weight_rd_req_key), .weight_rd_rsp_valid(weight_rd_rsp_valid),
        .weight_rd_rsp_epoch(weight_rd_rsp_epoch), .weight_rd_rsp_group(weight_rd_rsp_group),
        .weight_rd_rsp_global_q_head(weight_rd_rsp_global_q_head),
        .weight_rd_rsp_row(weight_rd_rsp_row), .weight_rd_rsp_slot_id(weight_rd_rsp_slot_id),
        .weight_rd_rsp_numeric_mode(weight_rd_rsp_numeric_mode),
        .weight_rd_rsp_key(weight_rd_rsp_key), .weight_rd_rsp_mask(weight_rd_rsp_mask),
        .weight_rd_rsp_data(weight_rd_rsp_data), .v_req_valid(v_req_valid),
        .v_req_ready(v_req_ready), .v_req_context_tag(v_req_context_tag),
        .v_req_key(v_req_key), .v_req_feature_block(v_req_feature_block),
        .v_rsp_valid(v_rsp_valid), .v_rsp_context_tag(v_rsp_context_tag),
        .v_rsp_vec_bf16(v_rsp_vec_bf16), .out_valid(out_valid), .out_ready(out_ready),
        .out_epoch(out_epoch), .out_seq(out_seq), .out_global_q_head(out_global_q_head),
        .out_row(out_row), .out_feature_block(out_feature_block),
        .out_data_bf16(out_data_bf16), .out_row_last(out_row_last),
        .out_tensor_last(out_tensor_last), .weight_release_valid(weight_release_valid),
        .weight_release_ready(weight_release_ready), .weight_release_epoch(weight_release_epoch),
        .weight_release_group(weight_release_group),
        .weight_release_global_q_head(weight_release_global_q_head),
        .weight_release_row(weight_release_row),
        .weight_release_slot_id(weight_release_slot_id),
        .weight_release_numeric_mode(weight_release_numeric_mode),
        .final_release_valid(final_release_valid), .final_release_ready(final_release_ready),
        .final_release_epoch(final_release_epoch), .final_release_group(final_release_group),
        .final_release_global_q_head(final_release_head), .final_release_row(final_release_row),
        .final_release_slot_id(final_release_slot),
        .final_release_numeric_mode(final_release_mode),
        .b2_rows_issue(unused64[44]), .b2_exp_issue(unused64[45]),
        .b2_exp_commit(b2_exp_commit), .b2_weight_writes(b2_weight_writes),
        .b2_row_commits(unused64[46]), .b2_slot_releases(unused64[47]),
        .b2_protocol_errors(unused64[48]), .b2_numeric_errors(unused64[49]),
        .b2_owner_errors(unused64[50]), .b3_pv_rows(unused64[51]),
        .b3_weight_requests(unused64[52]), .b3_weight_responses(unused64[53]),
        .b3_weight_consumes(unused64[54]), .b3_v_requests(unused64[55]),
        .b3_v_responses(unused64[56]), .b3_v_consumes(unused64[57]),
        .b3_pv_issue(unused64[58]), .b3_pv_result(unused64[59]),
        .b3_pv_commit(b3_pv_commit), .b3_context_words(b3_context_words),
        .b3_rows_released(unused64[60]), .b3_protocol_errors(unused64[61]),
        .b3_numeric_errors(unused64[62]), .b3_epoch_drops(unused64[63]),
        .final_release_count(final_release_count), .release_join_errors(),
        .error_sticky(unused_sticky[7]));

    integer rsp_pending_i;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            txn_numeric_mode_locked <= 0;
            qk_fault_hold <= 0;
            q_rsp_pending <= 0;
            k_rsp_pending <= 0;
        end else if (clear) begin
            txn_numeric_mode_locked <= 0;
            qk_fault_hold <= 0;
            q_rsp_pending <= 0;
            k_rsp_pending <= 0;
        end else begin
            if (txn_start_valid && txn_start_ready)
                txn_numeric_mode_locked <= txn_numeric_mode;
            if (qk_error_valid && qk_error_ready)
                qk_fault_hold <= 1;
            for (rsp_pending_i = 0; rsp_pending_i < 3;
                 rsp_pending_i = rsp_pending_i + 1) begin
                case ({q_req_valid && q_req_ready &&
                       q_req_context_tag == rsp_pending_i,
                       q_rsp_valid && q_rsp_admit &&
                       q_rsp_context_tag == rsp_pending_i})
                    2'b10: q_rsp_pending[rsp_pending_i] <= 1'b1;
                    2'b01: q_rsp_pending[rsp_pending_i] <= 1'b0;
                    2'b11: q_rsp_pending[rsp_pending_i] <= 1'b1;
                    default: q_rsp_pending[rsp_pending_i] <=
                             q_rsp_pending[rsp_pending_i];
                endcase
                case ({k_req_valid && k_req_ready &&
                       k_req_context_tag == rsp_pending_i,
                       k_rsp_valid && k_rsp_admit &&
                       k_rsp_context_tag == rsp_pending_i})
                    2'b10: k_rsp_pending[rsp_pending_i] <= 1'b1;
                    2'b01: k_rsp_pending[rsp_pending_i] <= 1'b0;
                    2'b11: k_rsp_pending[rsp_pending_i] <= 1'b1;
                    default: k_rsp_pending[rsp_pending_i] <=
                             k_rsp_pending[rsp_pending_i];
                endcase
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_count <= 0; first_issue_cycle <= 0; first_issue_cycle_valid <= 0;
            last_commit_cycle <= 0; last_commit_cycle_valid <= 0;
            slot0_occupied_cycles <= 0; slot1_occupied_cycles <= 0;
            slot2_occupied_cycles <= 0; row_stall_cycles <= 0;
            score_stall_cycles <= 0; weight_write_stall_cycles <= 0;
            row_commit_stall_cycles <= 0; weight_read_stall_cycles <= 0;
            v_request_stall_cycles <= 0; output_stall_cycles <= 0;
            error_stall_cycles <= 0; final_release_stall_cycles <= 0;
            q_slab_need_stall_cycles <= 0; q_slab_ready_stall_cycles <= 0;
            q_slab_retire_stall_cycles <= 0; q_request_stall_cycles <= 0;
            k_request_stall_cycles <= 0; pv_row_stall_cycles <= 0;
            weight_release_stall_cycles <= 0;
        end else if (counter_clear) begin
            cycle_count <= 0; first_issue_cycle <= 0; first_issue_cycle_valid <= 0;
            last_commit_cycle <= 0; last_commit_cycle_valid <= 0;
            slot0_occupied_cycles <= 0; slot1_occupied_cycles <= 0;
            slot2_occupied_cycles <= 0; row_stall_cycles <= 0;
            score_stall_cycles <= 0; weight_write_stall_cycles <= 0;
            row_commit_stall_cycles <= 0; weight_read_stall_cycles <= 0;
            v_request_stall_cycles <= 0; output_stall_cycles <= 0;
            error_stall_cycles <= 0; final_release_stall_cycles <= 0;
            q_slab_need_stall_cycles <= 0; q_slab_ready_stall_cycles <= 0;
            q_slab_retire_stall_cycles <= 0; q_request_stall_cycles <= 0;
            k_request_stall_cycles <= 0; pv_row_stall_cycles <= 0;
            weight_release_stall_cycles <= 0;
        end else begin
            cycle_count <= cycle_count + 1'b1;
            if (engine_start_valid && engine_start_ready && !first_issue_cycle_valid) begin
                first_issue_cycle <= cycle_count; first_issue_cycle_valid <= 1;
            end
            if (out_valid && out_ready && out_tensor_last) begin
                last_commit_cycle <= cycle_count; last_commit_cycle_valid <= 1;
            end
            if (slot_owner[1:0] != 0) slot0_occupied_cycles <= slot0_occupied_cycles+1'b1;
            if (slot_owner[3:2] != 0) slot1_occupied_cycles <= slot1_occupied_cycles+1'b1;
            if (slot_owner[5:4] != 0) slot2_occupied_cycles <= slot2_occupied_cycles+1'b1;
            if (b_row_valid && !b_row_ready) row_stall_cycles <= row_stall_cycles+1'b1;
            if (b_score_valid && !b_score_ready) score_stall_cycles <= score_stall_cycles+1'b1;
            if (weight_wr_valid && !weight_wr_ready) weight_write_stall_cycles <= weight_write_stall_cycles+1'b1;
            if (row_commit_valid && !row_commit_ready) row_commit_stall_cycles <= row_commit_stall_cycles+1'b1;
            if (weight_rd_req_valid && !weight_rd_req_ready) weight_read_stall_cycles <= weight_read_stall_cycles+1'b1;
            if (v_req_valid && !v_req_ready) v_request_stall_cycles <= v_request_stall_cycles+1'b1;
            if (out_valid && !out_ready) output_stall_cycles <= output_stall_cycles+1'b1;
            if (error_valid && !error_ready) error_stall_cycles <= error_stall_cycles+1'b1;
            if (final_release_valid && !final_release_ready) final_release_stall_cycles <= final_release_stall_cycles+1'b1;
            if (q_slab_need_valid && !q_slab_need_ready) q_slab_need_stall_cycles <= q_slab_need_stall_cycles+1'b1;
            if (q_slab_ready_valid && !q_slab_ready_ready) q_slab_ready_stall_cycles <= q_slab_ready_stall_cycles+1'b1;
            if (q_slab_retire_valid && !q_slab_retire_ready) q_slab_retire_stall_cycles <= q_slab_retire_stall_cycles+1'b1;
            if (q_req_valid && !q_req_ready) q_request_stall_cycles <= q_request_stall_cycles+1'b1;
            if (k_req_valid && !k_req_ready) k_request_stall_cycles <= k_request_stall_cycles+1'b1;
            if (pv_row_valid && !pv_row_ready) pv_row_stall_cycles <= pv_row_stall_cycles+1'b1;
            if (weight_release_valid && !weight_release_ready) weight_release_stall_cycles <= weight_release_stall_cycles+1'b1;
        end
    end

`ifndef SYNTHESIS
    logic [1:0] txn_mode_locked_previous;
    logic txn_mode_previous_valid;
    logic txn_start_fire_previous;
    logic [63:0] slot_allocations [0:2];
    logic [63:0] slot_handoffs [0:2];
    logic [63:0] slot_releases [0:2];
    logic [63:0] slot_aborts [0:2];
    integer lifecycle_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || clear) begin
            for (lifecycle_i = 0; lifecycle_i < 3; lifecycle_i = lifecycle_i + 1) begin
                slot_allocations[lifecycle_i] <= 0;
                slot_handoffs[lifecycle_i] <= 0;
                slot_releases[lifecycle_i] <= 0;
                slot_aborts[lifecycle_i] <= 0;
            end
        end else begin
            if (u_row_frontend.u_a2.u_rows.u_owner.reserve_valid &&
                u_row_frontend.u_a2.u_rows.u_owner.reserve_ready)
                slot_allocations[u_row_frontend.u_a2.u_rows.u_owner.reserve_slot_id] <=
                    slot_allocations[u_row_frontend.u_a2.u_rows.u_owner.reserve_slot_id] + 1'b1;
            if (u_row_frontend.u_a2.u_rows.u_owner.handoff_valid &&
                u_row_frontend.u_a2.u_rows.u_owner.handoff_ready)
                slot_handoffs[u_row_frontend.u_a2.u_rows.u_owner.handoff_slot_id] <=
                    slot_handoffs[u_row_frontend.u_a2.u_rows.u_owner.handoff_slot_id] + 1'b1;
            if (final_release_valid && final_release_ready && final_release_slot < 3)
                slot_releases[final_release_slot] <= slot_releases[final_release_slot] + 1'b1;
            if (row_abort_valid && row_abort_ready && row_abort_slot < 3)
                slot_aborts[row_abort_slot] <= slot_aborts[row_abort_slot] + 1'b1;
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            txn_mode_locked_previous <= 0;
            txn_mode_previous_valid <= 0;
            txn_start_fire_previous <= 0;
        end else if (clear) begin
            txn_mode_locked_previous <= 0;
            txn_mode_previous_valid <= 0;
            txn_start_fire_previous <= 0;
        end else begin
            if (txn_mode_previous_valid && !txn_start_fire_previous &&
                txn_numeric_mode_locked !== txn_mode_locked_previous)
                $fatal(1, "A3 transaction numeric mode lock changed without handshake");
            txn_mode_locked_previous <= txn_numeric_mode_locked;
            txn_mode_previous_valid <= 1;
            txn_start_fire_previous <= txn_start_valid && txn_start_ready;
        end
    end

    always_ff @(posedge clk) if (rst_n && !clear) begin
        assert (!(job_valid && job_ready && qk_fault_hold));
        assert (!(frontend_raw_score_valid && row_frontend_raw_score_ready &&
                  qk_fault_hold));
        assert (!(final_release_valid && final_release_ready &&
                  final_release_slot >= 3));
        assert (!(qk_error_valid && !qk_quarantine_safe));
        if (qk_fault_hold)
            assert (q_rsp_pending == 0 && k_rsp_pending == 0);
        assert (slot_allocations[0] == slot_releases[0] + slot_aborts[0] +
                (slot_owner[1:0] != 0));
        assert (slot_allocations[1] == slot_releases[1] + slot_aborts[1] +
                (slot_owner[3:2] != 0));
        assert (slot_allocations[2] == slot_releases[2] + slot_aborts[2] +
                (slot_owner[5:4] != 0));
        assert (slot_handoffs[0] <= slot_allocations[0]);
        assert (slot_handoffs[1] <= slot_allocations[1]);
        assert (slot_handoffs[2] <= slot_allocations[2]);
        assert (slot_releases[0] <= slot_handoffs[0]);
        assert (slot_releases[1] <= slot_handoffs[1]);
        assert (slot_releases[2] <= slot_handoffs[2]);
        if (engine_start_valid && engine_start_ready && client_start_row_count > 3)
            $fatal(1, "A3 engine launch row_count exceeds three");
        if (b_row_valid && b_row_ready && b_row_mode !== txn_numeric_mode_locked)
            $fatal(1, "A3 accepted row mode differs from locked transaction mode");
        if (final_release_valid && final_release_ready &&
            final_release_mode !== txn_numeric_mode_locked)
            $fatal(1, "A3 release mode differs from locked transaction mode");
        if (error_valid && error_ready && error_numeric_mode !== txn_numeric_mode_locked)
            $fatal(1, "A3 error mode differs from locked transaction mode");
        if (qk_fault_hold) begin
            if (engine_start_valid !== 1'b0 ||
                (engine_start_valid && engine_start_ready))
                $fatal(1, "A3 engine start escaped QK fault quarantine");
            if (q_req_valid !== 1'b0 || engine_q_req_ready !== 1'b0 ||
                (q_req_valid && q_req_ready) ||
                (engine_q_req_valid && engine_q_req_ready))
                $fatal(1, "A3 Q request escaped QK fault quarantine");
            if (k_req_valid !== 1'b0 || engine_k_req_ready !== 1'b0 ||
                (k_req_valid && k_req_ready) ||
                (engine_k_req_valid && engine_k_req_ready))
                $fatal(1, "A3 K request escaped QK fault quarantine");
            if (frontend_raw_score_valid && row_frontend_raw_score_ready)
                $fatal(1, "A3 raw score escaped QK fault quarantine");
            if (job_valid && job_ready)
                $fatal(1, "A3 job escaped QK fault quarantine");
        end
    end
`endif
endmodule
