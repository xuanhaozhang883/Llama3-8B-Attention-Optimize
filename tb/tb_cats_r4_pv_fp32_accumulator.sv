`timescale 1ns/1ps
module tb_cats_r4_pv_fp32_accumulator;
    localparam int LANES=32;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0, clear=0;
    logic row_start_valid,row_start_ready; logic [15:0] row_epoch; logic [2:0] row_group;
    logic [4:0] row_head; logic [6:0] row_number; logic [1:0] row_slot_id,row_numeric_mode; logic [31:0] inv_sum;
    logic product_valid,product_ready; logic [6:0] product_key; logic [1:0] product_feature_block;
    logic [LANES*32-1:0] product_fp32; logic product_last;
    logic context_valid,context_ready; logic [15:0] context_epoch; logic [2:0] context_group;
    logic [4:0] context_head; logic [6:0] context_row; logic [1:0] context_slot_id,context_numeric_mode,context_feature_block;
    logic [LANES*16-1:0] context_data; logic context_row_last;
    logic [63:0] product_accept_count,add_commit_count,context_emit_count,protocol_error_count;
    cats_r4_pv_fp32_accumulator dut (.*,
        .row_global_q_head(row_head), .row_inv_sum_fp32(inv_sum),
        .context_global_q_head(context_head), .context_data_bf16(context_data));
    task automatic tick; @(posedge clk); #1; endtask
    integer k,b,l; logic [15:0] got;
    initial begin
        row_start_valid=0; row_epoch=16'ha203; row_group=0; row_head=0; row_number=0;
        row_slot_id=0; row_numeric_mode=1; inv_sum=32'h3f800000; product_valid=0; product_key=0;
        product_feature_block=0; product_fp32='0; product_last=0; context_ready=0;
        repeat(3) tick(); rst_n=1; tick();
        @(negedge clk); row_start_valid=1; while(!row_start_ready) tick(); tick(); @(negedge clk); row_start_valid=0;
        for(k=0;k<128;k=k+1) begin
            for(b=0;b<4;b=b+1) begin
                @(negedge clk); product_key=k[6:0]; product_feature_block=b[1:0]; product_last=(k==127)&&(b==3); product_fp32='0;
                if(k==0 && b==0) product_fp32[31:0]=32'h3f800000;
                product_valid=1; while(!product_ready) tick(); tick(); @(negedge clk); product_valid=0;
            end
        end
        while(add_commit_count < 512) tick();
        if(product_accept_count!=512 || add_commit_count!=512 || protocol_error_count!=0)
            $fatal(1,"PV counters mismatch p=%0d a=%0d e=%0d",product_accept_count,add_commit_count,protocol_error_count);
        context_ready=1;
        for(b=0;b<4;b=b+1) begin
            while(!context_valid) tick();
            if(context_feature_block!=b[1:0] || context_row_last!=(b==3)) $fatal(1,"context metadata mismatch");
            got=context_data[15:0];
            if(b==0 && got!=16'h3f80) $fatal(1,"lane0 expected BF16 1.0, got %h",got);
            if(b!=0 && got!=16'h0000) $fatal(1,"zero block not zero: b=%0d got=%h",b,got);
            tick();
        end
        if(context_emit_count!=4) $fatal(1,"context count mismatch");
        $display("PASS: CATS-R4 32-lane ordered PV accumulation and BF16 context emission");
        $finish;
    end
    initial begin repeat(200000) tick(); $fatal(1,"PV accumulator timeout"); end
endmodule
