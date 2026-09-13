`timescale 1ns/1ps

// Test-only protocol model.  This is not representative QK arithmetic IP.
module cats_r4_qk_32lane_engine #(
    parameter int SEQ_LEN=128, HEAD_DIM=128, CONTEXTS=16, LANES=32
) (
    input logic clk,input logic rst_n,input logic clear,input logic counter_clear,
    input logic start_valid,output logic start_ready,
    input logic [15:0] start_epoch,input logic [2:0] start_group,
    input logic [4:0] start_global_q_head,input logic [2:0] start_row_window,
    input logic [3:0] start_row_offset,input logic [4:0] start_row_count,
    input logic [1:0] start_key_block,
    output logic done_valid,input logic done_ready,output logic [15:0] done_epoch,
    output logic [2:0] done_group,output logic [4:0] done_global_q_head,
    output logic [2:0] done_row_window,output logic [1:0] done_key_block,
    output logic done_error,
    output logic q_req_valid,input logic q_req_ready,
    output logic [3:0] q_req_context_tag,output logic [6:0] q_req_d,
    input logic q_rsp_valid,input logic [3:0] q_rsp_context_tag,
    input logic [15:0] q_rsp_bf16,
    output logic k_req_valid,input logic k_req_ready,
    output logic [3:0] k_req_context_tag,output logic [1:0] k_req_key_block,
    output logic [6:0] k_req_d,input logic k_rsp_valid,
    input logic [3:0] k_rsp_context_tag,input logic [511:0] k_rsp_vec,
    output logic score_valid,input logic score_ready,
    output logic [15:0] score_epoch,output logic [2:0] score_group,
    output logic [4:0] score_global_q_head,output logic [6:0] score_row,
    output logic [1:0] score_key_block,output logic [3:0] score_context_tag,
    output logic [LANES-1:0] score_lane_valid,
    output logic [LANES*32-1:0] score_fp32,
    output logic [63:0] q_requests_accepted,output logic [63:0] k_requests_accepted,
    output logic [63:0] mac_steps_issued,output logic [63:0] mac_steps_completed,
    output logic [63:0] valid_macs,output logic [63:0] causal_lane_bubbles,
    output logic [63:0] causal_rows_skipped,output logic [63:0] memory_request_stalls,
    output logic [63:0] mac_issue_stalls,
    output logic [63:0] scheduler_protocol_errors,
    output logic scheduler_protocol_error_sticky,
    output logic [63:0] fp32_requests_accepted,
    output logic [63:0] fp32_mul_products_completed,
    output logic [63:0] fp32_add_results_completed,
    output logic [63:0] fp32_response_transfers,
    output logic [63:0] fp32_protocol_errors,
    output logic fp32_protocol_error_sticky,
    output logic [63:0] score_commits,output logic [63:0] score_commit_stalls,
    output logic [63:0] score_fifo_max_occupancy
);
    typedef enum logic [1:0] {IDLE, EMIT, DONE} state_t;
    state_t state;
    logic [15:0] epoch_r; logic [2:0] group_r, window_r;
    logic [4:0] head_r, count_r; logic [3:0] offset_r, context_r;
    logic [1:0] block_r;
    logic [6:0] row_w;
    logic [5:0] active_lanes_w;

    function automatic logic [LANES-1:0] lane_mask_for(
        input logic [6:0] row_value,input logic [1:0] block_value
    );
        integer i;
        begin
            lane_mask_for='0;
            for(i=0;i<LANES;i=i+1)
                lane_mask_for[i]=((block_value*LANES+i)<=row_value);
        end
    endfunction
    function automatic logic [5:0] popcount(input logic [LANES-1:0] value);
        integer i;
        begin
            popcount=0;
            for(i=0;i<LANES;i=i+1) popcount=popcount+value[i];
        end
    endfunction
    function automatic logic context_has_lanes(
        input logic [2:0] window_value,input logic [3:0] offset_value,
        input logic [3:0] context_value,input logic [1:0] block_value
    );
        logic [6:0] context_row;
        begin
            context_row={window_value,4'b0}+offset_value+context_value;
            context_has_lanes=(lane_mask_for(context_row,block_value)!='0);
        end
    endfunction
    assign row_w={window_r,4'b0}+offset_r+context_r;
    assign active_lanes_w=popcount(score_lane_valid);
    assign start_ready=(state==IDLE);
    assign score_valid=(state==EMIT);
    assign score_epoch=epoch_r; assign score_group=group_r;
    assign score_global_q_head=head_r; assign score_row=row_w;
    assign score_key_block=block_r; assign score_context_tag=context_r;
    assign score_lane_valid=lane_mask_for(row_w,block_r);
    assign score_fp32='0;
    assign done_valid=(state==DONE); assign done_epoch=epoch_r;
    assign done_group=group_r; assign done_global_q_head=head_r;
    assign done_row_window=window_r; assign done_key_block=block_r;
    assign done_error=1'b0;
    assign q_req_valid=1'b0; assign q_req_context_tag='0; assign q_req_d='0;
    assign k_req_valid=1'b0; assign k_req_context_tag='0;
    assign k_req_key_block=block_r; assign k_req_d='0;

    always_ff @(posedge clk or negedge rst_n) begin
        integer scan;
        integer skipped;
        logic found;
        logic [3:0] next_context;
        if(!rst_n) begin
            state<=IDLE; epoch_r<=0; group_r<=0; head_r<=0; window_r<=0;
            offset_r<=0; count_r<=0; block_r<=0; context_r<=0;
            q_requests_accepted<=0;k_requests_accepted<=0;mac_steps_issued<=0;
            mac_steps_completed<=0;valid_macs<=0;causal_lane_bubbles<=0;
            causal_rows_skipped<=0;memory_request_stalls<=0;mac_issue_stalls<=0;
            scheduler_protocol_errors<=0;scheduler_protocol_error_sticky<=0;
            fp32_requests_accepted<=0;fp32_mul_products_completed<=0;
            fp32_add_results_completed<=0;fp32_response_transfers<=0;
            fp32_protocol_errors<=0;fp32_protocol_error_sticky<=0;
            score_commits<=0;score_commit_stalls<=0;score_fifo_max_occupancy<=0;
        end else if(clear) begin
            state<=IDLE; context_r<=0;
        end else begin
            if(score_valid&&!score_ready) score_commit_stalls<=score_commit_stalls+1'b1;
            case(state)
                IDLE: if(start_valid&&start_ready) begin
                    epoch_r<=start_epoch;group_r<=start_group;head_r<=start_global_q_head;
                    window_r<=start_row_window;offset_r<=start_row_offset;
                    count_r<=start_row_count;block_r<=start_key_block;
                    found=1'b0;skipped=0;next_context='0;
                    for(scan=0;scan<CONTEXTS;scan=scan+1) begin
                        if(scan<$unsigned(start_row_count)) begin
                            if(!found&&context_has_lanes(start_row_window,
                               start_row_offset,scan[3:0],start_key_block)) begin
                                found=1'b1;next_context=scan[3:0];
                            end else if(!found) skipped=skipped+1;
                        end
                    end
                    context_r<=next_context;
                    causal_rows_skipped<=causal_rows_skipped+skipped;
                    state<=found?EMIT:DONE;
                end
                EMIT: if(score_valid&&score_ready) begin
                    q_requests_accepted<=q_requests_accepted+HEAD_DIM;
                    k_requests_accepted<=k_requests_accepted+HEAD_DIM;
                    mac_steps_issued<=mac_steps_issued+HEAD_DIM;
                    mac_steps_completed<=mac_steps_completed+HEAD_DIM;
                    valid_macs<=valid_macs+(active_lanes_w*HEAD_DIM);
                    causal_lane_bubbles<=causal_lane_bubbles+((LANES-active_lanes_w)*HEAD_DIM);
                    fp32_requests_accepted<=fp32_requests_accepted+HEAD_DIM;
                    fp32_mul_products_completed<=fp32_mul_products_completed+(active_lanes_w*HEAD_DIM);
                    fp32_add_results_completed<=fp32_add_results_completed+(active_lanes_w*HEAD_DIM);
                    fp32_response_transfers<=fp32_response_transfers+HEAD_DIM;
                    score_commits<=score_commits+1'b1;
                    found=1'b0;skipped=0;next_context='0;
                    for(scan=0;scan<CONTEXTS;scan=scan+1) begin
                        if(scan>$unsigned(context_r)&&scan<$unsigned(count_r)) begin
                            if(!found&&context_has_lanes(window_r,offset_r,
                               scan[3:0],block_r)) begin
                                found=1'b1;next_context=scan[3:0];
                            end else if(!found) skipped=skipped+1;
                        end
                    end
                    causal_rows_skipped<=causal_rows_skipped+skipped;
                    if(found) context_r<=next_context;
                    else state<=DONE;
                end
                DONE: if(done_valid&&done_ready) state<=IDLE;
            endcase
            if(counter_clear) begin
                q_requests_accepted<=0;k_requests_accepted<=0;mac_steps_issued<=0;
                mac_steps_completed<=0;valid_macs<=0;causal_lane_bubbles<=0;
                causal_rows_skipped<=0;memory_request_stalls<=0;mac_issue_stalls<=0;
                scheduler_protocol_errors<=0;scheduler_protocol_error_sticky<=0;
                fp32_requests_accepted<=0;fp32_mul_products_completed<=0;
                fp32_add_results_completed<=0;fp32_response_transfers<=0;
                fp32_protocol_errors<=0;fp32_protocol_error_sticky<=0;
                score_commits<=0;score_commit_stalls<=0;score_fifo_max_occupancy<=0;
            end
        end
    end
endmodule
