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
                if(a_data==0||b_data==0) result_data<=0;
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
        begin
            case(bits)
                32'h00000000: decode_count=0;
                32'h3f800000: decode_count=1;
                32'h40000000: decode_count=2;
                32'h40400000: decode_count=3;
                32'h40800000: decode_count=4;
                32'h40a00000: decode_count=5;
                32'h40c00000: decode_count=6;
                32'h40e00000: decode_count=7;
                32'h41000000: decode_count=8;
                32'h41100000: decode_count=9;
                32'h41200000: decode_count=10;
                32'h41300000: decode_count=11;
                32'h41400000: decode_count=12;
                32'h41500000: decode_count=13;
                32'h41600000: decode_count=14;
                32'h41700000: decode_count=15;
                32'h41800000: decode_count=16;
                default: begin
                    $fatal(1,"A3 FP add mock decode unsupported %h",bits);
                    decode_count=0;
                end
            endcase
        end
    endfunction
    function automatic logic [31:0] encode_count(input integer value);
        begin
            case(value)
                0: encode_count=32'h00000000;
                1: encode_count=32'h3f800000;
                2: encode_count=32'h40000000;
                3: encode_count=32'h40400000;
                4: encode_count=32'h40800000;
                5: encode_count=32'h40a00000;
                6: encode_count=32'h40c00000;
                7: encode_count=32'h40e00000;
                8: encode_count=32'h41000000;
                9: encode_count=32'h41100000;
                10: encode_count=32'h41200000;
                11: encode_count=32'h41300000;
                12: encode_count=32'h41400000;
                13: encode_count=32'h41500000;
                14: encode_count=32'h41600000;
                15: encode_count=32'h41700000;
                16: encode_count=32'h41800000;
                default: begin
                    $fatal(1,"A3 FP add mock encode unsupported %0d",value);
                    encode_count=0;
                end
            endcase
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
module tb_cats_r4_a3_compute_cluster #(parameter integer MODE = 0);
    localparam logic [15:0] EPOCH = 16'ha306;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0, clear=0, counter_clear=0;
    logic txn_start_valid,txn_start_ready,job_valid,job_ready;
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
    logic [63:0] c_weight_writes,c_row_commits,c_pv_rows,c_weight_requests;
    logic [63:0] c_weight_responses,c_weight_releases; logic c_error_sticky;

    cats_r4_a3_compute_cluster #(.HEAD_DIM(8),.SCALE_FP32(32'h00000000)) dut (
        .clk(clk),.rst_n(rst_n),.clear(clear),.counter_clear(counter_clear),
        .txn_start_valid(txn_start_valid),.txn_start_ready(txn_start_ready),
        .txn_epoch(EPOCH),.txn_numeric_mode(txn_numeric_mode_drive),
        .job_valid(job_valid),.job_ready(job_ready),.job_epoch(EPOCH),
        .job_group(3'd0),.job_global_q_head(5'd0),.job_row_window(3'd0),
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
        .q_slab_jobs_accepted(q_slab_jobs_accepted),
        .engine_jobs_started(engine_jobs_started),.qk_valid_macs(qk_valid_macs),
        .rows_transferred(rows_transferred),.scores_transferred(scores_transferred),
        .b2_exp_commit(b2_exp_commit),.b2_weight_writes(b2_weight_writes),
        .b3_pv_commit(b3_pv_commit),.b3_context_words(b3_context_words),
        .final_release_count(final_release_count));

    tb_cats_r4_b4_c_weight_model #(.CLUSTERS(1),.CLUSTER_ID(0),
        .ROWS_PER_HEAD(128),.SEED(32'ha306_0001)) c_model (
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
    logic [31:0] lfsr=32'h9135a306;
    integer contexts=0,releases=0,internal_releases=0,retires=0;
    integer max_owned=0,owned,timeout,quiet;
    integer fault_errors=0;
    integer fault_q_requests=0,fault_q_responses=0;
    integer fault_k_requests=0,fault_k_responses=0;
    logic fault_phase=0,fault_responses=0;
    logic [63:0] held_engine_starts,held_q_requests,held_k_requests;
    logic out_stalled,release_stalled;
    logic [555:0] held_out; logic [34:0] held_release;
    assign q_req_ready=1; assign k_req_ready=1;
    assign q_slab_need_ready=1;
    assign q_slab_retire_ready=1; assign error_ready=1;
    assign v_rsp_vec_bf16={32{16'h3f80}};
    assign v_req_ready=lfsr[0]||lfsr[4]; assign out_ready=lfsr[1]||lfsr[6];

    always_ff @(posedge clk) begin : services
        integer i;
        if(!rst_n || clear) begin
            qpipe<=0;kpipe<=0;q_rsp_valid<=0;k_rsp_valid<=0;
            q_slab_ready_valid<=0;
            q_rsp_context_tag<=0;k_rsp_context_tag<=0;q_rsp_bf16<=0;k_rsp_vec<=0;
            v_rsp_valid<=0;v_rsp_context_tag<=0;lfsr<=32'h9135a306;
        end else begin
            lfsr<={lfsr[30:0],lfsr[31]^lfsr[21]^lfsr[1]^lfsr[0]};
            q_slab_ready_valid<=q_slab_need_valid&&q_slab_need_ready;
            q_rsp_valid<=fault_responses ? 1'b1 : qpipe[1];
            q_rsp_context_tag<=fault_responses ? 4'd0 : qtag[1];
            q_rsp_bf16<=16'h0000;
            qpipe[1]<=qpipe[0];qtag[1]<=qtag[0];qpipe[0]<=q_req_valid;qtag[0]<=q_req_context_tag;
            k_rsp_valid<=fault_responses ? 1'b1 : kpipe[1];
            k_rsp_context_tag<=fault_responses ? 4'd0 : ktag[1]; k_rsp_vec<=0;
            for(i=0;i<32;i=i+1) k_rsp_vec[i*16 +:16]<=16'h0000;
            kpipe[1]<=kpipe[0];ktag[1]<=ktag[0];kpipe[0]<=k_req_valid;ktag[0]<=k_req_context_tag;
            v_rsp_valid<=v_req_valid&&v_req_ready;
            if(v_req_valid&&v_req_ready) v_rsp_context_tag<=v_req_context_tag;
        end
    end

    always_ff @(posedge clk) begin
        if(!rst_n || clear) begin
            contexts<=0;releases<=0;internal_releases<=0;retires<=0;
            fault_errors<=0;
            fault_q_requests<=0;fault_q_responses<=0;
            fault_k_requests<=0;fault_k_responses<=0;
            max_owned<=0;out_stalled<=0;release_stalled<=0;
        end else begin
            owned=(slot_owner[1:0]!=0)+(slot_owner[3:2]!=0)+(slot_owner[5:4]!=0);
            if(owned>max_owned) max_owned<=owned;
            if(error_valid&&error_ready) begin
                if(!fault_phase)
                    $fatal(1,"A3 unexpected unified error source=%0d code=%0d",error_source,error_code);
                if(error_source!==0 || error_epoch!==EPOCH || error_group!==0 ||
                   error_global_q_head!==0 || error_row!==0 || error_slot_id!==0 ||
                   error_numeric_mode!==MODE || error_code!==7 || error_bad_key!==0)
                    $fatal(1,"A3 injected invalid-context error payload mismatch");
                fault_errors<=fault_errors+1;
            end
            if(fault_phase&&q_req_valid&&q_req_ready&&q_req_context_tag<3)
                fault_q_requests<=fault_q_requests+1;
            if(fault_phase&&q_rsp_valid&&q_rsp_context_tag<3)
                fault_q_responses<=fault_q_responses+1;
            if(fault_phase&&k_req_valid&&k_req_ready&&k_req_context_tag<3)
                fault_k_requests<=fault_k_requests+1;
            if(fault_phase&&k_rsp_valid&&k_rsp_context_tag<3)
                fault_k_responses<=fault_k_responses+1;
            if(out_stalled && (out_valid!==1'b1 ||
                {out_epoch,out_seq,out_global_q_head,out_row,out_feature_block,out_data_bf16,out_row_last,out_tensor_last}!==held_out))
                $fatal(1,"A3 Context payload changed while stalled");
            out_stalled<=out_valid&&!out_ready;
            if(out_valid&&!out_ready) held_out<={out_epoch,out_seq,out_global_q_head,out_row,out_feature_block,out_data_bf16,out_row_last,out_tensor_last};
            if(out_valid&&out_ready) begin
                if(out_epoch!==EPOCH || out_seq!==out_row || out_global_q_head!==0 ||
                   out_row!==contexts/4 || out_feature_block!==contexts%4 ||
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
                   weight_release_global_q_head!==0 || weight_release_row!==releases ||
                   weight_release_slot_id!==releases%3 || weight_release_numeric_mode!==MODE)
                    $fatal(1,"A3 release mismatch index=%0d",releases);
                releases<=releases+1;
            end
            if(dut.final_release_valid&&dut.final_release_ready) begin
                if(dut.final_release_epoch!==EPOCH ||
                   dut.final_release_group!==0 || dut.final_release_head!==0 ||
                   dut.final_release_row!==internal_releases ||
                   dut.final_release_slot!==internal_releases%3 ||
                   dut.final_release_mode!==MODE)
                    $fatal(1,"A3 final release mismatch index=%0d",internal_releases);
                internal_releases<=internal_releases+1;
            end
            if(q_slab_retire_valid&&q_slab_retire_ready) begin
                if(q_slab_retire_epoch!==EPOCH || q_slab_retire_group!==0 ||
                   q_slab_retire_global_q_head!==0 ||
                   q_slab_retire_row_window!==0 || q_slab_retire_buffer!==0)
                    $fatal(1,"A3 Q-slab retire token mismatch");
                retires<=retires+1;
            end
        end
    end

    initial begin
        txn_start_valid=0;job_valid=0;txn_numeric_mode_drive=MODE[1:0];
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
                $display("PROGRESS cycle=%0d ctx=%0d rel=%0d owner=%h starts=%0d rows=%0d scores=%0d exp=%0d pv=%0d",
                    timeout,contexts,releases,slot_owner,engine_jobs_started,
                    rows_transferred,scores_transferred,b2_exp_commit,b3_pv_commit);
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
        $display("PASS A3 COMPUTE CLUSTER mode=%0d slots_observed=%0d errors=0 context_chunks=%0d releases=%0d retires=%0d jobs=%0d engine_starts=%0d qk_macs=%0d rows=%0d scores=%0d exp=%0d weight_writes=%0d pv=%0d context_words=%0d",
            MODE,max_owned,contexts,releases,retires,q_slab_jobs_accepted,
            engine_jobs_started,qk_valid_macs,
            rows_transferred,scores_transferred,b2_exp_commit,b2_weight_writes,
            b3_pv_commit,b3_context_words);

        if(!first_issue_cycle_valid || first_issue_cycle>=cycle_count ||
           last_commit_cycle_valid || slot0_occupied_cycles==0 ||
           slot1_occupied_cycles==0 || slot2_occupied_cycles==0)
            $fatal(1,"A3 normal telemetry closure mismatch");

        // Reset-clean wrapper-owned invalid-context injection while the real
        // engine is active.  Only the engine score output wires are forced.
        fault_phase=1;
        @(negedge clk);clear=1;counter_clear=1;txn_numeric_mode_drive=MODE[1:0];
        @(posedge clk);#1;
        if(qk_fault_hold || cycle_count!==0 || first_issue_cycle_valid ||
           slot0_occupied_cycles!==0 || slot1_occupied_cycles!==0 ||
           slot2_occupied_cycles!==0)
            $fatal(1,"A3 clear/counter_clear did not reset fault telemetry");
        @(negedge clk);clear=0;counter_clear=0;txn_start_valid=1;
        do @(posedge clk); while(!txn_start_ready);
        @(negedge clk);txn_start_valid=0;
        txn_numeric_mode_drive=(MODE==0)?2'd1:2'd0;
        job_valid=1;
        do @(posedge clk); while(!job_ready);
        @(negedge clk);job_valid=0;
        timeout=0;
        while(!(q_req_valid||k_req_valid) && timeout<1000) begin
            @(posedge clk);timeout=timeout+1;
        end
        if(timeout==1000) $fatal(1,"A3 fault setup never reached Q/K request phase");
        @(negedge clk);
        force dut.engine_score_valid=1'b1;
        force dut.engine_score_context_tag=4'd3;
        force dut.engine_score_epoch=EPOCH;
        force dut.engine_score_group=3'd0;
        force dut.engine_score_head=5'd0;
        force dut.engine_score_row=7'd0;
        force dut.engine_score_key_block=2'd0;
        force dut.engine_score_lane_valid=32'd1;
        force dut.engine_score_fp32=1024'd0;
        timeout=0;
        do begin
            @(posedge clk);#1;timeout=timeout+1;
        end while(!qk_fault_hold&&timeout<2000);
        if(timeout==2000) $fatal(1,"A3 invalid context did not reach drained fault boundary");
        @(negedge clk);
        release dut.engine_score_valid;
        release dut.engine_score_context_tag;
        release dut.engine_score_epoch;
        release dut.engine_score_group;
        release dut.engine_score_head;
        release dut.engine_score_row;
        release dut.engine_score_key_block;
        release dut.engine_score_lane_valid;
        release dut.engine_score_fp32;
        timeout=0;
        while((!qk_fault_hold||fault_errors<1)&&timeout<1000) begin
            @(posedge clk);#1;timeout=timeout+1;
        end
        if(timeout==1000 || fault_q_requests!==fault_q_responses ||
           fault_k_requests!==fault_k_responses)
            $fatal(1,"A3 fault drain mismatch hold=%b q=%0d/%0d k=%0d/%0d",
                qk_fault_hold,fault_q_requests,fault_q_responses,
                fault_k_requests,fault_k_responses);
        held_engine_starts=engine_jobs_started;
        held_q_requests=dut.unused64[8];
        held_k_requests=dut.unused64[9];
        fault_responses=1;job_valid=1;
        repeat(8) begin
            @(posedge clk);#1;
            if(job_ready || (dut.client_start_valid&&dut.client_start_ready) ||
               (q_req_valid&&q_req_ready) || (k_req_valid&&k_req_ready) ||
               (dut.engine_score_valid&&dut.engine_score_ready))
                $fatal(1,"A3 post-fault traffic escaped quarantine job=%b start=%b q=%b k=%b score=%b",
                    job_ready,(dut.client_start_valid&&dut.client_start_ready),
                    (q_req_valid&&q_req_ready),(k_req_valid&&k_req_ready),
                    (dut.engine_score_valid&&dut.engine_score_ready));
        end
        if(engine_jobs_started!==held_engine_starts ||
           dut.unused64[8]!==held_q_requests || dut.unused64[9]!==held_k_requests)
            $fatal(1,"A3 post-fault counters advanced starts=%0d/%0d q=%0d/%0d k=%0d/%0d",
                engine_jobs_started,held_engine_starts,dut.unused64[8],held_q_requests,
                dut.unused64[9],held_k_requests);
        job_valid=0;fault_responses=0;
        repeat(4) @(posedge clk);
        if(fault_errors!==1) $fatal(1,"A3 invalid-context error count mismatch %0d",fault_errors);
        @(negedge clk);clear=1;
        @(posedge clk);#1;
        if(qk_fault_hold) $fatal(1,"A3 clear did not release qk_fault_hold");
        @(negedge clk);clear=0;counter_clear=1;
        @(posedge clk);#1;
        if(cycle_count!==0 || first_issue_cycle_valid ||
           slot0_occupied_cycles!==0 || slot1_occupied_cycles!==0 ||
           slot2_occupied_cycles!==0)
            $fatal(1,"A3 counter_clear did not clear telemetry");
        @(negedge clk);counter_clear=0;
        @(posedge clk);#1;
        if(!txn_start_ready || !job_ready)
            $fatal(1,"A3 readiness did not recover after clear");
        $display("PASS A3 FAULT QUARANTINE mode=%0d error_handshakes=1 blocked_cycles=8 drained_q=%0d/%0d drained_k=%0d/%0d recovered=1",MODE,
            fault_q_requests,fault_q_responses,
            fault_k_requests,fault_k_responses);
        $finish;
    end
endmodule
