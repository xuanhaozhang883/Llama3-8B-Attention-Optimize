`timescale 1ns/1ps
module tb_cats_r4_single_cluster_wrapper;
    logic core_clk=0, axi_clk=0;
    always #5 core_clk=~core_clk;
    always #7 axi_clk=~axi_clk;
    logic core_rst_n=0, axi_rst_n=0, arst_n=0, clear=0;
    logic weight_wr_valid,weight_wr_ready; logic [15:0] weight_wr_epoch; logic [2:0] weight_wr_group; logic [4:0] weight_wr_head; logic [6:0] weight_wr_row; logic [1:0] weight_wr_slot,weight_wr_mode; logic [6:0] weight_wr_key; logic weight_wr_mask; logic [31:0] weight_wr_data; logic weight_wr_last;
    logic row_commit_valid,row_commit_ready; logic [15:0] row_commit_epoch; logic [2:0] row_commit_group; logic [4:0] row_commit_head; logic [6:0] row_commit_row; logic [1:0] row_commit_slot,row_commit_mode; logic [31:0] row_commit_sum,row_commit_inv;
    logic v_req_valid,v_req_ready; logic [6:0] v_req_key; logic [1:0] v_req_block; logic v_rsp_valid; logic [511:0] v_rsp_vec; logic v_rsp_ready;
    logic output_start; logic [31:0] output_base; logic wr_valid,wr_ready; logic [31:0] wr_addr; logic [63:0] wr_data; logic wr_row_last,wr_tensor_last,output_busy,output_done,output_error;
    logic abort_valid,abort_ready,abort_done_valid,abort_done_ready; logic [15:0] abort_done_epoch,current_epoch; logic core_outstanding_zero,axi_outstanding_zero,core_accept_enable,axi_accept_enable,core_clear,axi_clear,drain_active;
    logic [63:0] weight_wr_accept,weight_rd_request,weight_rd_response,row_commit_count,pv_row_count,weight_release_count,owner_error,mask_error,last_error,mode_error,numeric_error,epoch_drop,bank_conflict,outstanding_max,rows_started,weights_forwarded,rows_released,product_accept_count,add_commit_count,context_emit_count,output_chunks_accepted,output_beats_committed,protocol_error_count;
    logic [511:0] ones;
    integer i,cycles,abort_wait; logic [15:0] epoch_before_abort;

    cats_r4_single_cluster_wrapper #(.TOTAL_BEATS(32)) dut (.*,
      .weight_wr_global_q_head(weight_wr_head),.weight_wr_slot_id(weight_wr_slot),.weight_wr_numeric_mode(weight_wr_mode),
      .row_commit_global_q_head(row_commit_head),.row_commit_slot_id(row_commit_slot),.row_commit_numeric_mode(row_commit_mode),.row_commit_sum_fp32(row_commit_sum),.row_commit_inv_sum_fp32(row_commit_inv),
      .output_base_addr(output_base),.wr_row_last,.wr_tensor_last,
      .v_req_feature_block(v_req_block),.v_rsp_vec,.abort_done_epoch,.current_epoch,
      .output_chunks_accepted,.output_beats_committed);

    always_ff @(posedge core_clk) begin
      if(!core_rst_n) begin v_rsp_valid<=0; v_rsp_vec<='0; end
      else begin
        v_rsp_valid<=0;
        if(v_req_valid && v_req_ready) begin v_rsp_valid<=1; v_rsp_vec<=ones; end
      end
    end

    task automatic tick; begin @(posedge core_clk); #1; end endtask
    initial begin
      ones='0; for(i=0;i<32;i=i+1) ones[i*16 +:16]=16'h3f80;
      weight_wr_valid=0; weight_wr_epoch=16'ha203; weight_wr_group=0; weight_wr_head=0; weight_wr_row=0; weight_wr_slot=0; weight_wr_mode=1; weight_wr_key=0; weight_wr_mask=0; weight_wr_data=0; weight_wr_last=0;
      row_commit_valid=0; row_commit_epoch=16'ha203; row_commit_group=0; row_commit_head=0; row_commit_row=0; row_commit_slot=0; row_commit_mode=1; row_commit_sum=32'h3f800000; row_commit_inv=32'h3f800000;
      v_req_ready=1; output_start=0; output_base=32'h10000000; wr_ready=1; abort_valid=0; abort_done_ready=1; core_outstanding_zero=1; axi_outstanding_zero=1;
      repeat(4) begin @(posedge core_clk); @(posedge axi_clk); end
      arst_n=1; core_rst_n=1; axi_rst_n=1;
      repeat(6) tick();
      while(!core_accept_enable) tick();
      @(posedge axi_clk); output_start=1; @(posedge axi_clk); output_start=0;
      for(i=0;i<128;i=i+1) begin
        @(negedge core_clk); weight_wr_key=i[6:0]; weight_wr_mask=(i>0); weight_wr_data=(i==0)?32'h3f800000:32'h00000000; weight_wr_last=(i==127); weight_wr_valid=1;
        cycles=0; while(!weight_wr_ready) begin @(posedge core_clk); cycles=cycles+1; end @(negedge core_clk); weight_wr_valid=0;
      end
      @(negedge core_clk); row_commit_valid=1; cycles=0; while(!row_commit_ready) begin @(posedge core_clk); cycles=cycles+1; end @(negedge core_clk); row_commit_valid=0;
      cycles=0; while(!output_done && cycles<200000) begin tick(); cycles=cycles+1; end
       if(!output_done) $fatal(1,"single-cluster output timeout");
      while(rows_released<1 && cycles<220000) begin tick(); cycles=cycles+1; end
      if(rows_released!=1) $fatal(1,"slot release missing");
      if(weight_wr_accept!=128 || weight_rd_request!=128 || weight_rd_response!=128 || row_commit_count!=1 || pv_row_count!=1 || weight_release_count!=1) $fatal(1,"IF_V3 counters mismatch wr=%0d rd=%0d rsp=%0d commit=%0d pv=%0d rel=%0d",weight_wr_accept,weight_rd_request,weight_rd_response,row_commit_count,pv_row_count,weight_release_count);
       if(owner_error||mask_error||last_error||mode_error||numeric_error||epoch_drop||bank_conflict||protocol_error_count||output_error) $fatal(1,"single-cluster errors owner=%0d mask=%0d last=%0d mode=%0d num=%0d epoch=%0d bank=%0d proto=%0d out=%0d",owner_error,mask_error,last_error,mode_error,numeric_error,epoch_drop,bank_conflict,protocol_error_count,output_error);
       if(owner_error||mask_error||last_error||mode_error||numeric_error||epoch_drop||bank_conflict||protocol_error_count||output_error) $fatal(1,"single-cluster errors owner=%0d mask=%0d last=%0d mode=%0d num=%0d epoch=%0d bank=%0d proto=%0d out=%0d",owner_error,mask_error,last_error,mode_error,numeric_error,epoch_drop,bank_conflict,protocol_error_count,output_error);
      epoch_before_abort = current_epoch;
      core_outstanding_zero = 1'b0; axi_outstanding_zero = 1'b0;
      @(negedge core_clk); abort_valid = 1'b1;
      @(posedge core_clk); @(negedge core_clk); abort_valid = 1'b0;
      wait (drain_active);
      repeat(4) tick();
      if (core_accept_enable || axi_accept_enable || weight_wr_ready)
$fatal(1,"abort did not close wrapper accepts");
      core_outstanding_zero = 1'b1; axi_outstanding_zero = 1'b1;
      abort_wait = 0;
      while (!abort_done_valid && abort_wait < 2000) begin tick(); abort_wait=abort_wait+1; end
      if (!abort_done_valid || current_epoch != epoch_before_abort + 1'b1)
$fatal(1,"abort epoch completion mismatch before=%0d after=%0d",epoch_before_abort,current_epoch);
      repeat(4) tick();
      if (!core_accept_enable || !axi_accept_enable)
$fatal(1,"wrapper did not reopen after abort completion");
      arst_n = 1'b0; core_rst_n = 1'b0; axi_rst_n = 1'b0;
      #1;
      if (drain_active || core_accept_enable || axi_accept_enable || current_epoch != 16'd0)
$fatal(1,"hard reset did not clear wrapper coordinator");
      arst_n = 1'b1; core_rst_n = 1'b1; axi_rst_n = 1'b1;
      repeat(8) tick();
      if (!core_accept_enable || !axi_accept_enable)
$fatal(1,"wrapper did not restart after hard reset");
      $display("PASS: CATS-R4 single-cluster replay -> slot -> PV -> output CDC/DDR writer + abort/drain/epoch/reset"); $finish;
    end
    initial begin repeat(250000) tick(); $fatal(1,"single-cluster wrapper timeout"); end
endmodule
