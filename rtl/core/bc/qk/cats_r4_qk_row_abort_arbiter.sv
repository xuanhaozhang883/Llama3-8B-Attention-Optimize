`timescale 1ns/1ps
module cats_r4_qk_row_abort_arbiter(
 input logic clk,rst_n,clear,
 input logic a_valid,output logic a_ready,input logic [15:0] a_epoch,input logic [2:0] a_group,
 input logic [4:0] a_head,input logic [6:0] a_row,input logic [1:0] a_slot,a_mode,
 input logic [2:0] a_code,input logic [6:0] a_key,
 input logic b_valid,output logic b_ready,input logic [15:0] b_epoch,input logic [2:0] b_group,
 input logic [4:0] b_head,input logic [6:0] b_row,input logic [1:0] b_slot,b_mode,
 input logic [2:0] b_code,input logic [6:0] b_key,
 output logic out_valid,input logic out_ready,output logic [15:0] out_epoch,output logic [2:0] out_group,
 output logic [4:0] out_head,output logic [6:0] out_row,output logic [1:0] out_slot,out_mode,
 output logic [2:0] out_code,output logic [6:0] out_key
);
 logic can_accept;
 assign can_accept=!out_valid||out_ready;
 assign b_ready=can_accept;
 assign a_ready=can_accept&&!b_valid;
 always_ff @(posedge clk) begin
  if(!rst_n||clear)begin out_valid<=0;out_epoch<=0;out_group<=0;out_head<=0;out_row<=0;out_slot<=0;out_mode<=0;out_code<=0;out_key<=0;end
  else begin
   if(out_valid&&out_ready)out_valid<=0;
   if(b_valid&&b_ready)begin out_valid<=1;out_epoch<=b_epoch;out_group<=b_group;out_head<=b_head;out_row<=b_row;out_slot<=b_slot;out_mode<=b_mode;out_code<=b_code;out_key<=b_key;end
   else if(a_valid&&a_ready)begin out_valid<=1;out_epoch<=a_epoch;out_group<=a_group;out_head<=a_head;out_row<=a_row;out_slot<=a_slot;out_mode<=a_mode;out_code<=a_code;out_key<=a_key;end
  end
 end
endmodule
