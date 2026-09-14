`timescale 1ns/1ps

// Test-only protocol model: handshake/counter faithful, arithmetic always zero.
// This is not representative QK arithmetic or real FP32 IP.
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
    typedef enum logic [1:0] {IDLE,RUN,EMIT,DONE} state_t;
    state_t state;
    logic [15:0] epoch_r,active_mask_r,q_done_r,k_done_r,context_done_r;
    logic [15:0] q_outstanding_r,k_outstanding_r,q_buffer_valid_r;
    logic [15:0] k_buffer_valid_r;
    logic [2:0] group_r,window_r;
    logic [4:0] head_r,count_r;
    logic [3:0] offset_r,context_r;
    logic [1:0] block_r;
    logic [6:0] q_next_d [0:CONTEXTS-1];
    logic [6:0] k_next_d [0:CONTEXTS-1];
    logic [6:0] q_pending_d [0:CONTEXTS-1];
    logic [6:0] k_pending_d [0:CONTEXTS-1];
    logic [6:0] q_buffer_d [0:CONTEXTS-1];
    logic [6:0] k_buffer_d [0:CONTEXTS-1];
    logic [6:0] step_next_d [0:CONTEXTS-1];
    logic [15:0] start_active_mask_w,context_done_after_w;
    logic [15:0] q_available_w,k_available_w;
    logic q_select_valid_w,k_select_valid_w,step_select_valid_w;
    logic [3:0] q_select_context_w,k_select_context_w,step_select_context_w;
    logic [3:0] first_context_w,next_context_w;
    logic first_context_valid_w,next_context_valid_w;
    logic [6:0] score_row_w,step_row_w;
    logic [5:0] step_active_lanes_w;
    logic q_hold_valid_r,k_hold_valid_r;
    logic [3:0] q_hold_context_r,k_hold_context_r;
    logic [6:0] q_hold_d_r,k_hold_d_r;
    logic q_fire,k_fire,q_rsp_accept,k_rsp_accept,step_event,score_fire;
    logic score_push,invalid_start,invalid_q_rsp,invalid_k_rsp;
    logic [3:0] score_wr_ptr_r,score_rd_ptr_r;
    logic [4:0] score_count_r;
    logic [15:0] score_epoch_mem [0:15];
    logic [2:0] score_group_mem [0:15];
    logic [4:0] score_head_mem [0:15];
    logic [6:0] score_row_mem [0:15];
    logic [1:0] score_block_mem [0:15];
    logic [3:0] score_context_mem [0:15];

    function automatic logic [LANES-1:0] lane_mask_for(
        input logic [6:0] row_value,input logic [1:0] block_value);
        integer lane;
        begin
            lane_mask_for='0;
            for(lane=0;lane<LANES;lane=lane+1)
                lane_mask_for[lane]=(((block_value*LANES+lane)<SEQ_LEN)&&
                                     ((block_value*LANES+lane)<=row_value));
        end
    endfunction
    function automatic logic [5:0] popcount32(input logic [LANES-1:0] value);
        integer lane;
        begin
            popcount32=0;
            for(lane=0;lane<LANES;lane=lane+1) popcount32+=value[lane];
        end
    endfunction
    function automatic logic [4:0] popcount16(input logic [15:0] value);
        integer index;
        begin
            popcount16=0;
            for(index=0;index<CONTEXTS;index=index+1) popcount16+=value[index];
        end
    endfunction

    always_comb begin : p_select
        integer scan,start_row;
        start_active_mask_w='0;
        q_select_valid_w=0;k_select_valid_w=0;step_select_valid_w=0;
        q_select_context_w=0;k_select_context_w=0;step_select_context_w=0;
        first_context_valid_w=0;first_context_w=0;
        next_context_valid_w=0;next_context_w=0;
        for(scan=0;scan<CONTEXTS;scan=scan+1) begin
            start_row=($unsigned(start_row_window)*CONTEXTS)+
                      $unsigned(start_row_offset)+scan;
            if(($unsigned(scan)<$unsigned(start_row_count))&&(start_row<SEQ_LEN)&&
               (start_row>=($unsigned(start_key_block)*LANES)))
                start_active_mask_w[scan]=1'b1;
            if(!step_select_valid_w&&q_available_w[scan]&&
               k_available_w[scan]&&
               ((q_rsp_accept&&q_rsp_context_tag==scan)?q_pending_d[scan]:q_buffer_d[scan])==
               ((k_rsp_accept&&k_rsp_context_tag==scan)?k_pending_d[scan]:k_buffer_d[scan])&&
               ((q_rsp_accept&&q_rsp_context_tag==scan)?q_pending_d[scan]:q_buffer_d[scan])==
               step_next_d[scan]) begin
                step_select_valid_w=1;step_select_context_w=scan[3:0];
            end
            if(!q_select_valid_w&&active_mask_r[scan]&&!q_done_r[scan]&&
               ((!q_outstanding_r[scan]&&!q_buffer_valid_r[scan])||
                (step_select_valid_w&&step_select_context_w==scan))) begin
                q_select_valid_w=1;q_select_context_w=scan[3:0];
            end
            if(!k_select_valid_w&&active_mask_r[scan]&&!k_done_r[scan]&&
               ((!k_outstanding_r[scan]&&!k_buffer_valid_r[scan])||
                (step_select_valid_w&&step_select_context_w==scan))) begin
                k_select_valid_w=1;k_select_context_w=scan[3:0];
            end
            if(!first_context_valid_w&&active_mask_r[scan]) begin
                first_context_valid_w=1;first_context_w=scan[3:0];
            end
            if(!next_context_valid_w&&(scan>$unsigned(context_r))&&
               active_mask_r[scan]) begin
                next_context_valid_w=1;next_context_w=scan[3:0];
            end
        end
    end

    always_comb begin
        context_done_after_w=context_done_r;
        if(step_select_valid_w&&step_next_d[step_select_context_w]==HEAD_DIM-1)
            context_done_after_w[step_select_context_w]=1'b1;
    end

    assign start_ready=(state==IDLE)&&
        (($unsigned(score_count_r)+popcount16(start_active_mask_w))<=16);
    assign q_req_valid=(state==RUN)&&(q_hold_valid_r||q_select_valid_w);
    assign q_req_context_tag=q_hold_valid_r?q_hold_context_r:q_select_context_w;
    assign q_req_d=q_hold_valid_r?q_hold_d_r:q_next_d[q_select_context_w];
    assign k_req_valid=(state==RUN)&&(k_hold_valid_r||k_select_valid_w);
    assign k_req_context_tag=k_hold_valid_r?k_hold_context_r:k_select_context_w;
    assign k_req_key_block=block_r;
    assign k_req_d=k_hold_valid_r?k_hold_d_r:k_next_d[k_select_context_w];
    assign q_fire=q_req_valid&&q_req_ready;assign k_fire=k_req_valid&&k_req_ready;
    assign q_rsp_accept=q_rsp_valid&&(state==RUN)&&
        ($unsigned(q_rsp_context_tag)<CONTEXTS)&&active_mask_r[q_rsp_context_tag]&&
        q_outstanding_r[q_rsp_context_tag]&&!q_buffer_valid_r[q_rsp_context_tag]&&
        (q_rsp_bf16=={5'b10101,q_rsp_context_tag,q_pending_d[q_rsp_context_tag]});
    assign k_rsp_accept=k_rsp_valid&&(state==RUN)&&
        ($unsigned(k_rsp_context_tag)<CONTEXTS)&&active_mask_r[k_rsp_context_tag]&&
        k_outstanding_r[k_rsp_context_tag]&&!k_buffer_valid_r[k_rsp_context_tag]&&
        (k_rsp_vec[15:0]=={1'b1,block_r,k_pending_d[k_rsp_context_tag],k_rsp_context_tag,2'b10})&&
        (k_rsp_vec[511:496]=={1'b1,block_r,k_pending_d[k_rsp_context_tag],k_rsp_context_tag,2'b10});
    assign invalid_q_rsp=q_rsp_valid&&!q_rsp_accept;
    assign invalid_k_rsp=k_rsp_valid&&!k_rsp_accept;
    assign q_available_w=q_buffer_valid_r|
        (q_rsp_accept?(16'b1<<q_rsp_context_tag):16'b0);
    assign k_available_w=k_buffer_valid_r|
        (k_rsp_accept?(16'b1<<k_rsp_context_tag):16'b0);
    assign step_event=(state==RUN)&&step_select_valid_w;
    assign step_row_w=($unsigned(window_r)*CONTEXTS)+$unsigned(offset_r)+
                      step_select_context_w;
    assign step_active_lanes_w=popcount32(lane_mask_for(step_row_w,block_r));
    assign score_push=step_event&&(step_next_d[step_select_context_w]==HEAD_DIM-1);
    assign score_valid=(score_count_r!=0);assign score_fire=score_valid&&score_ready;
    assign score_row_w=($unsigned(window_r)*CONTEXTS)+$unsigned(offset_r)+context_r;
    assign score_epoch=score_epoch_mem[score_rd_ptr_r];
    assign score_group=score_group_mem[score_rd_ptr_r];
    assign score_global_q_head=score_head_mem[score_rd_ptr_r];
    assign score_row=score_row_mem[score_rd_ptr_r];
    assign score_key_block=score_block_mem[score_rd_ptr_r];
    assign score_context_tag=score_context_mem[score_rd_ptr_r];
    assign score_lane_valid=lane_mask_for(score_row_mem[score_rd_ptr_r],
                                          score_block_mem[score_rd_ptr_r]);
    assign score_fp32='0;
    assign done_valid=(state==DONE);assign done_epoch=epoch_r;
    assign done_group=group_r;assign done_global_q_head=head_r;
    assign done_row_window=window_r;assign done_key_block=block_r;
    assign done_error=scheduler_protocol_error_sticky||fp32_protocol_error_sticky;
    assign invalid_start=(start_row_count==0)||($unsigned(start_row_count)>CONTEXTS)||
        ($unsigned(start_row_offset)>=CONTEXTS)||
        (($unsigned(start_row_offset)+$unsigned(start_row_count))>CONTEXTS)||
        ((($unsigned(start_row_window)*CONTEXTS)+$unsigned(start_row_offset)+
          $unsigned(start_row_count))>SEQ_LEN)||(start_global_q_head[4:2]!=start_group);

    always_ff @(posedge clk or negedge rst_n) begin : p_functional
        integer index;
        if(!rst_n||clear) begin
            state<=IDLE;epoch_r<=0;group_r<=0;head_r<=0;window_r<=0;
            offset_r<=0;count_r<=0;block_r<=0;context_r<=0;
            active_mask_r<=0;q_done_r<=0;k_done_r<=0;context_done_r<=0;
            q_outstanding_r<=0;
            k_outstanding_r<=0;q_buffer_valid_r<=0;k_buffer_valid_r<=0;
            q_hold_valid_r<=0;k_hold_valid_r<=0;
            q_hold_context_r<=0;k_hold_context_r<=0;q_hold_d_r<=0;k_hold_d_r<=0;
            score_wr_ptr_r<=0;score_rd_ptr_r<=0;score_count_r<=0;
            for(index=0;index<CONTEXTS;index=index+1) begin
                q_next_d[index]<=0;k_next_d[index]<=0;
                q_pending_d[index]<=0;k_pending_d[index]<=0;
                q_buffer_d[index]<=0;k_buffer_d[index]<=0;step_next_d[index]<=0;
            end
        end else begin
            if(!q_hold_valid_r&&q_req_valid&&!q_req_ready) begin
                q_hold_valid_r<=1;q_hold_context_r<=q_req_context_tag;
                q_hold_d_r<=q_req_d;
            end else if(q_fire) q_hold_valid_r<=0;
            if(!k_hold_valid_r&&k_req_valid&&!k_req_ready) begin
                k_hold_valid_r<=1;k_hold_context_r<=k_req_context_tag;
                k_hold_d_r<=k_req_d;
            end else if(k_fire) k_hold_valid_r<=0;
            if(q_rsp_accept) begin
                q_outstanding_r[q_rsp_context_tag]<=0;
                q_buffer_valid_r[q_rsp_context_tag]<=1;
                q_buffer_d[q_rsp_context_tag]<=q_pending_d[q_rsp_context_tag];
            end
            if(k_rsp_accept) begin
                k_outstanding_r[k_rsp_context_tag]<=0;
                k_buffer_valid_r[k_rsp_context_tag]<=1;
                k_buffer_d[k_rsp_context_tag]<=k_pending_d[k_rsp_context_tag];
            end
            if(step_event) begin
                q_buffer_valid_r[step_select_context_w]<=0;
                k_buffer_valid_r[step_select_context_w]<=0;
                context_r<=step_select_context_w;
                if(step_next_d[step_select_context_w]==HEAD_DIM-1)
                    context_done_r[step_select_context_w]<=1;
                else step_next_d[step_select_context_w]<=
                    step_next_d[step_select_context_w]+1'b1;
            end
            if(score_push) begin
                score_epoch_mem[score_wr_ptr_r]<=epoch_r;
                score_group_mem[score_wr_ptr_r]<=group_r;
                score_head_mem[score_wr_ptr_r]<=head_r;
                score_row_mem[score_wr_ptr_r]<=step_row_w;
                score_block_mem[score_wr_ptr_r]<=block_r;
                score_context_mem[score_wr_ptr_r]<=step_select_context_w;
                score_wr_ptr_r<=score_wr_ptr_r+1'b1;
            end
            if(score_fire) score_rd_ptr_r<=score_rd_ptr_r+1'b1;
            case({score_push,score_fire})
                2'b10:score_count_r<=score_count_r+1'b1;
                2'b01:score_count_r<=score_count_r-1'b1;
                default:score_count_r<=score_count_r;
            endcase
            // Request acceptance follows response/step updates so a same-cycle
            // replacement remains outstanding and cannot be overwritten.
            if(q_fire) begin
                q_outstanding_r[q_req_context_tag]<=1;
                q_pending_d[q_req_context_tag]<=q_req_d;
                if(q_req_d==HEAD_DIM-1) q_done_r[q_req_context_tag]<=1;
                else q_next_d[q_req_context_tag]<=q_req_d+1'b1;
            end
            if(k_fire) begin
                k_outstanding_r[k_req_context_tag]<=1;
                k_pending_d[k_req_context_tag]<=k_req_d;
                if(k_req_d==HEAD_DIM-1) k_done_r[k_req_context_tag]<=1;
                else k_next_d[k_req_context_tag]<=k_req_d+1'b1;
            end
            case(state)
                IDLE: if(start_valid&&start_ready) begin
                    epoch_r<=start_epoch;group_r<=start_group;head_r<=start_global_q_head;
                    window_r<=start_row_window;offset_r<=start_row_offset;
                    count_r<=start_row_count;block_r<=start_key_block;
                    active_mask_r<=start_active_mask_w;context_r<=0;
                    q_done_r<=0;k_done_r<=0;context_done_r<=0;
                    q_outstanding_r<=0;k_outstanding_r<=0;
                    q_buffer_valid_r<=0;k_buffer_valid_r<=0;
                    q_hold_valid_r<=0;k_hold_valid_r<=0;
                    for(index=0;index<CONTEXTS;index=index+1) begin
                        q_next_d[index]<=0;k_next_d[index]<=0;
                        q_pending_d[index]<=0;k_pending_d[index]<=0;
                        q_buffer_d[index]<=0;k_buffer_d[index]<=0;
                        step_next_d[index]<=0;
                    end
                    state<=(invalid_start||(start_active_mask_w==0))?DONE:RUN;
                end
                RUN: if(step_event&&
                    ((context_done_after_w&active_mask_r)==active_mask_r)) begin
                    state<=DONE;
                end
                DONE: if(done_valid&&done_ready) state<=IDLE;
            endcase
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin : p_counters
        if(!rst_n||clear||counter_clear) begin
            q_requests_accepted<=0;k_requests_accepted<=0;mac_steps_issued<=0;
            mac_steps_completed<=0;valid_macs<=0;causal_lane_bubbles<=0;
            causal_rows_skipped<=0;memory_request_stalls<=0;mac_issue_stalls<=0;
            scheduler_protocol_errors<=0;scheduler_protocol_error_sticky<=0;
            fp32_requests_accepted<=0;fp32_mul_products_completed<=0;
            fp32_add_results_completed<=0;fp32_response_transfers<=0;
            fp32_protocol_errors<=0;fp32_protocol_error_sticky<=0;
            score_commits<=0;score_commit_stalls<=0;score_fifo_max_occupancy<=0;
        end else begin
            if(q_fire) q_requests_accepted<=q_requests_accepted+1;
            if(k_fire) k_requests_accepted<=k_requests_accepted+1;
            if((state==RUN)&&((q_req_valid&&!q_req_ready)||(k_req_valid&&!k_req_ready)))
                memory_request_stalls<=memory_request_stalls+1;
            if(step_event) begin
                mac_steps_issued<=mac_steps_issued+1;mac_steps_completed<=mac_steps_completed+1;
                valid_macs<=valid_macs+step_active_lanes_w;
                causal_lane_bubbles<=causal_lane_bubbles+(LANES-step_active_lanes_w);
                fp32_requests_accepted<=fp32_requests_accepted+1;
                fp32_mul_products_completed<=fp32_mul_products_completed+step_active_lanes_w;
                fp32_add_results_completed<=fp32_add_results_completed+step_active_lanes_w;
                fp32_response_transfers<=fp32_response_transfers+1;
            end
            if(start_valid&&start_ready)
                causal_rows_skipped<=causal_rows_skipped+
                    ($unsigned(start_row_count)-popcount16(start_active_mask_w));
            if(invalid_start&&start_valid&&start_ready) begin
                scheduler_protocol_errors<=scheduler_protocol_errors+1;
                scheduler_protocol_error_sticky<=1;
            end
            if(invalid_q_rsp||invalid_k_rsp) begin
                scheduler_protocol_errors<=scheduler_protocol_errors+
                    invalid_q_rsp+invalid_k_rsp;scheduler_protocol_error_sticky<=1;
            end
            if(score_push) begin
                score_commits<=score_commits+1;
                if((score_count_r+(score_fire?0:1))>score_fifo_max_occupancy)
                    score_fifo_max_occupancy<=score_count_r+(score_fire?0:1);
            end
            if(score_valid&&!score_ready) score_commit_stalls<=score_commit_stalls+1;
        end
    end

    initial if((CONTEXTS!=16)||(LANES!=32)||(HEAD_DIM<=0))
        $error("cats_r4_qk protocol model requires R=16, lanes=32, positive D");

    always_ff @(posedge clk)
        if(rst_n&&!clear&&score_push&&(score_count_r==16)&&!score_fire)
            $fatal(1,"QK protocol-model score FIFO overflow");
endmodule
