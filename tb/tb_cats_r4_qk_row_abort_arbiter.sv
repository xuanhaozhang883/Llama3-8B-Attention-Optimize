`timescale 1ns/1ps
module tb_cats_r4_qk_row_abort_arbiter;
 logic clk=0; always #5 clk=~clk; logic rst_n=0,clear=0;
 logic a_valid,a_ready,b_valid,b_ready,out_valid,out_ready;
 logic [15:0] a_epoch,b_epoch,out_epoch; logic [2:0] a_group,b_group,out_group;
 logic [4:0] a_head,b_head,out_head; logic [6:0] a_row,b_row,out_row;
 logic [1:0] a_slot,b_slot,out_slot,a_mode,b_mode,out_mode;
 logic [2:0] a_code,b_code,out_code; logic [6:0] a_key,b_key,out_key;
 cats_r4_qk_row_abort_arbiter dut(.*);
 task automatic tick; @(posedge clk); #1; endtask
 initial begin
  a_valid=0;b_valid=0;out_ready=0;
  a_epoch=16'h1001;a_group=0;a_head=0;a_row=1;a_slot=0;a_mode=1;a_code=1;a_key=0;
  b_epoch=16'h2002;b_group=1;b_head=4;b_row=2;b_slot=1;b_mode=1;b_code=2;b_key=2;
  repeat(3)tick();rst_n=1;
  @(negedge clk);a_valid=1;#1;if(!a_ready)$fatal(1,"A abort not accepted");tick();
  @(negedge clk);a_valid=0;b_valid=1;#1;
  if(b_ready||!out_valid||out_epoch!=16'h1001||out_row!=1)$fatal(1,"buffered A abort displaced");
  repeat(3)begin tick();if(!out_valid||out_epoch!=16'h1001||out_row!=1||out_code!=1)$fatal(1,"abort changed while stalled");end
  out_ready=1;tick();
  if(!b_ready)$fatal(1,"B abort not accepted after A drained");
  @(negedge clk);b_valid=0;out_ready=0;#1;
  if(!out_valid||out_epoch!=16'h2002||out_row!=2||out_code!=2||out_key!=2)$fatal(1,"B abort payload lost");
  out_ready=1;tick();if(out_valid)$fatal(1,"arbiter did not empty");
  $display("PASS: CATS-R4 row abort arbiter preserves stalled payload and source order");$finish;
 end
endmodule
