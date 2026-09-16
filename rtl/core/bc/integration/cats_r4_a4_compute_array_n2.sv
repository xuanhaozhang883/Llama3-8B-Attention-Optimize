`timescale 1ns/1ps

// P6 N=2 compute composition.  All compute-facing data services remain
// physically separate.  C-owned finite spools, canonical serialization, DMA,
// and durable completion remain outside this boundary.
module cats_r4_a4_compute_array_n2 #(
    parameter integer HEAD_DIM = 128,
    parameter logic [31:0] SCALE_FP32 = 32'h3db5_04f3,
    parameter EXP_LUT_FILE = "mem/exp_lut_q15.mem"
) (
    input  logic clk,
    input  logic rst_n,
    input  logic clear,
    input  logic counter_clear,

    input  logic txn_start_valid,
    output logic txn_start_ready,
    input  logic [15:0] txn_epoch,
    input  logic [1:0] txn_numeric_mode,
    input  logic txn_drain_complete,
    input  logic abort_request,
    output logic txn_active,
    output logic [15:0] txn_epoch_locked,
    output logic [1:0] txn_numeric_mode_locked,
    output logic [1:0] cluster_started,
    output logic all_clusters_started,
    output logic global_halt,

    output logic [1:0] q_slab_need_valid,
    input  logic [1:0] q_slab_need_ready,
    output logic [1:0][15:0] q_slab_need_epoch,
    output logic [1:0][2:0] q_slab_need_group,
    output logic [1:0][4:0] q_slab_need_global_q_head,
    output logic [1:0][2:0] q_slab_need_row_window,
    input  logic [1:0] q_slab_ready_valid,
    output logic [1:0] q_slab_ready_ready,
    input  logic [1:0][15:0] q_slab_ready_epoch,
    input  logic [1:0][2:0] q_slab_ready_group,
    input  logic [1:0][4:0] q_slab_ready_global_q_head,
    input  logic [1:0][2:0] q_slab_ready_row_window,
    input  logic [1:0] q_slab_ready_buffer,
    output logic [1:0] q_slab_retire_valid,
    input  logic [1:0] q_slab_retire_ready,
    output logic [1:0][15:0] q_slab_retire_epoch,
    output logic [1:0][2:0] q_slab_retire_group,
    output logic [1:0][4:0] q_slab_retire_global_q_head,
    output logic [1:0][2:0] q_slab_retire_row_window,
    output logic [1:0] q_slab_retire_buffer,

    output logic [1:0] q_req_valid,
    input  logic [1:0] q_req_ready,
    output logic [1:0][3:0] q_req_context_tag,
    output logic [1:0][6:0] q_req_d,
    input  logic [1:0] q_rsp_valid,
    input  logic [1:0][3:0] q_rsp_context_tag,
    input  logic [1:0][15:0] q_rsp_bf16,
    output logic [1:0] k_req_valid,
    input  logic [1:0] k_req_ready,
    output logic [1:0][3:0] k_req_context_tag,
    output logic [1:0][1:0] k_req_key_block,
    output logic [1:0][6:0] k_req_d,
    input  logic [1:0] k_rsp_valid,
    input  logic [1:0][3:0] k_rsp_context_tag,
    input  logic [1:0][511:0] k_rsp_vec,

    output logic [1:0] weight_wr_valid,
    input  logic [1:0] weight_wr_ready,
    output logic [1:0][15:0] weight_wr_epoch,
    output logic [1:0][2:0] weight_wr_group,
    output logic [1:0][4:0] weight_wr_global_q_head,
    output logic [1:0][6:0] weight_wr_row,
    output logic [1:0][1:0] weight_wr_slot_id,
    output logic [1:0][1:0] weight_wr_numeric_mode,
    output logic [1:0][6:0] weight_wr_key,
    output logic [1:0] weight_wr_mask,
    output logic [1:0][31:0] weight_wr_data,
    output logic [1:0] weight_wr_last,
    output logic [1:0] row_commit_valid,
    input  logic [1:0] row_commit_ready,
    output logic [1:0][15:0] row_commit_epoch,
    output logic [1:0][2:0] row_commit_group,
    output logic [1:0][4:0] row_commit_global_q_head,
    output logic [1:0][6:0] row_commit_row,
    output logic [1:0][1:0] row_commit_slot_id,
    output logic [1:0][1:0] row_commit_numeric_mode,
    output logic [1:0][31:0] row_commit_sum_fp32,
    output logic [1:0][31:0] row_commit_inv_sum_fp32,
    input  logic [1:0] pv_row_valid,
    output logic [1:0] pv_row_ready,
    input  logic [1:0][15:0] pv_row_epoch,
    input  logic [1:0][2:0] pv_row_group,
    input  logic [1:0][4:0] pv_row_global_q_head,
    input  logic [1:0][6:0] pv_row_row,
    input  logic [1:0][1:0] pv_row_slot_id,
    input  logic [1:0][1:0] pv_row_numeric_mode,
    input  logic [1:0][31:0] pv_row_sum_fp32,
    input  logic [1:0][31:0] pv_row_inv_sum_fp32,
    output logic [1:0] weight_rd_req_valid,
    input  logic [1:0] weight_rd_req_ready,
    output logic [1:0][15:0] weight_rd_req_epoch,
    output logic [1:0][2:0] weight_rd_req_group,
    output logic [1:0][4:0] weight_rd_req_global_q_head,
    output logic [1:0][6:0] weight_rd_req_row,
    output logic [1:0][1:0] weight_rd_req_slot_id,
    output logic [1:0][1:0] weight_rd_req_numeric_mode,
    output logic [1:0][6:0] weight_rd_req_key,
    input  logic [1:0] weight_rd_rsp_valid,
    input  logic [1:0][15:0] weight_rd_rsp_epoch,
    input  logic [1:0][2:0] weight_rd_rsp_group,
    input  logic [1:0][4:0] weight_rd_rsp_global_q_head,
    input  logic [1:0][6:0] weight_rd_rsp_row,
    input  logic [1:0][1:0] weight_rd_rsp_slot_id,
    input  logic [1:0][1:0] weight_rd_rsp_numeric_mode,
    input  logic [1:0][6:0] weight_rd_rsp_key,
    input  logic [1:0] weight_rd_rsp_mask,
    input  logic [1:0][31:0] weight_rd_rsp_data,

    output logic [1:0] v_req_valid,
    input  logic [1:0] v_req_ready,
    output logic [1:0][3:0] v_req_context_tag,
    output logic [1:0][6:0] v_req_key,
    output logic [1:0][1:0] v_req_feature_block,
    input  logic [1:0] v_rsp_valid,
    input  logic [1:0][3:0] v_rsp_context_tag,
    input  logic [1:0][511:0] v_rsp_vec_bf16,

    output logic [1:0] out_valid,
    input  logic [1:0] out_ready,
    output logic [1:0][15:0] out_epoch,
    output logic [1:0][11:0] out_seq,
    output logic [1:0][4:0] out_global_q_head,
    output logic [1:0][6:0] out_row,
    output logic [1:0][1:0] out_feature_block,
    output logic [1:0][511:0] out_data_bf16,
    output logic [1:0] out_row_last,
    output logic [1:0] out_tensor_last,
    output logic [1:0] weight_release_valid,
    input  logic [1:0] weight_release_ready,
    output logic [1:0][15:0] weight_release_epoch,
    output logic [1:0][2:0] weight_release_group,
    output logic [1:0][4:0] weight_release_global_q_head,
    output logic [1:0][6:0] weight_release_row,
    output logic [1:0][1:0] weight_release_slot_id,
    output logic [1:0][1:0] weight_release_numeric_mode,

    input  logic [1:0] group_cmd_valid,
    output logic [1:0] group_cmd_ready,
    input  logic [1:0][15:0] group_cmd_epoch,
    input  logic [1:0][2:0] group_cmd_group,
    input  logic [1:0][2:0] group_cmd_local_index,
    input  logic [1:0][1:0] group_cmd_numeric_mode,
    input  logic [1:0] group_cmd_kv_buffer,
    output logic [1:0] group_kv_buffer,

    output logic [1:0] cluster_quiescent,
    output logic [1:0] cluster_group_done_valid,
    output logic [1:0][15:0] cluster_group_done_epoch,
    output logic [1:0][2:0] cluster_group_done_group,
    output logic [1:0][2:0] cluster_group_done_local_index,
    output logic [1:0][1:0] cluster_group_done_numeric_mode,
    output logic [1:0] cluster_group_done_aborted,
    output logic [1:0] cluster_group_done_error,
    output logic [1:0] cluster_adapter_busy,
    output logic [1:0] cluster_txn_active,
    output logic [1:0][63:0] cluster_groups_accepted,
    output logic [1:0][63:0] cluster_groups_completed,
    output logic [1:0][63:0] cluster_groups_aborted,
    output logic [1:0][63:0] cluster_jobs_accepted,
    output logic [1:0][63:0] cluster_retires_accepted,
    output logic [1:0][63:0] cluster_context_words,
    output logic [1:0][63:0] cluster_final_releases,

    output logic done_event_valid,
    input  logic done_event_ready,
    output logic done_event_source,
    output logic [25:0] done_event_payload,
    output logic error_event_valid,
    input  logic error_event_ready,
    output logic error_event_source,
    output logic [47:0] error_event_payload,
    output logic control_event_valid,
    input  logic control_event_ready,
    output logic control_event_source,
    output logic [25:0] control_event_payload,
    output logic txn_error_valid,
    input  logic txn_error_ready,
    output logic [3:0] txn_error_code,
    output logic [15:0] txn_error_epoch,
    output logic [1:0] txn_error_numeric_mode,

    input  logic telemetry_snapshot_req_valid,
    output logic telemetry_snapshot_req_ready,
    input  logic [3:0] telemetry_expected_groups,
    output logic telemetry_snapshot_valid,
    input  logic telemetry_snapshot_ready,
    output logic telemetry_first_issue_valid,
    output logic [63:0] telemetry_first_issue_cycle,
    output logic telemetry_last_commit_valid,
    output logic [63:0] telemetry_last_commit_cycle,
    output logic [63:0] telemetry_groups_accepted,
    output logic [63:0] telemetry_groups_completed,
    output logic [63:0] telemetry_groups_aborted,
    output logic [63:0] telemetry_group_wait_cycles,
    output logic [63:0] telemetry_output_stall_cycles,
    output logic [63:0] telemetry_service_stall_cycles,
    output logic [63:0] telemetry_active_cycles,
    output logic telemetry_all_done
);
    localparam integer CLUSTERS = 2;
    localparam integer DONE_WIDTH = 26;
    localparam integer ERROR_WIDTH = 48;
    localparam integer CONTROL_WIDTH = 26;

    logic [1:0] cluster_start_valid,cluster_start_ready;
    logic [15:0] cluster_start_epoch;
    logic [1:0] cluster_start_numeric_mode;
    logic child_clear_pulse;
    logic [1:0] child_clear;
    logic [1:0] group_abort;
    logic [1:0] cluster_group_cmd_ready;

    logic [1:0] cluster_error_valid,cluster_error_ready;
    logic [1:0][1:0] cluster_error_source;
    logic [1:0][15:0] cluster_error_epoch;
    logic [1:0][2:0] cluster_error_group;
    logic [1:0][4:0] cluster_error_head;
    logic [1:0][6:0] cluster_error_row;
    logic [1:0][1:0] cluster_error_slot;
    logic [1:0][1:0] cluster_error_mode;
    logic [1:0][3:0] cluster_error_code;
    logic [1:0][6:0] cluster_error_bad_key;
    logic [1:0] cluster_control_valid,cluster_control_ready;
    logic [1:0][3:0] cluster_control_code;
    logic [1:0][15:0] cluster_control_epoch;
    logic [1:0][2:0] cluster_control_group;
    logic [1:0][2:0] cluster_control_local_index;
    logic [1:0] cluster_faulted;

    logic [1:0][63:0] cluster_first_issue_cycle;
    logic [1:0] cluster_first_issue_valid;
    logic [1:0][63:0] cluster_last_commit_cycle;
    logic [1:0] cluster_last_commit_valid;
    logic [1:0][63:0] cluster_output_stall_cycles;
    logic [1:0][63:0] cluster_group_wait_cycles;
    logic [1:0][63:0] cluster_service_stall_cycles;
    logic [1:0][63:0] cluster_active_cycles;
    logic [1:0][63:0] unused_cycle_count;
    logic [1:0][5:0] unused_slot_owner;
    logic [1:0][1:0] unused_mode_locked;
    logic [1:0] unused_qk_fault_hold;
    logic [1:0][63:0] unused_counter [0:19];

    logic [2*DONE_WIDTH-1:0] done_source_payload;
    logic [2*ERROR_WIDTH-1:0] error_source_payload;
    logic [2*CONTROL_WIDTH-1:0] control_source_payload;
    logic [127:0] unused_done_source_count;
    logic [127:0] unused_error_source_count;
    logic [127:0] unused_control_source_count;
    logic [63:0] unused_done_emitted,unused_done_stalls,unused_done_simultaneous;
    logic [63:0] unused_error_emitted,unused_error_stalls,unused_error_simultaneous;
    logic [63:0] unused_control_emitted,unused_control_stalls;
    logic [63:0] unused_control_simultaneous;

    logic [127:0] snapshot_groups_accepted,snapshot_groups_completed;
    logic [127:0] snapshot_groups_aborted,snapshot_group_wait_cycles;
    logic [127:0] snapshot_output_stall_cycles,snapshot_service_stall_cycles;
    logic [127:0] snapshot_active_cycles;

    assign child_clear_pulse = txn_active && all_clusters_started &&
                               txn_drain_complete && (&cluster_quiescent);
    assign child_clear = {2{clear | child_clear_pulse}};
    assign group_abort = {2{abort_request | global_halt}};
    assign group_cmd_ready = cluster_group_cmd_ready & {2{!global_halt}};

    cats_r4_a4_txn_fanout #(.CLUSTERS(CLUSTERS)) u_txn_fanout (
        .clk,.rst_n,.clear,.txn_start_valid,.txn_start_ready,.txn_epoch,
        .txn_numeric_mode,.cluster_start_valid,.cluster_start_ready,
        .cluster_start_epoch,.cluster_start_numeric_mode,.txn_active,
        .txn_epoch_locked,.txn_numeric_mode_locked,.cluster_started,
        .all_clusters_started,.txn_drain_complete,.cluster_quiescent,
        .protocol_error_valid(txn_error_valid),
        .protocol_error_ready(txn_error_ready),
        .protocol_error_code(txn_error_code),
        .protocol_error_epoch(txn_error_epoch),
        .protocol_error_numeric_mode(txn_error_numeric_mode)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            global_halt <= 1'b0;
            cluster_faulted <= '0;
        end else if(clear) begin
            global_halt <= 1'b0;
            cluster_faulted <= '0;
        end else begin
            if(abort_request || txn_error_valid ||
               (|cluster_error_valid) || (|cluster_control_valid))
                global_halt <= 1'b1;
            cluster_faulted <= cluster_faulted |
                               cluster_error_valid | cluster_control_valid;
        end
    end

    genvar g;
    generate for(g=0;g<CLUSTERS;g=g+1) begin: g_cluster
        assign done_source_payload[g*DONE_WIDTH +: DONE_WIDTH] = {
            cluster_group_done_error[g],cluster_group_done_aborted[g],
            cluster_group_done_numeric_mode[g],
            cluster_group_done_local_index[g],cluster_group_done_group[g],
            cluster_group_done_epoch[g]
        };
        assign error_source_payload[g*ERROR_WIDTH +: ERROR_WIDTH] = {
            cluster_error_bad_key[g],cluster_error_code[g],
            cluster_error_mode[g],cluster_error_slot[g],cluster_error_row[g],
            cluster_error_head[g],cluster_error_group[g],
            cluster_error_epoch[g],cluster_error_source[g]
        };
        assign control_source_payload[g*CONTROL_WIDTH +: CONTROL_WIDTH] = {
            cluster_control_local_index[g],cluster_control_group[g],
            cluster_control_epoch[g],cluster_control_code[g]
        };

        always_ff @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                cluster_group_wait_cycles[g] <= '0;
                cluster_service_stall_cycles[g] <= '0;
                cluster_active_cycles[g] <= '0;
            end else if(counter_clear) begin
                cluster_group_wait_cycles[g] <= '0;
                cluster_service_stall_cycles[g] <= '0;
                cluster_active_cycles[g] <= '0;
            end else begin
                if(txn_active && all_clusters_started &&
                   !cluster_adapter_busy[g] &&
                   cluster_groups_accepted[g] < 4 &&
                   !(group_cmd_valid[g] && group_cmd_ready[g]))
                    cluster_group_wait_cycles[g] <=
                        cluster_group_wait_cycles[g] + 1'b1;
                if(cluster_adapter_busy[g])
                    cluster_active_cycles[g] <= cluster_active_cycles[g] + 1'b1;
                if((q_slab_need_valid[g] && !q_slab_need_ready[g]) ||
                   (q_req_valid[g] && !q_req_ready[g]) ||
                   (k_req_valid[g] && !k_req_ready[g]) ||
                   (weight_wr_valid[g] && !weight_wr_ready[g]) ||
                   (row_commit_valid[g] && !row_commit_ready[g]) ||
                   (weight_rd_req_valid[g] && !weight_rd_req_ready[g]) ||
                   (v_req_valid[g] && !v_req_ready[g]) ||
                   (weight_release_valid[g] && !weight_release_ready[g]))
                    cluster_service_stall_cycles[g] <=
                        cluster_service_stall_cycles[g] + 1'b1;
            end
        end

        cats_r4_a4_compute_array #(
            .HEAD_DIM(HEAD_DIM),.SCALE_FP32(SCALE_FP32),
            .EXP_LUT_FILE(EXP_LUT_FILE),.CLUSTERS(CLUSTERS),.CLUSTER_ID(g)
        ) u_compute (
            .clk,.rst_n,.clear(child_clear[g]),.counter_clear,
            .txn_start_valid(cluster_start_valid[g]),
            .txn_start_ready(cluster_start_ready[g]),
            .txn_epoch(cluster_start_epoch),
            .txn_numeric_mode(cluster_start_numeric_mode),
            .q_slab_need_valid(q_slab_need_valid[g]),
            .q_slab_need_ready(q_slab_need_ready[g]),
            .q_slab_need_epoch(q_slab_need_epoch[g]),
            .q_slab_need_group(q_slab_need_group[g]),
            .q_slab_need_global_q_head(q_slab_need_global_q_head[g]),
            .q_slab_need_row_window(q_slab_need_row_window[g]),
            .q_slab_ready_valid(q_slab_ready_valid[g]),
            .q_slab_ready_ready(q_slab_ready_ready[g]),
            .q_slab_ready_epoch(q_slab_ready_epoch[g]),
            .q_slab_ready_group(q_slab_ready_group[g]),
            .q_slab_ready_global_q_head(q_slab_ready_global_q_head[g]),
            .q_slab_ready_row_window(q_slab_ready_row_window[g]),
            .q_slab_ready_buffer(q_slab_ready_buffer[g]),
            .q_slab_retire_valid(q_slab_retire_valid[g]),
            .q_slab_retire_ready(q_slab_retire_ready[g]),
            .q_slab_retire_epoch(q_slab_retire_epoch[g]),
            .q_slab_retire_group(q_slab_retire_group[g]),
            .q_slab_retire_global_q_head(q_slab_retire_global_q_head[g]),
            .q_slab_retire_row_window(q_slab_retire_row_window[g]),
            .q_slab_retire_buffer(q_slab_retire_buffer[g]),
            .q_req_valid(q_req_valid[g]),.q_req_ready(q_req_ready[g]),
            .q_req_context_tag(q_req_context_tag[g]),.q_req_d(q_req_d[g]),
            .q_rsp_valid(q_rsp_valid[g]),.q_rsp_context_tag(q_rsp_context_tag[g]),
            .q_rsp_bf16(q_rsp_bf16[g]),
            .k_req_valid(k_req_valid[g]),.k_req_ready(k_req_ready[g]),
            .k_req_context_tag(k_req_context_tag[g]),
            .k_req_key_block(k_req_key_block[g]),.k_req_d(k_req_d[g]),
            .k_rsp_valid(k_rsp_valid[g]),.k_rsp_context_tag(k_rsp_context_tag[g]),
            .k_rsp_vec(k_rsp_vec[g]),
            .weight_wr_valid(weight_wr_valid[g]),.weight_wr_ready(weight_wr_ready[g]),
            .weight_wr_epoch(weight_wr_epoch[g]),.weight_wr_group(weight_wr_group[g]),
            .weight_wr_global_q_head(weight_wr_global_q_head[g]),
            .weight_wr_row(weight_wr_row[g]),.weight_wr_slot_id(weight_wr_slot_id[g]),
            .weight_wr_numeric_mode(weight_wr_numeric_mode[g]),
            .weight_wr_key(weight_wr_key[g]),.weight_wr_mask(weight_wr_mask[g]),
            .weight_wr_data(weight_wr_data[g]),.weight_wr_last(weight_wr_last[g]),
            .row_commit_valid(row_commit_valid[g]),.row_commit_ready(row_commit_ready[g]),
            .row_commit_epoch(row_commit_epoch[g]),.row_commit_group(row_commit_group[g]),
            .row_commit_global_q_head(row_commit_global_q_head[g]),
            .row_commit_row(row_commit_row[g]),.row_commit_slot_id(row_commit_slot_id[g]),
            .row_commit_numeric_mode(row_commit_numeric_mode[g]),
            .row_commit_sum_fp32(row_commit_sum_fp32[g]),
            .row_commit_inv_sum_fp32(row_commit_inv_sum_fp32[g]),
            .pv_row_valid(pv_row_valid[g]),.pv_row_ready(pv_row_ready[g]),
            .pv_row_epoch(pv_row_epoch[g]),.pv_row_group(pv_row_group[g]),
            .pv_row_global_q_head(pv_row_global_q_head[g]),.pv_row_row(pv_row_row[g]),
            .pv_row_slot_id(pv_row_slot_id[g]),
            .pv_row_numeric_mode(pv_row_numeric_mode[g]),
            .pv_row_sum_fp32(pv_row_sum_fp32[g]),
            .pv_row_inv_sum_fp32(pv_row_inv_sum_fp32[g]),
            .weight_rd_req_valid(weight_rd_req_valid[g]),
            .weight_rd_req_ready(weight_rd_req_ready[g]),
            .weight_rd_req_epoch(weight_rd_req_epoch[g]),
            .weight_rd_req_group(weight_rd_req_group[g]),
            .weight_rd_req_global_q_head(weight_rd_req_global_q_head[g]),
            .weight_rd_req_row(weight_rd_req_row[g]),
            .weight_rd_req_slot_id(weight_rd_req_slot_id[g]),
            .weight_rd_req_numeric_mode(weight_rd_req_numeric_mode[g]),
            .weight_rd_req_key(weight_rd_req_key[g]),
            .weight_rd_rsp_valid(weight_rd_rsp_valid[g]),
            .weight_rd_rsp_epoch(weight_rd_rsp_epoch[g]),
            .weight_rd_rsp_group(weight_rd_rsp_group[g]),
            .weight_rd_rsp_global_q_head(weight_rd_rsp_global_q_head[g]),
            .weight_rd_rsp_row(weight_rd_rsp_row[g]),
            .weight_rd_rsp_slot_id(weight_rd_rsp_slot_id[g]),
            .weight_rd_rsp_numeric_mode(weight_rd_rsp_numeric_mode[g]),
            .weight_rd_rsp_key(weight_rd_rsp_key[g]),
            .weight_rd_rsp_mask(weight_rd_rsp_mask[g]),
            .weight_rd_rsp_data(weight_rd_rsp_data[g]),
            .v_req_valid(v_req_valid[g]),.v_req_ready(v_req_ready[g]),
            .v_req_context_tag(v_req_context_tag[g]),.v_req_key(v_req_key[g]),
            .v_req_feature_block(v_req_feature_block[g]),
            .v_rsp_valid(v_rsp_valid[g]),.v_rsp_context_tag(v_rsp_context_tag[g]),
            .v_rsp_vec_bf16(v_rsp_vec_bf16[g]),
            .out_valid(out_valid[g]),.out_ready(out_ready[g]),
            .out_epoch(out_epoch[g]),.out_seq(out_seq[g]),
            .out_global_q_head(out_global_q_head[g]),.out_row(out_row[g]),
            .out_feature_block(out_feature_block[g]),.out_data_bf16(out_data_bf16[g]),
            .out_row_last(out_row_last[g]),.out_tensor_last(out_tensor_last[g]),
            .weight_release_valid(weight_release_valid[g]),
            .weight_release_ready(weight_release_ready[g]),
            .weight_release_epoch(weight_release_epoch[g]),
            .weight_release_group(weight_release_group[g]),
            .weight_release_global_q_head(weight_release_global_q_head[g]),
            .weight_release_row(weight_release_row[g]),
            .weight_release_slot_id(weight_release_slot_id[g]),
            .weight_release_numeric_mode(weight_release_numeric_mode[g]),
            .error_valid(cluster_error_valid[g]),.error_ready(cluster_error_ready[g]),
            .error_source(cluster_error_source[g]),.error_epoch(cluster_error_epoch[g]),
            .error_group(cluster_error_group[g]),
            .error_global_q_head(cluster_error_head[g]),
            .error_row(cluster_error_row[g]),.error_slot_id(cluster_error_slot[g]),
            .error_numeric_mode(cluster_error_mode[g]),
            .error_code(cluster_error_code[g]),.error_bad_key(cluster_error_bad_key[g]),
            .slot_owner(unused_slot_owner[g]),.txn_numeric_mode_locked(unused_mode_locked[g]),
            .qk_fault_hold(unused_qk_fault_hold[g]),.cycle_count(unused_cycle_count[g]),
            .first_issue_cycle(cluster_first_issue_cycle[g]),
            .first_issue_cycle_valid(cluster_first_issue_valid[g]),
            .last_commit_cycle(cluster_last_commit_cycle[g]),
            .last_commit_cycle_valid(cluster_last_commit_valid[g]),
            .slot0_occupied_cycles(unused_counter[0][g]),
            .slot1_occupied_cycles(unused_counter[1][g]),
            .slot2_occupied_cycles(unused_counter[2][g]),
            .row_stall_cycles(unused_counter[3][g]),
            .score_stall_cycles(unused_counter[4][g]),
            .weight_write_stall_cycles(unused_counter[5][g]),
            .row_commit_stall_cycles(unused_counter[6][g]),
            .weight_read_stall_cycles(unused_counter[7][g]),
            .v_request_stall_cycles(unused_counter[8][g]),
            .output_stall_cycles(cluster_output_stall_cycles[g]),
            .error_stall_cycles(unused_counter[9][g]),
            .final_release_stall_cycles(unused_counter[10][g]),
            .q_slab_need_stall_cycles(unused_counter[11][g]),
            .q_slab_ready_stall_cycles(unused_counter[12][g]),
            .q_slab_retire_stall_cycles(unused_counter[13][g]),
            .q_request_stall_cycles(unused_counter[14][g]),
            .k_request_stall_cycles(unused_counter[15][g]),
            .pv_row_stall_cycles(unused_counter[16][g]),
            .weight_release_stall_cycles(unused_counter[17][g]),
            .q_slab_jobs_accepted(unused_counter[18][g]),
            .engine_jobs_started(unused_counter[19][g]),
            .qk_valid_macs(),.rows_transferred(),.scores_transferred(),
            .b2_exp_commit(),.b2_weight_writes(),.b3_pv_commit(),
            .b3_context_words(cluster_context_words[g]),
            .final_release_count(cluster_final_releases[g]),
            .cluster_quiescent(cluster_quiescent[g]),
            .group_cmd_valid(group_cmd_valid[g] && !global_halt),
            .group_cmd_ready(cluster_group_cmd_ready[g]),
            .group_cmd_epoch(group_cmd_epoch[g]),.group_cmd_group(group_cmd_group[g]),
            .group_cmd_local_index(group_cmd_local_index[g]),
            .group_cmd_numeric_mode(group_cmd_numeric_mode[g]),
            .group_cmd_kv_buffer(group_cmd_kv_buffer[g]),
            .group_kv_buffer(group_kv_buffer[g]),.group_abort(group_abort[g]),
            .group_done_valid(cluster_group_done_valid[g]),
            .group_done_ready(cluster_group_done_ready[g]),
            .group_done_epoch(cluster_group_done_epoch[g]),
            .group_done_group(cluster_group_done_group[g]),
            .group_done_local_index(cluster_group_done_local_index[g]),
            .group_done_numeric_mode(cluster_group_done_numeric_mode[g]),
            .group_done_aborted(cluster_group_done_aborted[g]),
            .group_done_error(cluster_group_done_error[g]),
            .control_error_valid(cluster_control_valid[g]),
            .control_error_ready(cluster_control_ready[g]),
            .control_error_code(cluster_control_code[g]),
            .control_error_epoch(cluster_control_epoch[g]),
            .control_error_group(cluster_control_group[g]),
            .control_error_local_index(cluster_control_local_index[g]),
            .group_adapter_busy(cluster_adapter_busy[g]),
            .txn_active_status(cluster_txn_active[g]),
            .groups_accepted(cluster_groups_accepted[g]),
            .groups_completed(cluster_groups_completed[g]),
            .groups_aborted(cluster_groups_aborted[g]),
            .group_jobs_accepted(cluster_jobs_accepted[g]),
            .group_retires_accepted(cluster_retires_accepted[g])
        );
    end endgenerate

    logic [1:0] cluster_group_done_ready;

    cats_r4_a4_event_join #(
        .CLUSTERS(CLUSTERS),.PAYLOAD_WIDTH(DONE_WIDTH)
    ) u_done_join (
        .clk,.rst_n,.clear,.counter_clear,
        .source_valid(cluster_group_done_valid),
        .source_ready(cluster_group_done_ready),
        .source_payload(done_source_payload),.event_valid(done_event_valid),
        .event_ready(done_event_ready),.event_source(done_event_source),
        .event_payload(done_event_payload),
        .source_events_accepted(unused_done_source_count),
        .events_emitted(unused_done_emitted),
        .event_stall_cycles(unused_done_stalls),
        .simultaneous_accept_cycles(unused_done_simultaneous)
    );

    cats_r4_a4_event_join #(
        .CLUSTERS(CLUSTERS),.PAYLOAD_WIDTH(ERROR_WIDTH)
    ) u_error_join (
        .clk,.rst_n,.clear,.counter_clear,.source_valid(cluster_error_valid),
        .source_ready(cluster_error_ready),.source_payload(error_source_payload),
        .event_valid(error_event_valid),.event_ready(error_event_ready),
        .event_source(error_event_source),.event_payload(error_event_payload),
        .source_events_accepted(unused_error_source_count),
        .events_emitted(unused_error_emitted),
        .event_stall_cycles(unused_error_stalls),
        .simultaneous_accept_cycles(unused_error_simultaneous)
    );

    cats_r4_a4_event_join #(
        .CLUSTERS(CLUSTERS),.PAYLOAD_WIDTH(CONTROL_WIDTH)
    ) u_control_join (
        .clk,.rst_n,.clear,.counter_clear,.source_valid(cluster_control_valid),
        .source_ready(cluster_control_ready),
        .source_payload(control_source_payload),
        .event_valid(control_event_valid),.event_ready(control_event_ready),
        .event_source(control_event_source),.event_payload(control_event_payload),
        .source_events_accepted(unused_control_source_count),
        .events_emitted(unused_control_emitted),
        .event_stall_cycles(unused_control_stalls),
        .simultaneous_accept_cycles(unused_control_simultaneous)
    );

    cats_r4_a4_telemetry #(.CLUSTERS(CLUSTERS)) u_telemetry (
        .clk,.rst_n,.clear,
        .snapshot_req_valid(telemetry_snapshot_req_valid),
        .snapshot_req_ready(telemetry_snapshot_req_ready),
        .expected_groups(telemetry_expected_groups),.cluster_quiescent,
        .cluster_faulted,.cluster_first_issue_valid,
        .cluster_first_issue_cycle,.cluster_last_commit_valid,
        .cluster_last_commit_cycle,
        .cluster_groups_accepted(cluster_groups_accepted),
        .cluster_groups_completed(cluster_groups_completed),
        .cluster_groups_aborted(cluster_groups_aborted),
        .cluster_group_wait_cycles,.cluster_output_stall_cycles,
        .cluster_service_stall_cycles,.cluster_active_cycles,
        .snapshot_valid(telemetry_snapshot_valid),
        .snapshot_ready(telemetry_snapshot_ready),
        .snapshot_groups_accepted,.snapshot_groups_completed,
        .snapshot_groups_aborted,.snapshot_group_wait_cycles,
        .snapshot_output_stall_cycles,.snapshot_service_stall_cycles,
        .snapshot_active_cycles,
        .first_issue_valid(telemetry_first_issue_valid),
        .first_issue_cycle(telemetry_first_issue_cycle),
        .last_commit_valid(telemetry_last_commit_valid),
        .last_commit_cycle(telemetry_last_commit_cycle),
        .groups_accepted(telemetry_groups_accepted),
        .groups_completed(telemetry_groups_completed),
        .groups_aborted(telemetry_groups_aborted),
        .group_wait_cycles(telemetry_group_wait_cycles),
        .output_stall_cycles(telemetry_output_stall_cycles),
        .service_stall_cycles(telemetry_service_stall_cycles),
        .active_cycles(telemetry_active_cycles),
        .all_done(telemetry_all_done)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) if(rst_n && !clear) begin
        assert (!(cluster_group_done_error[0] && cluster_group_done_aborted[0]));
        assert (!(cluster_group_done_error[1] && cluster_group_done_aborted[1]));
        assert (!(counter_clear && txn_active));
    end
`endif
endmodule
