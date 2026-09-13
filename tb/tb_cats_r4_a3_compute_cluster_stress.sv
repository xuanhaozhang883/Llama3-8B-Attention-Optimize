`timescale 1ns/1ps
// Test-only vendor-FP handshake mocks.  The directed zero-score workload
// needs only 0, 1, 2, 3, 1/2 and 1/3; all compute stages remain production RTL.
module fp32_mul_ip #(parameter IP_ID=0) (
    input logic clk,rst_n,input logic a_valid,output logic a_ready,
    input logic [31:0] a_data,input logic b_valid,output logic b_ready,
    input logic [31:0] b_data,output logic result_valid,
    input logic result_ready,output logic [31:0] result_data);
    assign a_ready=!result_valid||result_ready;
    assign b_ready=a_ready;
    always_ff @(posedge clk) begin
        if(!rst_n) begin result_valid<=0;result_data<=0; end else begin
            if(result_valid&&result_ready) result_valid<=0;
            if(a_valid&&b_valid&&a_ready&&b_ready) begin
                result_valid<=1;
                if(a_data[30:23]==8'hff) result_data<=a_data;
                else if(b_data[30:23]==8'hff) result_data<=b_data;
                else if(a_data==0||b_data==0) result_data<=0;
                else if(IP_ID==2) result_data<=32'h3f800000;
                else if(a_data==32'h3f800000) result_data<=b_data;
                else if(b_data==32'h3f800000) result_data<=a_data;
                else if((a_data==32'h40000000&&b_data==32'h3f000000)||
                        (b_data==32'h40000000&&a_data==32'h3f000000)||
                        (a_data==32'h40400000&&b_data==32'h3eaaaaab)||
                        (b_data==32'h40400000&&a_data==32'h3eaaaaab))
                    result_data<=32'h3f800000;
                else $fatal(1,"A3 FP mul mock unsupported %h * %h",a_data,b_data);
            end
        end
    end
endmodule
module fp32_add_ip (
    input logic clk,rst_n,input logic a_valid,output logic a_ready,
    input logic [31:0] a_data,input logic b_valid,output logic b_ready,
    input logic [31:0] b_data,output logic result_valid,
    input logic result_ready,output logic [31:0] result_data);
    assign a_ready=!result_valid||result_ready;
    assign b_ready=a_ready;
    function automatic integer decode_count(input logic [31:0] bits);
        integer unbiased;
        integer significand;
        begin
            if(bits==0) decode_count=0;
            else begin
                unbiased=bits[30:23]-127;
                significand={1'b1,bits[22:0]};
                if(bits[31] || unbiased<0 || unbiased>23 ||
                   (significand & ((1 << (23-unbiased))-1)) != 0) begin
                    $fatal(1,"A3 FP add mock decode unsupported %h",bits);
                    decode_count=0;
                end else decode_count=significand >> (23-unbiased);
            end
        end
    endfunction
    function automatic logic [31:0] encode_count(input integer value);
        integer highest;
        integer scan;
        integer shifted;
        logic [7:0] exponent_field;
        begin
            if(value==0) encode_count=0;
            else if(value<0 || value>256) begin
                $fatal(1,"A3 FP add mock encode unsupported %0d",value);
                encode_count=0;
            end else begin
                highest=0;
                for(scan=0;scan<9;scan=scan+1)
                    if(value >= (1 << scan)) highest=scan;
                shifted=value << (23-highest);
                exponent_field=127+highest;
                encode_count={1'b0,exponent_field,shifted[22:0]};
            end
        end
    endfunction
    always_ff @(posedge clk) begin
        if(!rst_n) begin result_valid<=0;result_data<=0; end else begin
            if(result_valid&&result_ready) result_valid<=0;
            if(a_valid&&b_valid&&a_ready&&b_ready) begin
                result_valid<=1;
                result_data<=encode_count(decode_count(a_data)+decode_count(b_data));
            end
        end
    end
endmodule
module tb_cats_r4_a3_compute_cluster_stress #(
    parameter integer MODE = 0,
    parameter integer SEED = 7
);
    localparam logic [15:0] EPOCH = 16'ha306;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0, clear=0, counter_clear=0;
    logic txn_start_valid,txn_start_ready,job_valid,job_ready;
    logic [2:0] job_window;
    logic [1:0] txn_numeric_mode_drive;
    logic q_slab_need_valid,q_slab_need_ready,q_slab_ready_valid,q_slab_ready_ready;
    logic [15:0] q_slab_need_epoch; logic [2:0] q_slab_need_group;
    logic [4:0] q_slab_need_global_q_head; logic [2:0] q_slab_need_row_window;
    logic q_slab_retire_valid,q_slab_retire_ready,q_slab_retire_buffer;
    logic [15:0] q_slab_retire_epoch; logic [2:0] q_slab_retire_group;
    logic [4:0] q_slab_retire_global_q_head; logic [2:0] q_slab_retire_row_window;
    logic q_req_valid,q_req_ready; logic [3:0] q_req_context_tag; logic [6:0] q_req_d;
    logic q_rsp_valid; logic [3:0] q_rsp_context_tag; logic [15:0] q_rsp_bf16;
    logic k_req_valid,k_req_ready; logic [3:0] k_req_context_tag;
    logic [1:0] k_req_key_block; logic [6:0] k_req_d;
    logic k_rsp_valid; logic [3:0] k_rsp_context_tag; logic [511:0] k_rsp_vec;
    logic weight_wr_valid,weight_wr_ready; logic [15:0] weight_wr_epoch;
    logic [2:0] weight_wr_group; logic [4:0] weight_wr_global_q_head;
    logic [6:0] weight_wr_row; logic [1:0] weight_wr_slot_id,weight_wr_numeric_mode;
    logic [6:0] weight_wr_key; logic weight_wr_mask; logic [31:0] weight_wr_data;
    logic weight_wr_last,row_commit_valid,row_commit_ready;
    logic [15:0] row_commit_epoch; logic [2:0] row_commit_group;
    logic [4:0] row_commit_global_q_head; logic [6:0] row_commit_row;
    logic [1:0] row_commit_slot_id,row_commit_numeric_mode;
    logic [31:0] row_commit_sum_fp32,row_commit_inv_sum_fp32;
    logic pv_row_valid,pv_row_ready; logic [15:0] pv_row_epoch;
    logic [2:0] pv_row_group; logic [4:0] pv_row_global_q_head;
    logic [6:0] pv_row_row; logic [1:0] pv_row_slot_id,pv_row_numeric_mode;
    logic [31:0] pv_row_sum_fp32,pv_row_inv_sum_fp32;
    logic weight_rd_req_valid,weight_rd_req_ready; logic [15:0] weight_rd_req_epoch;
    logic [2:0] weight_rd_req_group; logic [4:0] weight_rd_req_global_q_head;
    logic [6:0] weight_rd_req_row; logic [1:0] weight_rd_req_slot_id;
    logic [1:0] weight_rd_req_numeric_mode; logic [6:0] weight_rd_req_key;
    logic weight_rd_rsp_valid; logic [15:0] weight_rd_rsp_epoch;
    logic [2:0] weight_rd_rsp_group; logic [4:0] weight_rd_rsp_global_q_head;
    logic [6:0] weight_rd_rsp_row; logic [1:0] weight_rd_rsp_slot_id;
    logic [1:0] weight_rd_rsp_numeric_mode; logic [6:0] weight_rd_rsp_key;
    logic weight_rd_rsp_mask; logic [31:0] weight_rd_rsp_data;
    logic v_req_valid,v_req_ready; logic [3:0] v_req_context_tag;
    logic [6:0] v_req_key; logic [1:0] v_req_feature_block;
    logic v_rsp_valid; logic [3:0] v_rsp_context_tag; logic [511:0] v_rsp_vec_bf16;
    logic out_valid,out_ready; logic [15:0] out_epoch; logic [11:0] out_seq;
    logic [4:0] out_global_q_head; logic [6:0] out_row;
    logic [1:0] out_feature_block; logic [511:0] out_data_bf16;
    logic out_row_last,out_tensor_last;
    logic weight_release_valid,weight_release_ready; logic [15:0] weight_release_epoch;
    logic [2:0] weight_release_group; logic [4:0] weight_release_global_q_head;
    logic [6:0] weight_release_row; logic [1:0] weight_release_slot_id;
    logic [1:0] weight_release_numeric_mode;
    logic error_valid,error_ready; logic [1:0] error_source;
    logic [15:0] error_epoch; logic [2:0] error_group;
    logic [4:0] error_global_q_head; logic [6:0] error_row;
    logic [1:0] error_slot_id,error_numeric_mode; logic [3:0] error_code;
    logic [6:0] error_bad_key; logic [5:0] slot_owner;
    logic [1:0] txn_numeric_mode_locked; logic qk_fault_hold;
    logic [63:0] q_slab_jobs_accepted,engine_jobs_started,qk_valid_macs;
    logic [63:0] rows_transferred,scores_transferred,b2_exp_commit;
    logic [63:0] b2_weight_writes,b3_pv_commit,b3_context_words,final_release_count;
    logic [63:0] cycle_count,first_issue_cycle,last_commit_cycle;
    logic first_issue_cycle_valid,last_commit_cycle_valid;
    logic [63:0] slot0_occupied_cycles,slot1_occupied_cycles;
    logic [63:0] slot2_occupied_cycles;
    logic [63:0] row_stall_cycles,score_stall_cycles,weight_write_stall_cycles;
    logic [63:0] row_commit_stall_cycles,weight_read_stall_cycles;
    logic [63:0] v_request_stall_cycles,output_stall_cycles,error_stall_cycles;
    logic [63:0] final_release_stall_cycles,q_slab_need_stall_cycles;
    logic [63:0] q_slab_ready_stall_cycles,q_slab_retire_stall_cycles;
    logic [63:0] q_request_stall_cycles,k_request_stall_cycles;
    logic [63:0] pv_row_stall_cycles,weight_release_stall_cycles;
    logic [63:0] c_weight_writes,c_row_commits,c_pv_rows,c_weight_requests;
    logic [63:0] c_weight_responses,c_weight_releases; logic c_error_sticky;

    cats_r4_a3_compute_cluster #(.HEAD_DIM(8),.SCALE_FP32(32'h3f800000)) dut (
        .clk(clk),.rst_n(rst_n),.clear(clear),.counter_clear(counter_clear),
        .txn_start_valid(txn_start_valid),.txn_start_ready(txn_start_ready),
        .txn_epoch(EPOCH),.txn_numeric_mode(txn_numeric_mode_drive),
        .job_valid(job_valid),.job_ready(job_ready),.job_epoch(EPOCH),
        .job_group(3'd0),.job_global_q_head(5'd0),.job_row_window(job_window),
        .q_slab_need_valid(q_slab_need_valid),.q_slab_need_ready(q_slab_need_ready),
        .q_slab_need_epoch(q_slab_need_epoch),.q_slab_need_group(q_slab_need_group),
        .q_slab_need_global_q_head(q_slab_need_global_q_head),
        .q_slab_need_row_window(q_slab_need_row_window),
        .q_slab_ready_valid(q_slab_ready_valid),.q_slab_ready_ready(q_slab_ready_ready),
        .q_slab_ready_epoch(q_slab_need_epoch),.q_slab_ready_group(q_slab_need_group),
        .q_slab_ready_global_q_head(q_slab_need_global_q_head),
        .q_slab_ready_row_window(q_slab_need_row_window),.q_slab_ready_buffer(1'b0),
        .q_slab_retire_valid(q_slab_retire_valid),.q_slab_retire_ready(q_slab_retire_ready),
        .q_slab_retire_epoch(q_slab_retire_epoch),.q_slab_retire_group(q_slab_retire_group),
        .q_slab_retire_global_q_head(q_slab_retire_global_q_head),
        .q_slab_retire_row_window(q_slab_retire_row_window),
        .q_slab_retire_buffer(q_slab_retire_buffer),
        .q_req_valid(q_req_valid),.q_req_ready(q_req_ready),
        .q_req_context_tag(q_req_context_tag),.q_req_d(q_req_d),
        .q_rsp_valid(q_rsp_valid),.q_rsp_context_tag(q_rsp_context_tag),
        .q_rsp_bf16(q_rsp_bf16),.k_req_valid(k_req_valid),.k_req_ready(k_req_ready),
        .k_req_context_tag(k_req_context_tag),.k_req_key_block(k_req_key_block),
        .k_req_d(k_req_d),.k_rsp_valid(k_rsp_valid),
        .k_rsp_context_tag(k_rsp_context_tag),.k_rsp_vec(k_rsp_vec),
        .weight_wr_valid(weight_wr_valid),.weight_wr_ready(weight_wr_ready),
        .weight_wr_epoch(weight_wr_epoch),.weight_wr_group(weight_wr_group),
        .weight_wr_global_q_head(weight_wr_global_q_head),.weight_wr_row(weight_wr_row),
        .weight_wr_slot_id(weight_wr_slot_id),.weight_wr_numeric_mode(weight_wr_numeric_mode),
        .weight_wr_key(weight_wr_key),.weight_wr_mask(weight_wr_mask),
        .weight_wr_data(weight_wr_data),.weight_wr_last(weight_wr_last),
        .row_commit_valid(row_commit_valid),.row_commit_ready(row_commit_ready),
        .row_commit_epoch(row_commit_epoch),.row_commit_group(row_commit_group),
        .row_commit_global_q_head(row_commit_global_q_head),.row_commit_row(row_commit_row),
        .row_commit_slot_id(row_commit_slot_id),
        .row_commit_numeric_mode(row_commit_numeric_mode),
        .row_commit_sum_fp32(row_commit_sum_fp32),
        .row_commit_inv_sum_fp32(row_commit_inv_sum_fp32),
        .pv_row_valid(pv_row_valid),.pv_row_ready(pv_row_ready),.pv_row_epoch(pv_row_epoch),
        .pv_row_group(pv_row_group),.pv_row_global_q_head(pv_row_global_q_head),
        .pv_row_row(pv_row_row),.pv_row_slot_id(pv_row_slot_id),
        .pv_row_numeric_mode(pv_row_numeric_mode),.pv_row_sum_fp32(pv_row_sum_fp32),
        .pv_row_inv_sum_fp32(pv_row_inv_sum_fp32),
        .weight_rd_req_valid(weight_rd_req_valid),.weight_rd_req_ready(weight_rd_req_ready),
        .weight_rd_req_epoch(weight_rd_req_epoch),.weight_rd_req_group(weight_rd_req_group),
        .weight_rd_req_global_q_head(weight_rd_req_global_q_head),
        .weight_rd_req_row(weight_rd_req_row),.weight_rd_req_slot_id(weight_rd_req_slot_id),
        .weight_rd_req_numeric_mode(weight_rd_req_numeric_mode),
        .weight_rd_req_key(weight_rd_req_key),.weight_rd_rsp_valid(weight_rd_rsp_valid),
        .weight_rd_rsp_epoch(weight_rd_rsp_epoch),.weight_rd_rsp_group(weight_rd_rsp_group),
        .weight_rd_rsp_global_q_head(weight_rd_rsp_global_q_head),
        .weight_rd_rsp_row(weight_rd_rsp_row),.weight_rd_rsp_slot_id(weight_rd_rsp_slot_id),
        .weight_rd_rsp_numeric_mode(weight_rd_rsp_numeric_mode),
        .weight_rd_rsp_key(weight_rd_rsp_key),.weight_rd_rsp_mask(weight_rd_rsp_mask),
        .weight_rd_rsp_data(weight_rd_rsp_data),.v_req_valid(v_req_valid),
        .v_req_ready(v_req_ready),.v_req_context_tag(v_req_context_tag),
        .v_req_key(v_req_key),.v_req_feature_block(v_req_feature_block),
        .v_rsp_valid(v_rsp_valid),.v_rsp_context_tag(v_rsp_context_tag),
        .v_rsp_vec_bf16(v_rsp_vec_bf16),.out_valid(out_valid),.out_ready(out_ready),
        .out_epoch(out_epoch),.out_seq(out_seq),.out_global_q_head(out_global_q_head),
        .out_row(out_row),.out_feature_block(out_feature_block),
        .out_data_bf16(out_data_bf16),.out_row_last(out_row_last),
        .out_tensor_last(out_tensor_last),.weight_release_valid(weight_release_valid),
        .weight_release_ready(weight_release_ready),.weight_release_epoch(weight_release_epoch),
        .weight_release_group(weight_release_group),
        .weight_release_global_q_head(weight_release_global_q_head),
        .weight_release_row(weight_release_row),.weight_release_slot_id(weight_release_slot_id),
        .weight_release_numeric_mode(weight_release_numeric_mode),
        .error_valid(error_valid),.error_ready(error_ready),.error_source(error_source),
        .error_epoch(error_epoch),.error_group(error_group),
        .error_global_q_head(error_global_q_head),.error_row(error_row),
        .error_slot_id(error_slot_id),.error_numeric_mode(error_numeric_mode),
        .error_code(error_code),.error_bad_key(error_bad_key),.slot_owner(slot_owner),
        .txn_numeric_mode_locked(txn_numeric_mode_locked),.qk_fault_hold(qk_fault_hold),
        .cycle_count(cycle_count),.first_issue_cycle(first_issue_cycle),
        .first_issue_cycle_valid(first_issue_cycle_valid),
        .last_commit_cycle(last_commit_cycle),
        .last_commit_cycle_valid(last_commit_cycle_valid),
        .slot0_occupied_cycles(slot0_occupied_cycles),
        .slot1_occupied_cycles(slot1_occupied_cycles),
        .slot2_occupied_cycles(slot2_occupied_cycles),
        .row_stall_cycles(row_stall_cycles),.score_stall_cycles(score_stall_cycles),
        .weight_write_stall_cycles(weight_write_stall_cycles),
        .row_commit_stall_cycles(row_commit_stall_cycles),
        .weight_read_stall_cycles(weight_read_stall_cycles),
        .v_request_stall_cycles(v_request_stall_cycles),
        .output_stall_cycles(output_stall_cycles),.error_stall_cycles(error_stall_cycles),
        .final_release_stall_cycles(final_release_stall_cycles),
        .q_slab_need_stall_cycles(q_slab_need_stall_cycles),
        .q_slab_ready_stall_cycles(q_slab_ready_stall_cycles),
        .q_slab_retire_stall_cycles(q_slab_retire_stall_cycles),
        .q_request_stall_cycles(q_request_stall_cycles),
        .k_request_stall_cycles(k_request_stall_cycles),
        .pv_row_stall_cycles(pv_row_stall_cycles),
        .weight_release_stall_cycles(weight_release_stall_cycles),
        .q_slab_jobs_accepted(q_slab_jobs_accepted),
        .engine_jobs_started(engine_jobs_started),.qk_valid_macs(qk_valid_macs),
        .rows_transferred(rows_transferred),.scores_transferred(scores_transferred),
        .b2_exp_commit(b2_exp_commit),.b2_weight_writes(b2_weight_writes),
        .b3_pv_commit(b3_pv_commit),.b3_context_words(b3_context_words),
        .final_release_count(final_release_count));

    tb_cats_r4_b4_c_weight_model #(.CLUSTERS(1),.CLUSTER_ID(0),
        .ROWS_PER_HEAD(128),.SEED(SEED ^ 32'ha306_0001)) c_model (
        .clk(clk),.rst_n(rst_n),.clear(clear),.counter_clear(counter_clear),
        .weight_wr_valid(weight_wr_valid),.weight_wr_ready(weight_wr_ready),
        .weight_wr_epoch(weight_wr_epoch),.weight_wr_group(weight_wr_group),
        .weight_wr_global_q_head(weight_wr_global_q_head),.weight_wr_row(weight_wr_row),
        .weight_wr_slot_id(weight_wr_slot_id),.weight_wr_numeric_mode(weight_wr_numeric_mode),
        .weight_wr_key(weight_wr_key),.weight_wr_mask(weight_wr_mask),
        .weight_wr_data(weight_wr_data),.weight_wr_last(weight_wr_last),
        .row_commit_valid(row_commit_valid),.row_commit_ready(row_commit_ready),
        .row_commit_epoch(row_commit_epoch),.row_commit_group(row_commit_group),
        .row_commit_global_q_head(row_commit_global_q_head),.row_commit_row(row_commit_row),
        .row_commit_slot_id(row_commit_slot_id),
        .row_commit_numeric_mode(row_commit_numeric_mode),
        .row_commit_sum_fp32(row_commit_sum_fp32),
        .row_commit_inv_sum_fp32(row_commit_inv_sum_fp32),
        .pv_row_valid(pv_row_valid),.pv_row_ready(pv_row_ready),.pv_row_epoch(pv_row_epoch),
        .pv_row_group(pv_row_group),.pv_row_global_q_head(pv_row_global_q_head),
        .pv_row_row(pv_row_row),.pv_row_slot_id(pv_row_slot_id),
        .pv_row_numeric_mode(pv_row_numeric_mode),.pv_row_sum_fp32(pv_row_sum_fp32),
        .pv_row_inv_sum_fp32(pv_row_inv_sum_fp32),
        .weight_rd_req_valid(weight_rd_req_valid),.weight_rd_req_ready(weight_rd_req_ready),
        .weight_rd_req_epoch(weight_rd_req_epoch),.weight_rd_req_group(weight_rd_req_group),
        .weight_rd_req_global_q_head(weight_rd_req_global_q_head),
        .weight_rd_req_row(weight_rd_req_row),.weight_rd_req_slot_id(weight_rd_req_slot_id),
        .weight_rd_req_numeric_mode(weight_rd_req_numeric_mode),
        .weight_rd_req_key(weight_rd_req_key),.weight_rd_rsp_valid(weight_rd_rsp_valid),
        .weight_rd_rsp_epoch(weight_rd_rsp_epoch),.weight_rd_rsp_group(weight_rd_rsp_group),
        .weight_rd_rsp_global_q_head(weight_rd_rsp_global_q_head),
        .weight_rd_rsp_row(weight_rd_rsp_row),.weight_rd_rsp_slot_id(weight_rd_rsp_slot_id),
        .weight_rd_rsp_numeric_mode(weight_rd_rsp_numeric_mode),
        .weight_rd_rsp_key(weight_rd_rsp_key),.weight_rd_rsp_mask(weight_rd_rsp_mask),
        .weight_rd_rsp_data(weight_rd_rsp_data),
        .weight_release_valid(weight_release_valid),.weight_release_ready(weight_release_ready),
        .weight_release_epoch(weight_release_epoch),.weight_release_group(weight_release_group),
        .weight_release_global_q_head(weight_release_global_q_head),
        .weight_release_row(weight_release_row),.weight_release_slot_id(weight_release_slot_id),
        .weight_release_numeric_mode(weight_release_numeric_mode),
        .c_weight_writes(c_weight_writes),.c_row_commits(c_row_commits),
        .c_pv_rows(c_pv_rows),.c_weight_requests(c_weight_requests),
        .c_weight_responses(c_weight_responses),.c_weight_releases(c_weight_releases),
        .c_error_sticky(c_error_sticky));

    logic [1:0] qpipe,kpipe; logic [3:0] qtag[0:1],ktag[0:1];
    logic [31:0] lfsr;
    integer contexts=0,releases=0,internal_releases=0,retires=0;
    integer max_owned=0,owned,timeout,quiet;
    integer fault_errors=0,error_base;
    logic fault_phase=0,fault_responses=0,block_q_ready=0;
    logic hold_q_responses=0,inject_q_rsp=0;
    logic [3:0] inject_q_tag=0,held_old_q_tag=0;
    logic old_q_captured=0;
    integer expected_row_base=0;
    logic [1:0] last_error_source,last_error_slot;
    logic [3:0] last_error_code;
    logic [6:0] last_error_row,last_error_key;
    logic [6:0] injected_row,injected_key;
    logic [1:0] injected_slot;
    logic [1023:0] injected_score_fp32;
    logic [37:0] held_client_error;
    logic saw_final_one_row;
    logic [2:0] lifecycle_seen_release,lifecycle_seen_realloc;
    logic [2:0] lifecycle_seen_rehandoff,lifecycle_seen_rerelease;
    logic [63:0] held_engine_starts,held_q_requests,held_k_requests;
    integer error_s0_c2=0,error_s0_c7=0,error_s1_c7=0,error_other=0;
    integer q_service_requests=0,q_service_responses=0;
    integer k_service_requests=0,k_service_responses=0;
    integer q_phase_requests=0,q_phase_responses=0;
    integer k_phase_requests=0,k_phase_responses=0;
    logic saw_error_with_q_valid_ready=0,saw_error_with_q_outstanding=0;
    logic out_stalled,release_stalled;
    logic [555:0] held_out; logic [34:0] held_release;
    logic [2047:0] p_row,p_score,p_ww,p_commit,p_pv,p_wreq,p_vreq,p_final,p_err,p_qreq,p_kreq;
    logic [2047:0] p_need,p_ready,p_retire,p_context,p_release;
    assign p_row={dut.b_row_epoch,dut.b_row_group,dut.b_row_head,dut.b_row_index,dut.b_row_slot,dut.b_row_mode,dut.b_row_max};
    assign p_score={dut.b_score_epoch,dut.b_score_group,dut.b_score_head,dut.b_score_row,dut.b_score_key,dut.b_score_slot,dut.b_score_mode,dut.b_score_data,dut.b_score_last};
    assign p_ww={weight_wr_epoch,weight_wr_group,weight_wr_global_q_head,weight_wr_row,weight_wr_slot_id,weight_wr_numeric_mode,weight_wr_key,weight_wr_mask,weight_wr_data,weight_wr_last};
    assign p_commit={row_commit_epoch,row_commit_group,row_commit_global_q_head,row_commit_row,row_commit_slot_id,row_commit_numeric_mode,row_commit_sum_fp32,row_commit_inv_sum_fp32};
    assign p_pv={pv_row_epoch,pv_row_group,pv_row_global_q_head,pv_row_row,pv_row_slot_id,pv_row_numeric_mode,pv_row_sum_fp32,pv_row_inv_sum_fp32};
    assign p_wreq={weight_rd_req_epoch,weight_rd_req_group,weight_rd_req_global_q_head,weight_rd_req_row,weight_rd_req_slot_id,weight_rd_req_numeric_mode,weight_rd_req_key};
    assign p_vreq={v_req_context_tag,v_req_key,v_req_feature_block};
    assign p_final={dut.final_release_epoch,dut.final_release_group,dut.final_release_head,dut.final_release_row,dut.final_release_slot,dut.final_release_mode};
    assign p_err={error_source,error_epoch,error_group,error_global_q_head,error_row,error_slot_id,error_numeric_mode,error_code,error_bad_key};
    assign p_qreq={q_req_context_tag,q_req_d};
    assign p_kreq={k_req_context_tag,k_req_key_block,k_req_d};
    assign p_need={q_slab_need_epoch,q_slab_need_group,q_slab_need_global_q_head,q_slab_need_row_window};
    assign p_ready={q_slab_need_epoch,q_slab_need_group,q_slab_need_global_q_head,q_slab_need_row_window,1'b0};
    assign p_retire={q_slab_retire_epoch,q_slab_retire_group,q_slab_retire_global_q_head,q_slab_retire_row_window,q_slab_retire_buffer};
    assign p_context={out_epoch,out_seq,out_global_q_head,out_row,out_feature_block,out_data_bf16,out_row_last,out_tensor_last};
    assign p_release={weight_release_epoch,weight_release_group,weight_release_global_q_head,weight_release_row,weight_release_slot_id,weight_release_numeric_mode};
    assign q_req_ready=(lfsr[2]||lfsr[9])&&!block_q_ready;
    assign k_req_ready=lfsr[3]||lfsr[10];
    assign q_slab_need_ready=lfsr[4]||lfsr[11];
    assign q_slab_retire_ready=lfsr[5]||lfsr[12];
    assign error_ready=fault_phase ? 1'b1 : (lfsr[6]||lfsr[13]);
    assign v_rsp_vec_bf16={32{16'h3f80}};
    assign v_req_ready=lfsr[0]||lfsr[4]; assign out_ready=lfsr[1]||lfsr[6];

    always_ff @(posedge clk) begin : services
        integer i;
        if(!rst_n || clear) begin
            qpipe<=0;kpipe<=0;q_rsp_valid<=0;k_rsp_valid<=0;
            q_slab_ready_valid<=0;
            q_rsp_context_tag<=0;k_rsp_context_tag<=0;q_rsp_bf16<=0;k_rsp_vec<=0;
            v_rsp_valid<=0;v_rsp_context_tag<=0;lfsr<=SEED[31:0];
        end else begin
            lfsr<={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            q_slab_ready_valid<=q_slab_need_valid&&q_slab_need_ready;
            q_rsp_valid<=inject_q_rsp ? 1'b1 : (fault_responses ? 1'b1 : qpipe[1]);
            q_rsp_context_tag<=inject_q_rsp ? inject_q_tag : (fault_responses ? 4'd0 : qtag[1]);
            q_rsp_bf16<=16'h0000;
            qpipe[1]<=qpipe[0];qtag[1]<=qtag[0];
            qpipe[0]<=q_req_valid&&q_req_ready&&!hold_q_responses;
            qtag[0]<=q_req_context_tag;
            if(q_req_valid&&q_req_ready&&hold_q_responses&&!old_q_captured) begin
                held_old_q_tag<=q_req_context_tag; old_q_captured<=1;
            end
            k_rsp_valid<=fault_responses ? 1'b1 : kpipe[1];
            k_rsp_context_tag<=fault_responses ? 4'd0 : ktag[1]; k_rsp_vec<=0;
            for(i=0;i<32;i=i+1) k_rsp_vec[i*16 +:16]<=16'h0000;
            kpipe[1]<=kpipe[0];ktag[1]<=ktag[0];kpipe[0]<=k_req_valid&&k_req_ready;ktag[0]<=k_req_context_tag;
            v_rsp_valid<=v_req_valid&&v_req_ready;
            if(v_req_valid&&v_req_ready) v_rsp_context_tag<=v_req_context_tag;
        end
    end

    always_ff @(posedge clk) begin
        if(!rst_n || clear) begin
            contexts<=0;releases<=0;internal_releases<=0;retires<=0;
            fault_errors<=0;
            error_s0_c2<=0;error_s0_c7<=0;error_s1_c7<=0;error_other<=0;
            q_service_requests<=0;q_service_responses<=0;
            k_service_requests<=0;k_service_responses<=0;
            saw_error_with_q_valid_ready<=0;saw_error_with_q_outstanding<=0;
            saw_final_one_row<=0;
            lifecycle_seen_release<=0;lifecycle_seen_realloc<=0;
            lifecycle_seen_rehandoff<=0;lifecycle_seen_rerelease<=0;
            max_owned<=0;out_stalled<=0;release_stalled<=0;
        end else begin
            if(dut.u_row_frontend.u_a2.u_rows.u_owner.reserve_valid &&
               dut.u_row_frontend.u_a2.u_rows.u_owner.reserve_ready &&
               lifecycle_seen_release[dut.u_row_frontend.u_a2.u_rows.u_owner.reserve_slot_id])
                lifecycle_seen_realloc[dut.u_row_frontend.u_a2.u_rows.u_owner.reserve_slot_id]<=1;
            if(dut.u_row_frontend.u_a2.u_rows.u_owner.handoff_valid &&
               dut.u_row_frontend.u_a2.u_rows.u_owner.handoff_ready &&
               lifecycle_seen_realloc[dut.u_row_frontend.u_a2.u_rows.u_owner.handoff_slot_id])
                lifecycle_seen_rehandoff[dut.u_row_frontend.u_a2.u_rows.u_owner.handoff_slot_id]<=1;
            if(dut.final_release_valid&&dut.final_release_ready) begin
                if(lifecycle_seen_rehandoff[dut.final_release_slot])
                    lifecycle_seen_rerelease[dut.final_release_slot]<=1;
                lifecycle_seen_release[dut.final_release_slot]<=1;
            end
            owned=(slot_owner[1:0]!=0)+(slot_owner[3:2]!=0)+(slot_owner[5:4]!=0);
            if(owned>max_owned) max_owned<=owned;
            if(error_valid&&error_ready) begin
                $display("A3_STRESS_ERROR mode=%0d seed=%0d source=%0d code=%0d row=%0d slot=%0d key=%0d",MODE,SEED,error_source,error_code,error_row,error_slot_id,error_bad_key);
                if(!fault_phase)
                    $fatal(1,"A3 unexpected unified error source=%0d code=%0d",error_source,error_code);
                if(error_source===2'bxx || error_epoch===16'hxxxx ||
                   error_slot_id===2'bxx || error_code===4'hx)
                    $fatal(1,"A3 unified error payload contains X");
                fault_errors<=fault_errors+1;
                if(error_source==0 && error_code==2) error_s0_c2<=error_s0_c2+1;
                else if(error_source==0 && error_code==7) error_s0_c7<=error_s0_c7+1;
                else if(error_source==1 && error_code==7) error_s1_c7<=error_s1_c7+1;
                else error_other<=error_other+1;
                last_error_source<=error_source; last_error_slot<=error_slot_id;
                last_error_code<=error_code; last_error_row<=error_row;
                last_error_key<=error_bad_key;
            end
            if(q_req_valid&&q_req_ready&&q_req_context_tag<3)
                q_service_requests<=q_service_requests+1;
            if(q_rsp_valid&&dut.q_rsp_admit&&q_rsp_context_tag<3)
                q_service_responses<=q_service_responses+1;
            if(k_req_valid&&k_req_ready&&k_req_context_tag<3)
                k_service_requests<=k_service_requests+1;
            if(k_rsp_valid&&dut.k_rsp_admit&&k_rsp_context_tag<3)
                k_service_responses<=k_service_responses+1;
            if(dut.client_engine_error_valid&&q_req_valid&&q_req_ready)
                saw_error_with_q_valid_ready<=1;
            if(dut.client_engine_error_valid&&dut.q_rsp_pending!=0)
                saw_error_with_q_outstanding<=1;
            if(dut.client_start_valid&&dut.client_start_ready&&
               dut.client_start_row_offset==15&&dut.client_start_row_count==1)
                saw_final_one_row<=1;
            if(out_stalled && (out_valid!==1'b1 ||
                {out_epoch,out_seq,out_global_q_head,out_row,out_feature_block,out_data_bf16,out_row_last,out_tensor_last}!==held_out))
                $fatal(1,"A3 Context payload changed while stalled");
            out_stalled<=out_valid&&!out_ready;
            if(out_valid&&!out_ready) held_out<={out_epoch,out_seq,out_global_q_head,out_row,out_feature_block,out_data_bf16,out_row_last,out_tensor_last};
            if(out_valid&&out_ready) begin
                if(out_epoch!==EPOCH || out_seq!==out_row || out_global_q_head!==0 ||
                   out_row!==expected_row_base+contexts/4 || out_feature_block!==contexts%4 ||
                   out_data_bf16!=={32{16'h3f80}} ||
                   out_row_last!==(contexts%4==3) || out_tensor_last!==1'b0)
                    $fatal(1,"A3 Context mismatch index=%0d row=%0d block=%0d",contexts,out_row,out_feature_block);
                contexts<=contexts+1;
            end
            if(release_stalled && (weight_release_valid!==1'b1 ||
                {weight_release_epoch,weight_release_group,weight_release_global_q_head,
                 weight_release_row,weight_release_slot_id,weight_release_numeric_mode}!==held_release))
                $fatal(1,"A3 release payload changed while stalled");
            release_stalled<=weight_release_valid&&!weight_release_ready;
            if(weight_release_valid&&!weight_release_ready)
                held_release<={weight_release_epoch,weight_release_group,weight_release_global_q_head,
                              weight_release_row,weight_release_slot_id,weight_release_numeric_mode};
            if(weight_release_valid&&weight_release_ready) begin
                if(weight_release_epoch!==EPOCH || weight_release_group!==0 ||
                   weight_release_global_q_head!==0 || weight_release_row!==expected_row_base+releases ||
                   weight_release_slot_id!==releases%3 || weight_release_numeric_mode!==MODE)
                    $fatal(1,"A3 release mismatch index=%0d",releases);
                releases<=releases+1;
            end
            if(dut.final_release_valid&&dut.final_release_ready) begin
                if(dut.final_release_epoch!==EPOCH ||
                   dut.final_release_group!==0 || dut.final_release_head!==0 ||
                   dut.final_release_row!==expected_row_base+internal_releases ||
                   dut.final_release_slot!==internal_releases%3 ||
                   dut.final_release_mode!==MODE)
                    $fatal(1,"A3 final release mismatch index=%0d",internal_releases);
                internal_releases<=internal_releases+1;
            end
            if(q_slab_retire_valid&&q_slab_retire_ready) begin
                if(q_slab_retire_epoch!==EPOCH || q_slab_retire_group!==0 ||
                   q_slab_retire_global_q_head!==0 ||
                   q_slab_retire_row_window!==job_window || q_slab_retire_buffer!==0)
                    $fatal(1,"A3 Q-slab retire token mismatch");
                retires<=retires+1;
            end
        end
    end

`define A3_STABLE(NAME,VALID,READY,PAYLOAD) \
    logic NAME``_stalled; logic [2047:0] NAME``_held; \
    always_ff @(posedge clk) begin \
        if(!rst_n || clear) NAME``_stalled<=0; \
        else begin \
            if($isunknown(VALID)) $fatal(1,"A3 valid contains X/Z: NAME"); \
            if((VALID)===1'b1 && $isunknown(READY)) \
                $fatal(1,"A3 ready contains X/Z: NAME"); \
            if((VALID)===1'b1 && $isunknown(PAYLOAD)) \
                $fatal(1,"A3 valid payload contains X/Z: NAME"); \
            if(NAME``_stalled && ((VALID)!==1'b1 || (PAYLOAD)!==NAME``_held)) \
                $fatal(1,"A3 stalled payload changed: NAME"); \
            NAME``_stalled <= ((VALID)===1'b1) && ((READY)===1'b0); \
            if(((VALID)===1'b1) && ((READY)===1'b0)) NAME``_held <= (PAYLOAD); \
        end \
    end
    `A3_STABLE(row_hold,dut.b_row_valid,dut.b_row_ready,p_row)
    `A3_STABLE(score_hold,dut.b_score_valid,dut.b_score_ready,p_score)
    `A3_STABLE(weight_write_hold,weight_wr_valid,weight_wr_ready,p_ww)
    `A3_STABLE(row_commit_hold,row_commit_valid,row_commit_ready,p_commit)
    `A3_STABLE(pv_row_hold,pv_row_valid,pv_row_ready,p_pv)
    `A3_STABLE(weight_read_hold,weight_rd_req_valid,weight_rd_req_ready,p_wreq)
    `A3_STABLE(v_request_hold,v_req_valid,v_req_ready,p_vreq)
    `A3_STABLE(final_release_hold,dut.final_release_valid,dut.final_release_ready,p_final)
    `A3_STABLE(error_hold,error_valid,error_ready,p_err)
    `A3_STABLE(q_request_hold,q_req_valid,q_req_ready,p_qreq)
    `A3_STABLE(k_request_hold,k_req_valid,k_req_ready,p_kreq)
    `A3_STABLE(q_slab_need_hold,q_slab_need_valid,q_slab_need_ready,p_need)
    `A3_STABLE(q_slab_ready_token_hold,q_slab_ready_valid,q_slab_ready_ready,p_ready)
    `A3_STABLE(q_slab_retire_hold,q_slab_retire_valid,q_slab_retire_ready,p_retire)
    `A3_STABLE(context_hold,out_valid,out_ready,p_context)
    `A3_STABLE(weight_release_hold,weight_release_valid,weight_release_ready,p_release)
`undef A3_STABLE

    initial begin
        txn_start_valid=0;job_valid=0;job_window=0;txn_numeric_mode_drive=MODE[1:0];
        repeat(6) @(posedge clk); rst_n=1; repeat(2) @(posedge clk);
        @(negedge clk);txn_start_valid=1;
        do @(posedge clk); while(!txn_start_ready);
        @(negedge clk);txn_start_valid=0;
        if(txn_numeric_mode_locked!==MODE) $fatal(1,"A3 numeric mode lock mismatch");
        txn_numeric_mode_drive=(MODE==0)?2'd1:2'd0;
        @(negedge clk);job_valid=1;
        do @(posedge clk); while(!job_ready);
        @(negedge clk);job_valid=0;
        timeout=0;
        // The first three rows prove three-slot concurrency, but a Q-slab
        // window is indivisible: drain all 16 rows before claiming closure.
        while((internal_releases<16 || retires<1) && timeout<200000) begin
            @(posedge clk); timeout=timeout+1;
            if((timeout%10000)==0)
                begin
                    $display("PROGRESS cycle=%0d ctx=%0d rel=%0d owner=%h starts=%0d rows=%0d scores=%0d exp=%0d pv=%0d",
                        timeout,contexts,releases,slot_owner,engine_jobs_started,
                        rows_transferred,scores_transferred,b2_exp_commit,b3_pv_commit);
                    $fflush();
                end
        end
        if(timeout==200000) $fatal(1,"A3 watchdog contexts=%0d releases=%0d retires=%0d owners=%h",contexts,releases,retires,slot_owner);
        for(quiet=0;quiet<100;quiet=quiet+1) @(posedge clk);
        if(contexts!==64 || releases!==16 || internal_releases!==16 ||
           retires!==1 || max_owned!==3 || slot_owner!==0 ||
           q_slab_jobs_accepted!==1 || engine_jobs_started!==24 ||
           qk_valid_macs!==1088 || rows_transferred!==16 || scores_transferred!==136 ||
           b2_exp_commit!==136 || b2_weight_writes!==2048 ||
           b3_pv_commit!==17408 || b3_context_words!==2048 ||
           final_release_count!==16 || c_weight_releases!==16 ||
           c_error_sticky || qk_fault_hold)
            $fatal(1,"A3 closure mode=%0d ctx=%0d rel=%0d final_rel=%0d retires=%0d slots=%0d jobs=%0d starts=%0d qk=%0d rows=%0d scores=%0d exp=%0d ww=%0d pv=%0d words=%0d final=%0d c_rel=%0d owner=%h",
                MODE,contexts,releases,internal_releases,retires,max_owned,
                q_slab_jobs_accepted,engine_jobs_started,qk_valid_macs,rows_transferred,
                scores_transferred,b2_exp_commit,b2_weight_writes,b3_pv_commit,
                b3_context_words,final_release_count,c_weight_releases,slot_owner);
        if(dut.slot_allocations[0]!==6 || dut.slot_handoffs[0]!==6 || dut.slot_releases[0]!==6 || dut.slot_aborts[0]!==0 ||
           dut.slot_allocations[1]!==5 || dut.slot_handoffs[1]!==5 || dut.slot_releases[1]!==5 || dut.slot_aborts[1]!==0 ||
           dut.slot_allocations[2]!==5 || dut.slot_handoffs[2]!==5 || dut.slot_releases[2]!==5 || dut.slot_aborts[2]!==0)
            $fatal(1,"A3 window0 lifecycle accounting mismatch");
        if(weight_write_stall_cycles==0 ||
           row_commit_stall_cycles==0 || weight_read_stall_cycles==0 ||
           v_request_stall_cycles==0 || output_stall_cycles==0 ||
           q_request_stall_cycles==0 || k_request_stall_cycles==0 ||
           weight_release_stall_cycles==0)
            $fatal(1,"A3 independent backpressure missing row=%0d score=%0d ww=%0d commit=%0d wrd=%0d v=%0d out=%0d final=%0d need=%0d retire=%0d q=%0d k=%0d pv=%0d release=%0d",
                row_stall_cycles,score_stall_cycles,weight_write_stall_cycles,
                row_commit_stall_cycles,weight_read_stall_cycles,v_request_stall_cycles,
                output_stall_cycles,final_release_stall_cycles,q_slab_need_stall_cycles,
                q_slab_retire_stall_cycles,q_request_stall_cycles,k_request_stall_cycles,
                pv_row_stall_cycles,weight_release_stall_cycles);
        if(!first_issue_cycle_valid || first_issue_cycle>=cycle_count ||
           last_commit_cycle_valid || slot0_occupied_cycles==0 ||
           slot1_occupied_cycles==0 || slot2_occupied_cycles==0)
            $fatal(1,"A3 normal telemetry closure mismatch");
        $display("PASS A3 STRESS mode=%0d seed=%0d phase=fill_three_slots allocations=16 handoffs=16 releases=16 aborts=0 live=0",MODE,SEED);
        $fflush();

        // A standalone counter clear must not reset lifecycle proof state while
        // the real owner still has live slots.  Complete this genuine window.
        @(negedge clk); clear=1;
        @(posedge clk); @(negedge clk); clear=0; txn_numeric_mode_drive=MODE[1:0];
        txn_start_valid=1;
        do @(posedge clk); while(!txn_start_ready);
        @(negedge clk); txn_start_valid=0; job_valid=1;
        do @(posedge clk); while(!job_ready);
        @(negedge clk); job_valid=0;
        timeout=0;
        while(slot_owner==0 && timeout<20000) begin @(posedge clk);timeout=timeout+1;end
        if(timeout==20000) $fatal(1,"A3 counter_clear setup saw no live slot");
        @(negedge clk); counter_clear=1;
        @(posedge clk); #1;
        if(slot_owner==0) $fatal(1,"A3 counter_clear did not overlap a live slot");
        @(negedge clk); counter_clear=0;
        timeout=0;
        while((internal_releases<16||retires<1)&&timeout<200000) begin
            @(posedge clk);timeout=timeout+1;
        end
        if(timeout==200000 || contexts!==64 || internal_releases!==16 ||
           releases!==16 || slot_owner!==0 ||
           dut.slot_allocations[0]!==6 || dut.slot_handoffs[0]!==6 ||
           dut.slot_releases[0]!==6 || dut.slot_aborts[0]!==0 ||
           dut.slot_allocations[1]!==5 || dut.slot_handoffs[1]!==5 ||
           dut.slot_releases[1]!==5 || dut.slot_aborts[1]!==0 ||
           dut.slot_allocations[2]!==5 || dut.slot_handoffs[2]!==5 ||
           dut.slot_releases[2]!==5 || dut.slot_aborts[2]!==0)
            $fatal(1,"A3 live counter_clear lifecycle/completion mismatch");
        $display("PASS A3 STRESS mode=%0d seed=%0d phase=independent_weight_v_output_release_backpressure rows=16 row0=1 three_row_batch=1 final_one_row_batch=1 stalls=1 live_counter_clear=1 completed=1",MODE,SEED);
        $fflush();

        @(negedge clk); clear=1;
        @(posedge clk); @(negedge clk); clear=0; txn_start_valid=1;
        do @(posedge clk); while(!txn_start_ready);
        @(negedge clk); txn_start_valid=0;

        // Capture a genuine registered score-memory response just after it
        // is created, then assert asynchronous reset before the next rising edge.
        @(negedge clk); job_window=0; job_valid=1;
        do @(posedge clk); while(!job_ready);
        @(negedge clk); job_valid=0;
        timeout=0;
        while(dut.u_row_frontend.score_rd_rsp_valid!==1'b1 && timeout<20000) begin
            @(posedge clk); #1; timeout=timeout+1;
        end
        $display("PENDING_RSP token=%h/%h/%h/%h/%h/%h/%h data=%h",
            dut.u_row_frontend.score_rd_rsp_epoch,dut.u_row_frontend.score_rd_rsp_group,
            dut.u_row_frontend.score_rd_rsp_global_q_head,dut.u_row_frontend.score_rd_rsp_row,
            dut.u_row_frontend.score_rd_rsp_key,dut.u_row_frontend.score_rd_rsp_slot_id,
            dut.u_row_frontend.score_rd_rsp_numeric_mode,dut.u_row_frontend.score_rd_rsp_bf16);
        if(timeout==20000 || $isunknown(dut.u_row_frontend.score_rd_rsp_epoch) ||
           $isunknown(dut.u_row_frontend.score_rd_rsp_group) ||
           $isunknown(dut.u_row_frontend.score_rd_rsp_global_q_head) ||
           $isunknown(dut.u_row_frontend.score_rd_rsp_row) ||
           $isunknown(dut.u_row_frontend.score_rd_rsp_key) ||
           $isunknown(dut.u_row_frontend.score_rd_rsp_slot_id) ||
           $isunknown(dut.u_row_frontend.score_rd_rsp_numeric_mode) ||
           $isunknown(dut.u_row_frontend.score_rd_rsp_bf16))
            $fatal(1,"A3 failed pending response valid=%b ready=%b scorev=%b client=%0d starts=%0d",
                dut.u_row_frontend.score_rd_rsp_valid,
                dut.u_row_frontend.score_rd_rsp_ready,dut.b_score_valid,
                dut.u_q_slab_client.state,engine_jobs_started);
        #2; rst_n=0;
        @(posedge clk); #1;
        if(dut.u_row_frontend.score_rd_rsp_valid!==1'b0)
            $fatal(1,"A3 asynchronous reset did not invalidate pending response");
        @(negedge clk); rst_n=1;
        repeat(12) begin @(posedge clk); #1;
            if(dut.b_row_valid || dut.b_score_valid || out_valid ||
               weight_release_valid || error_valid)
                $fatal(1,"A3 stale output after reset with pending score response");
        end
        if(!txn_start_ready || !job_ready)
            $fatal(1,"A3 did not restart after pending-response reset");
        $display("PASS A3 STRESS mode=%0d seed=%0d phase=reset_with_pending_score_response pending=1 async_drop=1 stale=0 restart=1",MODE,SEED);
        $fflush();

        // Hold one genuine old request's response across clear.  Because Q/K
        // responses have no epoch, deliver it before any new same-tag request.
        hold_q_responses=1; old_q_captured=0;
        @(negedge clk); txn_numeric_mode_drive=MODE[1:0]; txn_start_valid=1;
        do @(posedge clk); while(!txn_start_ready);
        @(negedge clk); txn_start_valid=0; job_window=0; job_valid=1;
        do @(posedge clk); while(!job_ready);
        @(negedge clk); job_valid=0;
        timeout=0;
        while(!old_q_captured && timeout<1000) begin @(posedge clk); timeout=timeout+1; end
        if(timeout==1000) $fatal(1,"A3 old-epoch setup saw no genuine Q request");
        @(negedge clk); clear=1;
        @(posedge clk); #1;
        @(negedge clk); clear=0; hold_q_responses=0;
        inject_q_tag=held_old_q_tag; inject_q_rsp=1;
        @(posedge clk); @(negedge clk); inject_q_rsp=0;
        repeat(6) begin @(posedge clk); #1;
            if(dut.frontend_raw_score_valid || error_valid ||
               dut.u_qk_engine.scheduler_protocol_errors!=0)
                $fatal(1,"A3 old untagged Q response was not quarantined");
        end
        if(dut.q_rsp_pending!==0)
            $fatal(1,"A3 old response recreated pending state");
        $display("PASS A3 STRESS mode=%0d seed=%0d phase=clear_with_old_epoch_qk_response old_tag=%0d dropped=1 errors=0 caveat=before_new_same_tag_request",MODE,SEED,held_old_q_tag);
        $fflush();

        // Generate done_error in the real scheduler with an invalid response
        // context, then allow genuine requests to complete and retire.
        fault_phase=1;
        @(negedge clk);clear=1;counter_clear=1;txn_numeric_mode_drive=MODE[1:0];
        @(posedge clk);#1;
        @(negedge clk);clear=0;counter_clear=0;txn_start_valid=1;
        do @(posedge clk); while(!txn_start_ready);
        @(negedge clk);txn_start_valid=0;job_window=0;job_valid=1;
        do @(posedge clk); while(!job_ready);
        @(negedge clk);job_valid=0;
        // Corrupt one real response so the genuine engine eventually reports
        // done_error.  At that done boundary, present one extra upstream Q
        // request to deterministically exercise the wrapper drain contract.
        timeout=0;
        while(!(q_req_valid&&q_req_ready) && timeout<1000) begin
            @(posedge clk);timeout=timeout+1;
        end
        if(timeout==1000) $fatal(1,"A3 fault setup never reached Q request");
        @(negedge clk); inject_q_tag=4'd15; inject_q_rsp=1;
        @(posedge clk); @(negedge clk); inject_q_rsp=0;
        timeout=0;
        while(!(dut.engine_done_valid&&dut.engine_done_error) && timeout<20000) begin
            @(negedge clk);timeout=timeout+1;
        end
        if(timeout==20000) $fatal(1,"A3 scheduler never reached real done_error");
        block_q_ready=1; hold_q_responses=1; held_old_q_tag=0;
        force dut.engine_q_req_valid=1'b1;
        force q_req_context_tag=4'd0;
        force q_req_d=7'd0;
        @(posedge clk); #1;
        timeout=0;
        while(!dut.client_engine_error_valid && timeout<1000) begin
            @(posedge clk);#1;timeout=timeout+1;
        end
        if(timeout==1000) $fatal(1,"A3 scheduler error did not remain pending");
        if(qk_fault_hold || error_valid)
            $fatal(1,"A3 error escaped while Q request was stalled");
        held_client_error={dut.client_engine_error_epoch,
            dut.client_engine_error_group,dut.client_engine_error_head,
            dut.client_engine_error_window,dut.client_engine_error_row_offset,
            dut.client_engine_error_row_count,dut.client_engine_error_key_block};
        repeat(3) begin
            @(posedge clk); #1;
            if(!dut.client_engine_error_valid || dut.client_engine_error_ready ||
               {dut.client_engine_error_epoch,dut.client_engine_error_group,
                dut.client_engine_error_head,dut.client_engine_error_window,
                dut.client_engine_error_row_offset,dut.client_engine_error_row_count,
                dut.client_engine_error_key_block}!==held_client_error)
                $fatal(1,"A3 client error changed while Q request stalled");
        end
        @(negedge clk); block_q_ready=0;
        timeout=0;
        while(!(q_req_valid&&q_req_ready)&&timeout<1000) begin
            @(posedge clk);timeout=timeout+1;
        end
        if(timeout==1000 || !dut.client_engine_error_valid)
            $fatal(1,"A3 pending-error Q request did not handshake");
        @(negedge clk); release dut.engine_q_req_valid;
        release q_req_context_tag; release q_req_d;
        @(posedge clk); #1;
        if(qk_fault_hold || error_valid || dut.q_rsp_pending==0)
            $fatal(1,"A3 error accepted before delayed Q response pending=%b",dut.q_rsp_pending);
        @(negedge clk); hold_q_responses=0; inject_q_tag=held_old_q_tag; inject_q_rsp=1;
        @(posedge clk); @(negedge clk); inject_q_rsp=0;
        timeout=0;
        while(!qk_fault_hold && timeout<20000) begin
            @(posedge clk); #1; timeout=timeout+1;
        end
        if(timeout==20000) $fatal(1,"A3 real engine error did not set qk_fault_hold");
        if(!saw_error_with_q_valid_ready || !saw_error_with_q_outstanding ||
           q_service_requests<1 || q_service_requests!==q_service_responses ||
           k_service_requests!==k_service_responses)
            $fatal(1,"A3 QK drain/evidence mismatch q=%0d/%0d k=%0d/%0d flags=%b%b",
                q_service_requests,q_service_responses,k_service_requests,k_service_responses,
                saw_error_with_q_valid_ready,saw_error_with_q_outstanding);
        q_phase_requests=q_service_requests; q_phase_responses=q_service_responses;
        k_phase_requests=k_service_requests; k_phase_responses=k_service_responses;
        held_engine_starts=engine_jobs_started;
        held_q_requests=dut.unused64[8];
        held_k_requests=dut.unused64[9];
        job_valid=1;
        repeat(12) begin
            @(posedge clk);#1;
            if(job_ready || (dut.client_start_valid&&dut.client_start_ready) ||
               (q_req_valid&&q_req_ready) || (k_req_valid&&k_req_ready) ||
               (dut.engine_score_valid&&dut.engine_score_ready))
                $fatal(1,"A3 post-fault traffic escaped quarantine");
        end
        job_valid=0;
        timeout=0; while(retires<1&&timeout<1000) begin @(posedge clk);timeout=timeout+1;end
        if(timeout==1000 || fault_errors!==1 || retires!==1 ||
           error_s0_c7!==1 || error_s0_c2!==0 || error_s1_c7!==0 || error_other!==0)
            $fatal(1,"A3 engine error/retire count mismatch errors=%0d retires=%0d",fault_errors,retires);
        @(negedge clk);clear=1;counter_clear=1;
        @(posedge clk);#1;
        if(qk_fault_hold) $fatal(1,"A3 clear did not release qk_fault_hold");
        @(negedge clk);clear=0;counter_clear=0;txn_start_valid=1;
        do @(posedge clk); while(!txn_start_ready);
        @(negedge clk);txn_start_valid=0;
        $display("PASS A3 STRESS mode=%0d seed=%0d phase=qk_engine_error_report_retire_clear_restart errors=1 s0c7=1 s0c2=0 s1c7=0 other=0 retires=1 drained_q=%0d/%0d drained_k=%0d/%0d stalled_req=1 accepted_delayed=1 recovered=1",MODE,SEED,q_phase_requests,q_phase_responses,k_phase_requests,k_phase_responses);
        $fflush();

        // Valid-tag nonfinite engine score: production formatter/A2 must abort.
        error_base=fault_errors; job_window=0; job_valid=1;
        do @(posedge clk); while(!job_ready);
        @(negedge clk); job_valid=0;
        timeout=0;
        while(!(dut.engine_score_valid && dut.engine_score_context_tag<3 &&
                dut.engine_score_lane_valid[0]) && timeout<20000) begin
            @(negedge clk); timeout=timeout+1;
        end
        if(timeout==20000) $fatal(1,"A3 nonfinite setup saw no real score");
        injected_row=dut.engine_score_row;
        injected_slot=dut.engine_score_context_tag[1:0];
        injected_key={dut.engine_score_key_block,5'b0};
        injected_score_fp32=dut.engine_score_fp32;
        injected_score_fp32[31:0]=32'h7f80_0000;
        force dut.engine_score_fp32=injected_score_fp32;
        do @(posedge clk); while(!(dut.engine_score_valid&&dut.engine_score_ready));
        @(negedge clk); release dut.engine_score_fp32;
        timeout=0;
        while(fault_errors<error_base+1&&timeout<2000) begin @(posedge clk);timeout=timeout+1;end
        if(timeout==2000 || last_error_source!==0 || last_error_code!==2 ||
           last_error_row!==injected_row || last_error_slot!==injected_slot ||
           last_error_key!==injected_key || dut.slot_aborts[injected_slot]!==1 ||
           error_s0_c2!==1 || error_s0_c7!==0 || error_s1_c7!==0 || error_other!==0)
            $fatal(1,"A3 real A2 nonfinite abort mismatch src=%0d code=%0d row=%0d slot=%0d key=%0d",
                last_error_source,last_error_code,last_error_row,last_error_slot,last_error_key);
        $display("PASS A3 STRESS mode=%0d seed=%0d phase=a2_nonfinite_score_abort errors=1 s0c2=1 s0c7=0 s1c7=0 other=0 code=2 row=%0d slot=%0d aborts=1",MODE,SEED,injected_row,injected_slot);
        $fflush();

        // Fresh state; malformed score token enters production B4 input.
        @(negedge clk); clear=1; counter_clear=1;
        @(posedge clk); @(negedge clk); clear=0; counter_clear=0; txn_start_valid=1;
        do @(posedge clk); while(!txn_start_ready);
        @(negedge clk); txn_start_valid=0; error_base=fault_errors;
        force dut.b_row_valid=1'b1; force dut.b_row_epoch=EPOCH;
        force dut.b_row_group=3'd0; force dut.b_row_head=5'd0;
        force dut.b_row_index=7'd9; force dut.b_row_slot=2'd2;
        force dut.b_row_mode=MODE[1:0]; force dut.b_row_max=16'h0000;
        do @(posedge clk); while(!dut.b_row_ready);
        @(negedge clk); release dut.b_row_valid; release dut.b_row_epoch;
        release dut.b_row_group; release dut.b_row_head; release dut.b_row_index;
        release dut.b_row_slot; release dut.b_row_mode; release dut.b_row_max;
        for(quiet=0;quiet<(MODE==0?11:10);quiet=quiet+1) begin
            @(negedge clk);
            force dut.b_score_valid=1'b1; force dut.b_score_epoch=EPOCH;
            force dut.b_score_group=3'd0; force dut.b_score_head=5'd0;
            force dut.b_score_row=7'd9;
            force dut.b_score_key=(MODE==0) ?
                ((quiet==0)?7'd1:(quiet-1)) :
                ((quiet==9)?7'd10:quiet[6:0]);
            force dut.b_score_slot=2'd2; force dut.b_score_mode=MODE[1:0];
            force dut.b_score_data=16'h0000;
            force dut.b_score_last=(MODE==0)?(quiet==10):(quiet==9);
            do @(posedge clk); while(!dut.b_score_ready);
            @(negedge clk); release dut.b_score_valid; release dut.b_score_epoch;
            release dut.b_score_group; release dut.b_score_head; release dut.b_score_row;
            release dut.b_score_key; release dut.b_score_slot; release dut.b_score_mode;
            release dut.b_score_data; release dut.b_score_last;
        end
        timeout=0;
        while(fault_errors<error_base+1&&timeout<2000) begin @(posedge clk);timeout=timeout+1;end
        if(timeout==2000 || last_error_source!==1 || error_s0_c2!==0 ||
           error_s0_c7!==0 || error_s1_c7!==1 || error_other!==0)
            $fatal(1,"A3 real B4 malformed-token error mismatch timeout=%0d errors=%0d b4v=%b code=%0d",
                timeout,fault_errors,dut.b4_error_valid,dut.b4_error_code);
        $display("PASS A3 STRESS mode=%0d seed=%0d phase=b4_score_token_error errors=1 s0c2=0 s0c7=0 s1c7=1 other=0 source=1 code=%0d",MODE,SEED,last_error_code);
        $fflush();

        // Trigger both production detector paths in the same bounded episode.
        @(negedge clk); clear=1; counter_clear=1;
        @(posedge clk); @(negedge clk); clear=0; counter_clear=0; txn_start_valid=1;
        do @(posedge clk); while(!txn_start_ready);
        @(negedge clk); txn_start_valid=0;
        force dut.b_row_valid=1'b1; force dut.b_row_epoch=EPOCH;
        force dut.b_row_group=3'd0; force dut.b_row_head=5'd0;
        force dut.b_row_index=7'd10; force dut.b_row_slot=2'd2;
        force dut.b_row_mode=MODE[1:0]; force dut.b_row_max=16'h0000;
        do @(posedge clk); while(!dut.b_row_ready);
        @(negedge clk); release dut.b_row_valid; release dut.b_row_epoch;
        release dut.b_row_group; release dut.b_row_head; release dut.b_row_index;
        release dut.b_row_slot; release dut.b_row_mode; release dut.b_row_max;
        // Supply every legal pre-final score before the concurrent fault cycle;
        // the malformed last beat then needs no post-error traffic to retire.
        for(quiet=0;quiet<(MODE==1?10:0);quiet=quiet+1) begin
            @(negedge clk);
            force dut.b_score_valid=1'b1; force dut.b_score_epoch=EPOCH;
            force dut.b_score_group=3'd0; force dut.b_score_head=5'd0;
            force dut.b_score_row=7'd10; force dut.b_score_key=quiet[6:0];
            force dut.b_score_slot=2'd2; force dut.b_score_mode=MODE[1:0];
            force dut.b_score_data=16'h0000; force dut.b_score_last=1'b0;
            do @(posedge clk); while(!dut.b_score_ready);
            @(negedge clk); release dut.b_score_valid; release dut.b_score_epoch;
            release dut.b_score_group; release dut.b_score_head; release dut.b_score_row;
            release dut.b_score_key; release dut.b_score_slot; release dut.b_score_mode;
            release dut.b_score_data; release dut.b_score_last;
        end
        job_valid=1;
        do @(posedge clk); while(!job_ready);
        @(negedge clk); job_valid=0;
        timeout=0;
        while(!(dut.engine_score_valid&&dut.engine_score_ready&&
                dut.engine_score_context_tag<3&&dut.engine_score_lane_valid[0]&&
                dut.b_score_ready)&&timeout<20000) begin
            @(negedge clk);timeout=timeout+1;
        end
        if(timeout==20000)$fatal(1,"A3 simultaneous setup saw no score");
        error_base=fault_errors;
        injected_score_fp32=dut.engine_score_fp32;
        injected_score_fp32[31:0]=32'h7f80_0000;
        force dut.engine_score_fp32=injected_score_fp32;
        force dut.b_score_valid=1'b1; force dut.b_score_epoch=EPOCH;
        force dut.b_score_group=3'd0; force dut.b_score_head=5'd0;
        force dut.b_score_row=7'd10;
        force dut.b_score_key=(MODE==0)?7'd1:7'd11;
        force dut.b_score_slot=2'd2; force dut.b_score_mode=MODE[1:0];
        force dut.b_score_data=16'h0000; force dut.b_score_last=1'b1;
        @(posedge clk);
        @(negedge clk); release dut.engine_score_fp32;
        release dut.b_score_valid; release dut.b_score_epoch;
        release dut.b_score_group; release dut.b_score_head;
        release dut.b_score_row; release dut.b_score_key;
        release dut.b_score_slot; release dut.b_score_mode;
        release dut.b_score_data; release dut.b_score_last;
        for(quiet=0;quiet<(MODE==0?11:0);quiet=quiet+1) begin
            @(negedge clk);
            force dut.b_score_valid=1'b1; force dut.b_score_epoch=EPOCH;
            force dut.b_score_group=3'd0; force dut.b_score_head=5'd0;
            force dut.b_score_row=7'd10; force dut.b_score_key=quiet[6:0];
            force dut.b_score_slot=2'd2; force dut.b_score_mode=MODE[1:0];
            force dut.b_score_data=16'h0000; force dut.b_score_last=(quiet==10);
            do @(posedge clk); while(!dut.b_score_ready);
            @(negedge clk); release dut.b_score_valid; release dut.b_score_epoch;
            release dut.b_score_group; release dut.b_score_head; release dut.b_score_row;
            release dut.b_score_key; release dut.b_score_slot; release dut.b_score_mode;
            release dut.b_score_data; release dut.b_score_last;
        end
        timeout=0;
        while(fault_errors<error_base+2&&timeout<4000) begin @(posedge clk);timeout=timeout+1;end
        if(timeout==4000 || error_s0_c2!==1 || error_s0_c7!==0 ||
           error_s1_c7!==1 || error_other!==0)
            $fatal(1,"A3 simultaneous detector evidence mismatch s0c2=%0d s0c7=%0d s1c7=%0d other=%0d",
                error_s0_c2,error_s0_c7,error_s1_c7,error_other);
        $display("PASS A3 STRESS mode=%0d seed=%0d phase=simultaneous_a_side_and_b4_error errors=2 s0c2=1 s0c7=0 s1c7=1 other=0 sources=0,1",MODE,SEED);
        $fflush();

        // Real window 7 proves slot reuse and final row_count=1 -> row127.
        // Reset also clears the test vendor FP services, which intentionally do
        // not have a production clear port and may still hold an aborted MAC.
        @(negedge clk); rst_n=0; clear=0; counter_clear=0;
        repeat(2) @(posedge clk);
        @(negedge clk); rst_n=1;
        repeat(2) @(posedge clk); @(negedge clk);
        // The reusable C service model publishes a full-head stream starting at
        // row zero.  This transaction deliberately starts at production window
        // seven, so seed only the model's ordering cursor at the requested base;
        // every DUT request/response and all arithmetic remain production paths.
        c_model.publish_sequence=112;
        expected_row_base=112; job_window=7; txn_start_valid=1;
        do @(posedge clk); while(!txn_start_ready);
        @(negedge clk); txn_start_valid=0; job_valid=1;
        do @(posedge clk); while(!job_ready);
        @(negedge clk); job_valid=0;
        timeout=0;
        while((internal_releases<16||retires<1)&&timeout<1200000) begin
            @(posedge clk);timeout=timeout+1;
            if((timeout%50000)==0)
                begin
                    $display("A3_STRESS_WATCHDOG mode=%0d seed=%0d phase=slot_reuse_after_final_release cycle=%0d releases=%0d scores=%0d pv=%0d contexts=%0d owner=%h starts=%0d qreq=%0d kreq=%0d client=%0d fault=%0d",
                        MODE,SEED,timeout,internal_releases,scores_transferred,b3_pv_commit,contexts,
                        slot_owner,engine_jobs_started,dut.unused64[8],dut.unused64[9],
                        dut.u_q_slab_client.state,qk_fault_hold);
                    $fflush();
                end
        end
        if(timeout==1200000 || contexts!==64 || releases!==16 || internal_releases!==16 ||
           !saw_final_one_row || slot_owner!==0 ||
           q_slab_jobs_accepted!==1 || engine_jobs_started!==24 ||
           qk_valid_macs!==15424 || rows_transferred!==16 || scores_transferred!==1928 ||
           b2_exp_commit!==1928 || b2_weight_writes!==2048 ||
           b3_pv_commit!==246784 || b3_context_words!==2048 ||
           final_release_count!==16 || c_weight_releases!==16 ||
           dut.slot_allocations[0]!==6 || dut.slot_handoffs[0]!==6 || dut.slot_releases[0]!==6 || dut.slot_aborts[0]!==0 ||
           dut.slot_allocations[1]!==5 || dut.slot_handoffs[1]!==5 || dut.slot_releases[1]!==5 || dut.slot_aborts[1]!==0 ||
           dut.slot_allocations[2]!==5 || dut.slot_handoffs[2]!==5 || dut.slot_releases[2]!==5 || dut.slot_aborts[2]!==0 ||
           !(|lifecycle_seen_realloc) || !(|lifecycle_seen_rehandoff) ||
           !(|lifecycle_seen_rerelease))
            $fatal(1,"A3 real window7 slot reuse/row127 closure mismatch");
        $display("PASS A3 STRESS mode=%0d seed=%0d phase=slot_reuse_after_final_release row127=1 final_one_row=1 scores=1928 pv=246784 reuse=%03b s0=6/6/6/0/0 s1=5/5/5/0/0 s2=5/5/5/0/0",MODE,SEED,lifecycle_seen_rerelease);
        $fflush();
        $display("PASS A3 STRESS SUMMARY mode=%0d seed=%0d phases=9 qk=1 a2=1 b4=1 simultaneous=2 row127=1 scores=1928 pv=246784 s0=6/6/6/0/0 s1=5/5/5/0/0 s2=5/5/5/0/0",MODE,SEED);
        $finish;
    end
endmodule
