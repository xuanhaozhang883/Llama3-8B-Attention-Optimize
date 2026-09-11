`timescale 1ns/1ps
module tb_cats_r4_weight_pv_wrapper;
 logic clk=0;always #5 clk=~clk;logic rst_n=0,clear=0;
 logic pv_row_valid,pv_row_ready;logic [15:0] pv_row_epoch=16'ha203;logic [2:0] pv_row_group=0;logic [4:0] pv_row_global_q_head=0;logic [6:0] pv_row_row=7'd127;logic [1:0] pv_row_slot_id=0,pv_row_numeric_mode=1;logic [31:0] pv_row_inv_sum_fp32=32'h3f800000;
 logic weight_rd_req_valid,weight_rd_req_ready=1;logic [15:0] weight_rd_req_epoch;logic [2:0] weight_rd_req_group;logic [4:0] weight_rd_req_global_q_head;logic [6:0] weight_rd_req_row;logic [1:0] weight_rd_req_slot_id,weight_rd_req_numeric_mode;logic [6:0] weight_rd_req_key;
 logic weight_rd_rsp_valid;logic [15:0] weight_rd_rsp_epoch;logic [2:0] weight_rd_rsp_group;logic [4:0] weight_rd_rsp_global_q_head;logic [6:0] weight_rd_rsp_row;logic [1:0] weight_rd_rsp_slot_id,weight_rd_rsp_numeric_mode;logic [6:0] weight_rd_rsp_key;logic weight_rd_rsp_mask;logic [31:0] weight_rd_rsp_data;
 logic row_start_valid,row_start_ready=1;logic [31:0] row_start_inv_sum_fp32;logic weight_valid,weight_ready;logic [6:0] weight_key;logic weight_mask;logic [31:0] weight_data;logic weight_last;logic pv_done_valid,pv_done_ready;logic weight_release_valid,weight_release_ready=1;logic [15:0] weight_release_epoch;logic [2:0] weight_release_group;logic [4:0] weight_release_global_q_head;logic [6:0] weight_release_row;logic [1:0] weight_release_slot_id,weight_release_numeric_mode;logic [63:0] rows_started,weights_forwarded,rows_released,protocol_error_count;
 cats_r4_weight_pv_wrapper dut(.*);
 logic v0,v1;logic [6:0] k0,k1;
 assign weight_rd_rsp_valid=v1;assign weight_rd_rsp_epoch=pv_row_epoch;assign weight_rd_rsp_group=pv_row_group;assign weight_rd_rsp_global_q_head=pv_row_global_q_head;assign weight_rd_rsp_row=pv_row_row;assign weight_rd_rsp_slot_id=pv_row_slot_id;assign weight_rd_rsp_numeric_mode=pv_row_numeric_mode;assign weight_rd_rsp_key=k1;assign weight_rd_rsp_mask=0;assign weight_rd_rsp_data={25'd0,k1};
 always_ff @(posedge clk) begin if(!rst_n||clear)begin v0<=0;v1<=0;k0<=0;k1<=0;end else begin v1<=v0;k1<=k0;v0<=weight_rd_req_valid&&weight_rd_req_ready;if(weight_rd_req_valid&&weight_rd_req_ready)k0<=weight_rd_req_key;end end
 task automatic tick;@(posedge clk);#1;endtask integer seen;
 initial begin pv_row_valid=0;weight_ready=0;pv_done_valid=0;repeat(3)tick();rst_n=1;@(negedge clk);pv_row_valid=1;tick();@(negedge clk);pv_row_valid=0;seen=0;
  while(seen<128)begin weight_ready=1;tick();if(weight_valid&&weight_ready)begin if(weight_key!=seen[6:0]||weight_data!={25'd0,seen[6:0]})$fatal(1,"weight mismatch");seen=seen+1;end end
  @(negedge clk);pv_done_valid=1;while(!pv_done_ready)tick();tick();@(negedge clk);pv_done_valid=0;while(!pv_row_ready)tick();
  if(rows_started!=1||weights_forwarded!=128||rows_released!=1||protocol_error_count!=0)$fatal(1,"wrapper counters mismatch");
  $display("PASS: CATS-R4 IF_V3 weight-to-PV wrapper order, response hold and release");$finish;end
 initial begin repeat(10000)tick();$fatal(1,"weight PV wrapper timeout");end
endmodule