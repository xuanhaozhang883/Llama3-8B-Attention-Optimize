`timescale 1ns/1ps
module tb_cats_r4_pv_vcache_to_context;
 localparam int LANES=32; logic clk=0;always #5 clk=~clk;logic rst_n=0,clear=0;
 logic load_valid,load_ready;logic [13:0] load_addr;logic [511:0] load_data;logic req_valid,req_ready;logic [13:0] req_addr;logic rsp_valid,rsp_ready;logic [511:0] rsp_data;logic vcache_error;
 logic weight_valid,weight_ready;logic [6:0] weight_key;logic [1:0] weight_block;logic [31:0] weight_fp32;logic weight_last;
 logic v_req_valid,v_req_ready;logic [6:0] v_req_key;logic [1:0] v_req_block;logic v_rsp_valid;logic [511:0] v_rsp_vec;
 logic product_valid,product_ready;logic [6:0] product_key;logic [1:0] product_block;logic [LANES*32-1:0] product_fp32;logic product_last;
 logic row_start_valid,row_start_ready;logic [31:0] inv_sum;logic context_valid,context_ready;logic [1:0] context_block;logic [LANES*16-1:0] context_data;logic context_row_last;logic [15:0] ce;logic [2:0] cg;logic [4:0] ch;logic [6:0] cr;logic [1:0] cs,cm;
 logic [63:0] wa,vr,pe,adapter_errors,product_accept,add_commits,product_errors,ec;
 bf16_v_cache #(.NUM_KV_HEADS(1),.SEQ_LEN(128),.HEAD_DIM(128),.LANES(32)) u_v(.clk,.rst_n,.load_valid,.load_ready,.load_addr,.load_data,.req_valid,.req_ready,.req_addr,.rsp_valid,.rsp_ready,.rsp_data,.protocol_error(vcache_error));
 cats_r4_pv_weight_v_product_adapter u_p(.clk,.rst_n,.clear,.weight_valid,.weight_ready,.weight_key,.weight_feature_block(weight_block),.weight_fp32,.weight_last,.v_req_valid,.v_req_ready,.v_req_key,.v_req_feature_block(v_req_block),.v_rsp_valid,.v_rsp_vec,.product_valid,.product_ready,.product_key,.product_feature_block(product_block),.product_fp32,.product_last,.weight_accept_count(wa),.v_request_count(vr),.product_emit_count(pe),.protocol_error_count(adapter_errors));
 assign req_valid=v_req_valid;assign v_req_ready=req_ready;assign req_addr=(v_req_key*128)+(v_req_block*32);assign v_rsp_valid=rsp_valid;assign v_rsp_vec=rsp_data;assign rsp_ready=1'b1;
 cats_r4_pv_fp32_accumulator u_a(.clk,.rst_n,.clear,.row_start_valid,.row_start_ready,.row_epoch(16'ha203),.row_group(0),.row_global_q_head(0),.row_number(0),.row_slot_id(0),.row_numeric_mode(1),.row_inv_sum_fp32(inv_sum),.product_valid,.product_ready,.product_key,.product_feature_block(product_block),.product_fp32,.product_last,.context_valid,.context_ready,.context_epoch(ce),.context_group(cg),.context_global_q_head(ch),.context_row(cr),.context_slot_id(cs),.context_numeric_mode(cm),.context_feature_block(context_block),.context_data_bf16(context_data),.context_row_last,.product_accept_count(product_accept),.add_commit_count(add_commits),.context_emit_count(ec),.protocol_error_count(product_errors));
 task automatic tick;@(posedge clk);#1;endtask integer a,b,k,i; logic [511:0] ones; integer context_seen;
 logic [15:0] expected_bf16;
 always @(posedge clk) begin
   if (context_valid && context_ready) begin
     if (context_block !== context_seen[1:0]) $fatal(1,"context block order mismatch: got %0d expected %0d",context_block,context_seen);
     if (context_row_last !== (context_seen == 3)) $fatal(1,"context row_last mismatch at chunk %0d",context_seen);
     for (i=0;i<32;i=i+1) begin
       expected_bf16 = (context_seen == 0) ? 16'h3f80 : 16'h0000;
       if (context_data[i*16 +: 16] !== expected_bf16) $fatal(1,"context Golden mismatch chunk=%0d lane=%0d got=%h expected=%h",context_seen,i,context_data[i*16 +:16],expected_bf16);
     end
     context_seen = context_seen + 1;
   end
 end
 initial begin context_seen=0; ones='0;for(a=0;a<32;a=a+1)ones[a*16 +:16]=16'h3f80;load_valid=0;load_addr=0;load_data=ones;weight_valid=0;weight_key=0;weight_block=0;weight_fp32=0;weight_last=0;row_start_valid=0;inv_sum=32'h3f800000;context_ready=0;
  repeat(3)tick();rst_n=1;
  for(a=0;a<512;a=a+1)begin @(negedge clk);load_addr=a*32;load_valid=1;while(!load_ready)tick();tick();@(negedge clk);load_valid=0;end
  @(negedge clk);row_start_valid=1;while(!row_start_ready)tick();tick();@(negedge clk);row_start_valid=0;
  for(k=0;k<128;k=k+1)for(b=0;b<4;b=b+1)begin @(negedge clk);weight_key=k;weight_block=b;weight_last=(k==127)&&(b==3);weight_fp32=((k==0)&&(b==0))?32'h3f800000:32'h00000000;weight_valid=1;while(!weight_ready)tick();tick();@(negedge clk);weight_valid=0;end
  while(!context_valid)tick(); context_ready=1; while(context_seen<4) tick(); if(wa!=512||vr!=512||pe!=512||product_accept!=512||add_commits!=512||ec!=4||adapter_errors!=0||product_errors!=0||vcache_error)$fatal(1,"PV V-cache counters mismatch wa=%0d vr=%0d pe=%0d pa=%0d ac=%0d ec=%0d ae=%0d pe=%0d ve=%0d",wa,vr,pe,product_accept,add_commits,ec,adapter_errors,product_errors,vcache_error);
  $display("PASS: CATS-R4 real BF16 V-cache -> 32-lane product adapter -> PV context");$finish;end
 initial begin repeat(500000)tick();$fatal(1,"V-cache PV integration timeout");end
endmodule
