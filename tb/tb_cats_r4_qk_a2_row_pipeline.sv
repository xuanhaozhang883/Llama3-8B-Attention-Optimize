`timescale 1ns/1ps

module tb_cats_r4_qk_a2_row_pipeline;
    localparam int LANES=4, SEQ_LEN=8;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,clear=0,counter_clear=0;
    logic txn_start_valid,txn_start_ready; logic [15:0] txn_epoch;
    logic [1:0] txn_numeric_mode;
    logic raw_score_valid,raw_score_ready; logic [15:0] raw_score_epoch;
    logic [2:0] raw_score_group; logic [4:0] raw_score_global_q_head;
    logic [6:0] raw_score_row; logic [1:0] raw_score_key_block;
    logic [3:0] raw_score_context_tag; logic [LANES-1:0] raw_score_lane_valid;
    logic [LANES*32-1:0] raw_score_fp32;
    logic store_wr_valid,store_wr_ready; logic [1:0] store_wr_slot_id;
    logic [6:0] store_wr_key_base; logic [LANES-1:0] store_wr_lane_valid;
    logic [LANES*16-1:0] store_wr_score_bf16;
    logic score_rd_req_valid,score_rd_req_ready; logic [15:0] score_rd_req_epoch;
    logic [2:0] score_rd_req_group; logic [4:0] score_rd_req_global_q_head;
    logic [6:0] score_rd_req_row,score_rd_req_key; logic [1:0] score_rd_req_slot_id;
    logic [1:0] score_rd_req_numeric_mode;
    logic score_rd_rsp_valid,score_rd_rsp_ready; logic [15:0] score_rd_rsp_epoch;
    logic [2:0] score_rd_rsp_group; logic [4:0] score_rd_rsp_global_q_head;
    logic [6:0] score_rd_rsp_row,score_rd_rsp_key; logic [1:0] score_rd_rsp_slot_id;
    logic [1:0] score_rd_rsp_numeric_mode; logic [15:0] score_rd_rsp_bf16;
    logic b_row_valid,b_row_ready; logic [15:0] b_row_epoch; logic [2:0] b_row_group;
    logic [4:0] b_row_global_q_head; logic [6:0] b_row_index;
    logic [1:0] b_row_slot_id,b_row_numeric_mode; logic [15:0] b_row_max_bf16;
    logic b_score_valid,b_score_ready; logic [15:0] b_score_epoch;
    logic [2:0] b_score_group; logic [4:0] b_score_global_q_head;
    logic [6:0] b_score_row,b_score_key; logic [1:0] b_score_slot_id,b_score_numeric_mode;
    logic [15:0] b_score_bf16; logic b_score_last;
    logic final_release_valid,final_release_ready; logic [15:0] final_release_epoch;
    logic [2:0] final_release_group; logic [4:0] final_release_global_q_head;
    logic [6:0] final_release_row; logic [1:0] final_release_slot_id;
    logic [1:0] final_release_numeric_mode;
    logic row_abort_valid,row_abort_ready; logic [15:0] row_abort_epoch;
    logic [2:0] row_abort_group; logic [4:0] row_abort_global_q_head;
    logic [6:0] row_abort_row,row_abort_error_key; logic [1:0] row_abort_slot_id;
    logic [1:0] row_abort_numeric_mode; logic [2:0] row_abort_error_code;
    logic [5:0] slot_owner; logic [63:0] rows_completed,scores_transferred;
    logic [63:0] rows_transferred,owner_errors,scale_requests_accepted;
    logic [63:0] scale_products_completed,score_format_transfers;
    logic [63:0] formatter_protocol_errors; logic protocol_error_sticky;

    cats_r4_qk_a2_row_pipeline #(
        .SEQ_LEN(SEQ_LEN),.LANES(LANES),.SLOTS(3),.SCALE_FP32(32'h3f800000)
    ) dut (.*);

    logic [15:0] mem[0:2][0:SEQ_LEN-1];
    logic pending; logic [6:0] pending_key; logic [1:0] pending_slot;
    integer i,seen_scores;
    task automatic tick; @(posedge clk); #1; endtask
    initial begin
      repeat(500) tick();
      $fatal(1,"pipeline timeout raw_ready=%b store=%b/%b rd=%b/%b rsp=%b/%b brow=%b bscore=%b rows=%0d scores=%0d owner=%h abort=%b",
             raw_score_ready,store_wr_valid,store_wr_ready,
             score_rd_req_valid,score_rd_req_ready,score_rd_rsp_valid,score_rd_rsp_ready,
             b_row_valid,b_score_valid,rows_transferred,scores_transferred,slot_owner,row_abort_valid);
    end
    task automatic send_raw(input [1:0] kb,input [LANES*32-1:0] values);
      begin
        @(negedge clk); raw_score_key_block=kb;raw_score_fp32=values;
        raw_score_valid=1; while(!raw_score_ready) tick(); tick();
        @(negedge clk);raw_score_valid=0;
      end
    endtask

    always_ff @(posedge clk) begin
      if(!rst_n||clear) begin pending<=0;score_rd_rsp_valid<=0;seen_scores<=0;end
      else begin
        if(store_wr_valid&&store_wr_ready)
          for(i=0;i<LANES;i=i+1) if(store_wr_lane_valid[i])
            mem[store_wr_slot_id][store_wr_key_base+i]<=store_wr_score_bf16[i*16+:16];
        if(score_rd_rsp_valid&&score_rd_rsp_ready) score_rd_rsp_valid<=0;
        if(pending&&(!score_rd_rsp_valid||score_rd_rsp_ready)) begin
          pending<=0;score_rd_rsp_valid<=1;score_rd_rsp_epoch<=score_rd_req_epoch;
          score_rd_rsp_group<=score_rd_req_group;
          score_rd_rsp_global_q_head<=score_rd_req_global_q_head;
          score_rd_rsp_row<=score_rd_req_row;score_rd_rsp_key<=pending_key;
          score_rd_rsp_slot_id<=pending_slot;
          score_rd_rsp_numeric_mode<=score_rd_req_numeric_mode;
          score_rd_rsp_bf16<=mem[pending_slot][pending_key];
        end
        if(score_rd_req_valid&&score_rd_req_ready) begin
          pending<=1;pending_key<=score_rd_req_key;pending_slot<=score_rd_req_slot_id;
        end
        if(b_row_valid&&b_row_ready && b_row_max_bf16!==16'h4100)
          $fatal(1,"row max was not computed from all formatted scores");
        if(b_score_valid&&b_score_ready) begin
          if(b_score_key!==seen_scores || b_score_bf16!==mem[0][seen_scores] ||
             b_score_last!==(seen_scores==7)) $fatal(1,"B score order/data/last mismatch");
          seen_scores<=seen_scores+1;
        end
      end
    end

    initial begin
      txn_start_valid=0;txn_epoch=16'ha202;txn_numeric_mode=1;
      raw_score_valid=0;raw_score_epoch=16'ha202;raw_score_group=1;
      raw_score_global_q_head=4;raw_score_row=7;raw_score_context_tag=0;
      raw_score_lane_valid='1;raw_score_fp32=0;
      store_wr_ready=1;score_rd_req_ready=1;
      b_row_ready=1;b_score_ready=1;row_abort_ready=1;final_release_valid=0;
      final_release_epoch=16'ha202;final_release_group=1;
      final_release_global_q_head=4;final_release_row=7;final_release_slot_id=0;
      final_release_numeric_mode=1;
      repeat(3)tick();rst_n=1;repeat(2)tick();
      @(negedge clk);txn_start_valid=1;tick();@(negedge clk);txn_start_valid=0;
      send_raw(0,{32'h40800000,32'h40400000,32'h40000000,32'h3f800000});
      send_raw(1,{32'h41000000,32'h40e00000,32'h40c00000,32'h40a00000});
      while(rows_transferred!=1)tick();
      if(seen_scores!=8||rows_completed!=1||scores_transferred!=8||
         scale_requests_accepted!=2||scale_products_completed!=8||
         score_format_transfers!=2||formatter_protocol_errors!=0||
         row_abort_valid||protocol_error_sticky||slot_owner[1:0]!=2)
        $fatal(1,"raw-to-B pipeline counters/ownership mismatch");
      @(negedge clk);final_release_valid=1;#1;
      if(!final_release_ready)$fatal(1,"B release rejected");
      tick();@(negedge clk);final_release_valid=0;#1;
      if(slot_owner[1:0]!=0||owner_errors!=0)$fatal(1,"slot was not reusable");
      $display("PASS: CATS-R4 A2 raw FP32 through BF16 RNE row/max A-to-B pipeline");
      $finish;
    end
endmodule
