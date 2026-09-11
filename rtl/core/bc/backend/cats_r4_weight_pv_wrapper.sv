`timescale 1ns/1ps

// IF_V3 C weight-service to PV protocol wrapper.
// Accepts one announced row, reads weights in key order, provides an elastic
// weight stream to the PV consumer, and releases the slot only after the
// consumer reports that the final context output was accepted.
module cats_r4_weight_pv_wrapper (
 input logic clk,input logic rst_n,input logic clear,
 input logic pv_row_valid,output logic pv_row_ready,input logic [15:0] pv_row_epoch,
 input logic [2:0] pv_row_group,input logic [4:0] pv_row_global_q_head,input logic [6:0] pv_row_row,
 input logic [1:0] pv_row_slot_id,input logic [1:0] pv_row_numeric_mode,input logic [31:0] pv_row_inv_sum_fp32,
 output logic weight_rd_req_valid,input logic weight_rd_req_ready,output logic [15:0] weight_rd_req_epoch,
 output logic [2:0] weight_rd_req_group,output logic [4:0] weight_rd_req_global_q_head,
 output logic [6:0] weight_rd_req_row,output logic [1:0] weight_rd_req_slot_id,
 output logic [1:0] weight_rd_req_numeric_mode,output logic [6:0] weight_rd_req_key,
 input logic weight_rd_rsp_valid,input logic [15:0] weight_rd_rsp_epoch,input logic [2:0] weight_rd_rsp_group,
 input logic [4:0] weight_rd_rsp_global_q_head,input logic [6:0] weight_rd_rsp_row,
 input logic [1:0] weight_rd_rsp_slot_id,input logic [1:0] weight_rd_rsp_numeric_mode,
 input logic [6:0] weight_rd_rsp_key,input logic weight_rd_rsp_mask,input logic [31:0] weight_rd_rsp_data,
 output logic row_start_valid,input logic row_start_ready,output logic [31:0] row_start_inv_sum_fp32,
 output logic weight_valid,input logic weight_ready,output logic [6:0] weight_key,
 output logic weight_mask,output logic [31:0] weight_data,output logic weight_last,
 input logic pv_done_valid,output logic pv_done_ready,
 output logic weight_release_valid,input logic weight_release_ready,
 output logic [15:0] weight_release_epoch,output logic [2:0] weight_release_group,
 output logic [4:0] weight_release_global_q_head,output logic [6:0] weight_release_row,
 output logic [1:0] weight_release_slot_id,output logic [1:0] weight_release_numeric_mode,
 output logic [63:0] rows_started,output logic [63:0] weights_forwarded,
 output logic [63:0] rows_released,output logic [63:0] protocol_error_count
);
 typedef enum logic [2:0]{IDLE,ROW_START,REQUEST,RESPONSE,WAIT_DONE,RELEASE} state_t;
 state_t state; logic [15:0] e; logic [2:0] g; logic [4:0] h; logic [6:0] r,k;
 logic [1:0] s,m; logic [31:0] inv; logic mask_hold,rsp_hold_valid; logic [31:0] data_hold;
 assign pv_row_ready=(state==IDLE); assign row_start_valid=(state==ROW_START);
 assign row_start_inv_sum_fp32=inv; assign weight_rd_req_valid=(state==REQUEST);
 assign weight_rd_req_epoch=e; assign weight_rd_req_group=g; assign weight_rd_req_global_q_head=h;
 assign weight_rd_req_row=r; assign weight_rd_req_slot_id=s; assign weight_rd_req_numeric_mode=m;
 assign weight_rd_req_key=k; assign weight_valid=(state==RESPONSE)&&rsp_hold_valid; assign weight_key=k;
 assign weight_mask=mask_hold; assign weight_data=data_hold; assign weight_last=(k==7'd127);
 assign pv_done_ready=(state==WAIT_DONE); assign weight_release_valid=(state==RELEASE);
 assign weight_release_epoch=e; assign weight_release_group=g; assign weight_release_global_q_head=h;
 assign weight_release_row=r; assign weight_release_slot_id=s; assign weight_release_numeric_mode=m;
 always_ff @(posedge clk) begin
  if(!rst_n||clear) begin state<=IDLE;e<='0;g<='0;h<='0;r<='0;k<='0;s<='0;m<='0;inv<='0;mask_hold<=0;rsp_hold_valid<=0;data_hold<='0;rows_started<='0;weights_forwarded<='0;rows_released<='0;protocol_error_count<='0; end
  else case(state)
   IDLE:if(pv_row_valid) begin e<=pv_row_epoch;g<=pv_row_group;h<=pv_row_global_q_head;r<=pv_row_row;s<=pv_row_slot_id;m<=pv_row_numeric_mode;inv<=pv_row_inv_sum_fp32;k<='0;state<=ROW_START;end
   ROW_START:if(row_start_valid&&row_start_ready) begin rows_started<=rows_started+1'b1;state<=REQUEST;end
   REQUEST:if(weight_rd_req_valid&&weight_rd_req_ready) begin rsp_hold_valid<=0;state<=RESPONSE;end
   RESPONSE:begin
    if(weight_rd_rsp_valid) begin
     if({weight_rd_rsp_epoch,weight_rd_rsp_group,weight_rd_rsp_global_q_head,weight_rd_rsp_row,weight_rd_rsp_slot_id,weight_rd_rsp_numeric_mode,weight_rd_rsp_key}!={e,g,h,r,s,m,k}) protocol_error_count<=protocol_error_count+1'b1;
     mask_hold<=weight_rd_rsp_mask;data_hold<=weight_rd_rsp_data;rsp_hold_valid<=1;
    end
    if(weight_valid&&weight_ready) begin rsp_hold_valid<=0;weights_forwarded<=weights_forwarded+1'b1; if(k==7'd127) state<=WAIT_DONE; else begin k<=k+1'b1;state<=REQUEST;end end
   end
   WAIT_DONE:if(pv_done_valid&&pv_done_ready) state<=RELEASE;
   RELEASE:if(weight_release_valid&&weight_release_ready) begin rows_released<=rows_released+1'b1;state<=IDLE;end
   default:state<=IDLE;
  endcase
 end
endmodule